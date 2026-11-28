package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func TestHistoryRollsGrowthAndVisitorEarningsWithDurableReplay(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "history-archive-local-signing-key-only")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	var clock atomic.Int64
	var apiDownstream atomic.Int64
	clock.Store(start.Unix())
	app := &Server{Pool: playerDayPool(t, pool, 1, &apiDownstream), Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return time.Unix(clock.Load(), 0).UTC()
	}}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("history-archive")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		r, _ := testCall(t, api, method, path, token, body, gardenHeaders, status)
		return r
	}
	zone, err := time.LoadLocation("Asia/Singapore")
	if err != nil {
		t.Fatal(err)
	}
	if start.In(zone).Hour() == 23 && start.In(zone).Minute() >= 59 {
		zone = time.UTC
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": zone.String()}, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	garden := account["gardenId"].(string)
	plant := account["starterPlantId"].(string)
	editRequest := uuid.NewString()
	call("POST", "/v1/me/garden/edits", map[string]any{"requestId": editRequest, "expectedLayoutVersion": 0,
		"catalogVersion": "development-woodland-v2", "actions": []map[string]any{{"action": "plant", "plantId": plant, "x": 2, "y": 2, "rotationDegrees": 0}}}, 200)
	// A malformed stored completion must not cause loss of the full response.
	if _, err := pool.Exec(ctx, `UPDATE api_requests SET completion='{"version":1,"outcome":null}' WHERE user_id=$1 AND request_id=$2`, owner, editRequest); err != nil {
		t.Fatal(err)
	}
	installation := uuid.NewString()
	device := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(), "installationId": installation,
		"observedAt": start.Format(time.RFC3339Nano), "steps": 900}, 200)["device"].(map[string]any)
	enrolledAt, err := time.Parse(time.RFC3339Nano, device["enrolledAt"].(string))
	if err != nil {
		t.Fatal(err)
	}
	start = maxTime(start, enrolledAt.UTC().Truncate(time.Second).Add(time.Second))
	upload := func(seconds, steps int64) (map[string]any, map[string]any) {
		t.Helper()
		at := start.Add(time.Duration(seconds) * time.Second)
		clock.Store(at.Unix())
		body := map[string]any{"requestId": uuid.NewString(), "deviceId": device["deviceId"], "installationId": installation,
			"observedAt": at.Format(time.RFC3339Nano),
			"days":       []map[string]any{{"gameDate": at.In(zone).Format(time.DateOnly), "steps": steps}}}
		return call("POST", "/v1/activity/sync", body, 200), body
	}
	first, body := upload(10, 1900)
	second, _ := upload(20, 2900)
	call("POST", "/v1/reward-recaps/"+first["recapId"].(string)+"/ack", map[string]string{"requestId": uuid.NewString()}, 200)

	ctxBefore := call("GET", "/v1/me/visitors", nil, 200)
	visitorInstallation := uuid.NewString()

	visitors := call("POST", "/v1/me/visitor-sessions", map[string]string{"requestId": uuid.NewString(), "installationId": visitorInstallation}, 200)
	session := visitors["session"].(map[string]any)["sessionId"]
	when := start.Add(20 * time.Second)
	welcome, legacy, expired := uuid.NewString(), uuid.NewString(), uuid.NewString()
	for index, id := range []string{welcome, legacy, expired} {
		status := "issued"
		if id == expired {
			status = "expired"
		}
		if _, err := pool.Exec(ctx, `INSERT INTO visitor_opportunities(id,garden_id,session_id,context_id,rule_version,slot,issued_at,expires_at,tokens,status)
			VALUES($1,$2,$3,$4,'development-visitors-v1',$5,$6,$7,1,$8)`,
			id, garden, session, visitors["contextId"], when.Unix()/30-int64(index+1), when.Add(-time.Second), when.Add(15*time.Second), status); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pool.Exec(ctx, "UPDATE garden_visitor_state SET ever_issued=true WHERE garden_id=$1", garden); err != nil {
		t.Fatal(err)
	}
	newRequest := map[string]string{"requestId": uuid.NewString()}
	welcomePath := "/v1/me/visitor-opportunities/" + welcome + "/welcome"
	normal := call("POST", welcomePath, newRequest, 200)
	testCall(t, api, "POST", "/v1/me/visitor-opportunities/"+legacy+"/welcome", token, map[string]string{"requestId": uuid.NewString()}, nil, 200)
	call("POST", "/v1/me/visitor-sessions/"+session.(string)+"/end", map[string]string{"requestId": uuid.NewString(), "installationId": visitorInstallation}, 200)
	unusedContext, unusedSession := uuid.NewString(), uuid.NewString()
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_contexts(id,garden_id,effective_at,rule_version,snapshot)
		SELECT $1,garden_id,effective_at,rule_version,snapshot FROM visitor_contexts WHERE id=$2`,
		unusedContext, ctxBefore["contextId"]); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_sessions(id,owner_id,garden_id,installation_id,started_at,lease_expires_at,ended_at,arrival_protocol)
		SELECT $1,owner_id,garden_id,installation_id,started_at,lease_expires_at,ended_at,arrival_protocol FROM visitor_sessions WHERE id=$2`,
		unusedSession, session); err != nil {
		t.Fatal(err)
	}
	// Model a legacy activity request with a retained full body but no completion.
	if _, err := pool.Exec(ctx, `UPDATE api_requests SET completion=NULL,recovery_version=0,response_expires_at=NULL
		WHERE user_id=$1 AND request_id=$2`, owner, body["requestId"]); err != nil {
		t.Fatal(err)
	}
	var originalGrowth, watermark int64
	var expectedProfile json.RawMessage
	if err := pool.QueryRow(ctx, `SELECT sum(p.after_growth-p.before_growth),max(d.credited_steps),
		jsonb_build_object('profiles',g.payload->'profiles','skills',g.payload->'skills')
		FROM plant_growth_credits p JOIN growth_provenance g ON g.id=p.provenance_id
		JOIN activity_days d ON d.owner_id=$1 WHERE p.plant_id=$2 GROUP BY 3`, owner, plant).
		Scan(&originalGrowth, &watermark, &expectedProfile); err != nil {
		t.Fatal(err)
	}
	expectedKey, err := growthHistoryProfileKey(expectedProfile)
	if err != nil {
		t.Fatal(err)
	}

	// Use a future cutoff to age real HTTP-created receipts without rewriting
	// immutable source timestamps or waiting for the retention window.
	var downstream atomic.Int64
	daemon := &Server{Pool: playerDayPool(t, pool, 1, &downstream)}
	future := start.AddDate(0, 0, 35)
	worker := httptest.NewServer(daemon.worker(func(ctx context.Context, tx pgx.Tx) (string, error) {
		return maintainHistory(ctx, tx, &future)
	}))
	t.Cleanup(worker.Close)
	for _, phase := range []string{"active archive", "idle retry"} {
		begin := time.Now()
		before := downstream.Load()
		response, _ := testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
		if response["status"] != "ok" {
			t.Fatal(response)
		}
		t.Logf("%s: %.2f ms, %d PostgreSQL downstream bytes", phase, float64(time.Since(begin))/float64(time.Millisecond), downstream.Load()-before)
	}

	var traceCount, provenanceCount, remainingOpp, sessions, contexts int
	var awarded, credits, hosted, tokens, retainedWatermark int64
	var recapsProtected, legacyReceipt, usedContext, invalidProofRetained bool
	var profileKey string
	err = pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM plant_growth_credits WHERE plant_id=$2),
		(SELECT count(*) FROM growth_provenance),
		(SELECT count(*) FROM visitor_opportunities WHERE garden_id=$3),
		(SELECT count(*) FROM visitor_sessions WHERE garden_id=$3),
		(SELECT count(*) FROM visitor_contexts WHERE id=$4),
		(SELECT awarded FROM growth_day_summaries WHERE plant_id=$2),
		(SELECT credit_count FROM growth_day_summaries WHERE plant_id=$2),
		(SELECT profile_key FROM growth_day_summaries WHERE plant_id=$2),
		(SELECT sum(visits) FROM visitor_day_summaries WHERE garden_id=$3 AND kind='active_welcome'),
		(SELECT sum(tokens) FROM visitor_day_summaries WHERE garden_id=$3 AND kind='active_welcome'),
		(SELECT credited_steps FROM activity_days WHERE owner_id=$1),
		(SELECT a.payload ? 'compacted' AND e.payload ? 'compacted' FROM reward_recaps a JOIN reward_events e ON e.id=a.event_id WHERE a.id=$5)
			AND (SELECT NOT (a.payload ? 'compacted' OR e.payload ? 'compacted') FROM reward_recaps a JOIN reward_events e ON e.id=a.event_id WHERE a.id=$6),
		(SELECT completion IS NOT NULL AND response IS NOT NULL FROM api_requests WHERE user_id=$1 AND request_id=$7),
		EXISTS(SELECT 1 FROM garden_visitor_state v JOIN visitor_contexts c ON c.id=v.context_id WHERE v.garden_id=$3),
		(SELECT response IS NOT NULL FROM api_requests WHERE user_id=$1 AND request_id=$8)`,
		owner, plant, garden, unusedContext, first["recapId"], second["recapId"], body["requestId"], editRequest).
		Scan(&traceCount, &provenanceCount, &remainingOpp, &sessions, &contexts, &awarded, &credits, &profileKey, &hosted, &tokens, &retainedWatermark, &recapsProtected, &legacyReceipt, &usedContext, &invalidProofRetained)
	if err != nil {
		t.Fatal(err)
	}
	if traceCount != 0 || provenanceCount != 0 || remainingOpp != 1 || sessions != 1 || contexts != 0 || awarded != originalGrowth ||
		credits != 2 || profileKey != expectedKey || hosted != 2 || tokens != 2 || retainedWatermark != watermark || !recapsProtected || !legacyReceipt || !usedContext || !invalidProofRetained {
		t.Fatalf("traces=%d provenance=%d opportunities=%d sessions=%d contexts=%d growth=%d credits=%d hosted=%d tokens=%d watermarks=%d; recap=%v request=%v context=%v invalidProofRetained=%v",
			traceCount, provenanceCount, remainingOpp, sessions, contexts, awarded, credits, hosted, tokens, retainedWatermark, recapsProtected, legacyReceipt, usedContext, invalidProofRetained)
	}

	recovered := call("POST", welcomePath, newRequest, 200)["recovery"].(map[string]any)
	alias := map[string]string{"requestId": uuid.NewString()}
	before, started := apiDownstream.Load(), time.Now()
	recoveredAlias := call("POST", welcomePath, alias, 200)
	t.Logf("archived welcome recovery for a fresh request ID: %.2f ms, %d PostgreSQL downstream bytes",
		float64(time.Since(started))/float64(time.Millisecond), apiDownstream.Load()-before)
	if recovered["outcome"].(map[string]any)["eventId"] != normal["eventId"] ||
		recoveredAlias["recovery"].(map[string]any)["outcome"].(map[string]any)["eventId"] != normal["eventId"] ||
		!reflect.DeepEqual(call("POST", welcomePath, alias, 200), recoveredAlias) {
		t.Fatal(recovered, recoveredAlias)
	}
	call("POST", "/v1/me/visitor-opportunities/"+legacy+"/welcome", alias, 409)
	testCall(t, api, "POST", welcomePath, token, map[string]string{"requestId": uuid.NewString()}, nil, 426)
	wallet := call("GET", "/v1/me/visitors", nil, 200)
	if wallet["tokenBalance"] != "2" {
		t.Fatal(wallet)
	}
}

func TestWorkerRequestRetentionHonorsClientProofAndFlags(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "request-retention-local-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	app := &Server{Pool: pool, Auth: dev, Environment: "test"}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("retention-policy")
	if err != nil {
		t.Fatal(err)
	}
	account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token,
		map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, map[string]string{"X-Forest-Recovery": "1"}, 200)
	owner := account["profile"].(map[string]any)["userId"]
	control, unsequenced, legacy, unverifiable, enrollment := uuid.New(), uuid.New(), uuid.New(), uuid.New(), uuid.New()
	if _, err := pool.Exec(ctx, `
		INSERT INTO visitor_controls(owner_id,sequence,request_id,operation,payload_hash,accepted_at)
		VALUES($1,1,$2,'visitor_heartbeat','heartbeat',now()-interval '2 days 1 second');
	`, owner, control); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO api_requests
		(user_id,request_id,operation,payload_hash,created_at,response,recovery_version,response_expires_at,completion)
		VALUES
		($1,$2,'visitor_heartbeat','heartbeat',now()-interval '2 days','{"session":null}',1,now()-interval '1 day',
			'{"version":1,"outcome":{"sessionId":null},"sequencedControl":true}'),
		($1,$3,'visitor_end','end',now()-interval '2 days','{"session":null}',1,NULL,NULL),
		($1,$4,'visitor_end','legacy',now()-interval '2 days','{"session":null}',0,NULL,NULL),
		($1,$5,'item_purchase','unknown',now()-interval '8 days','{"purchaseId":"missing"}',1,NULL,NULL),
		($1,$6,'activity_enrolment','enroll',now()-interval '8 days','{"device":null}',1,NULL,NULL)`,
		owner, control, unsequenced, legacy, unverifiable, enrollment); err != nil {
		t.Fatal(err)
	}

	config := defaultWorkerConfig
	config.Responses, config.Visitors, config.Growth, config.Metrics = false, false, false, true
	disabled := httptest.NewServer((&Server{Pool: pool, WorkerConfig: &config}).WorkerHandler())
	t.Cleanup(disabled.Close)
	report, _ := testCall(t, disabled, "POST", "/tasks/history", "", nil, nil, 200)
	if report["responses"].(map[string]any)["examined"] != float64(0) ||
		report["queries"] != float64(3) || report["dbResultSampleTruncated"] != false {
		t.Fatal(report)
	}

	worker := httptest.NewServer(app.WorkerHandler())
	t.Cleanup(worker.Close)
	report, _ = testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	counts := report["responses"].(map[string]any)
	if report["committedTransactions"] != float64(1) ||
		counts["deletedControls"] != float64(1) || counts["compacted"] != float64(1) ||
		counts["backfilled"] != float64(4) {
		t.Fatal(report)
	}
	var gone, expired, preserved bool
	if err := pool.QueryRow(ctx, `SELECT
		NOT EXISTS(SELECT 1 FROM api_requests WHERE user_id=$1 AND request_id=$2),
		EXISTS(SELECT 1 FROM api_requests WHERE user_id=$1 AND request_id=$3 AND response IS NULL
			AND completion->'outcome'='{"sessionId":null}'),
		(SELECT count(*)=3 FROM api_requests WHERE user_id=$1 AND request_id IN ($4,$5,$6)
			AND response IS NOT NULL AND completion IS NOT NULL)`, owner, control, unsequenced, legacy, unverifiable, enrollment).
		Scan(&gone, &expired, &preserved); err != nil || !gone || !expired || !preserved {
		t.Fatalf("control removed=%v, unsequenced compacted=%v, protected receipts retained=%v, error=%v",
			gone, expired, preserved, err)
	}
	var seconds int64
	if err := pool.QueryRow(ctx, `SELECT extract(epoch FROM response_expires_at-created_at)::bigint
		FROM api_requests WHERE user_id=$1 AND request_id=$2`, owner, enrollment).Scan(&seconds); err != nil || seconds != 30*86400 {
		t.Fatalf("enrollment window=%d seconds, error=%v", seconds, err)
	}
}
