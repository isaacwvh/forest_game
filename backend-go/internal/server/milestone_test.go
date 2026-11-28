package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const testMilestonePolicy = "milestones-woodland-v1"

func seedMilestonePolicy(t *testing.T, pool *pgxpool.Pool, effective time.Time) json.RawMessage {
	t.Helper()
	data, err := os.ReadFile("../../fixtures/milestones-test.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Policy, Event json.RawMessage }
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := pool.Exec(ctx, "INSERT INTO milestone_policies(version,effective_at,active,definition) VALUES($1,$2,true,$3::jsonb)",
		testMilestonePolicy, effective, fixture.Policy); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO pack_definitions (id,version,is_fixture,definition)
		SELECT p.id,20,true,d.definition FROM pack_definitions d CROSS JOIN (VALUES ('woodland'),('select-woodland')) p(id)
		WHERE d.id='woodland' AND d.version=2`); err != nil {
		t.Fatal(err)
	}
	return fixture.Event
}

func findMilestone(t *testing.T, doc map[string]any, key string) map[string]any {
	t.Helper()
	for _, raw := range doc["milestones"].([]any) {
		m := raw.(map[string]any)
		if m["milestoneId"] == key {
			return m
		}
	}
	t.Fatalf("missing milestone %s", key)
	return nil
}

func TestNativeMilestoneClaimsActivityAndVisitorEvidence(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	zone := time.UTC
	if start.Hour() >= 21 {
		var err error
		zone, err = time.LoadLocation("Asia/Singapore")
		if err != nil {
			t.Fatal(err)
		}
	}
	event := seedMilestonePolicy(t, pool, start.Add(-time.Hour))
	if _, err := pool.Exec(ctx, `INSERT INTO milestone_events(event_id,policy_version,name,starts_at,ends_at,claim_until,definition)
		VALUES ('go_event',$1,'Go Event',$2,$3,$4,$5::jsonb)`, testMilestonePolicy, start.Add(-time.Minute), start.Add(3*time.Hour), start.Add(4*time.Hour), event); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO economy_configs (version,effective_at,is_fixture,rules)
		SELECT 'go-milestone-workout','1970-01-02',true,rules||'{"workout_daily_cap_seconds":600}'::jsonb
		||jsonb_build_object('metrics',rules->'metrics'||'{"workout_minutes.running":{"normalisation":"1","water_micro_units":1000000}}')
		FROM economy_configs WHERE version='development-neutral-v1'`); err != nil {
		t.Fatal(err)
	}
	dev, err := DevelopmentVerifier("test", "native-milestone-test-development-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	clock.Store(start.Unix())
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time { return time.Unix(clock.Load(), 0).UTC() }}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("native-milestones")
	if err != nil {
		t.Fatal(err)
	}
	headers := map[string]string{"X-Forest-Milestones": "1", "X-Forest-Recovery": "1", "X-Forest-Woodland": "1"}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		doc, _ := testCall(t, api, method, path, token, body, headers, status)
		return doc
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": zone.String()}, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	garden := account["gardenId"].(string)
	home := call("GET", "/v1/me/home-attention", nil, 200)
	if home["milestoneCount"] != float64(1) {
		t.Fatal(home)
	}
	const summary = "/v1/me/collection?view=home"
	legacy, _ := testCall(t, api, "GET", summary, token, nil, nil, 200)
	if len(legacy["milestones"].([]any)) != 0 {
		t.Fatal(legacy)
	}
	read := func() map[string]any { return call("GET", summary, nil, 200) }
	if opening := findMilestone(t, read(), "steps_new_beginnings"); opening["eligible"] != true || opening["progress"] != "1" {
		t.Fatal(opening)
	}
	claimPath := func(key string) string { return "/v1/me/milestones/" + key + "/claim" }
	body := map[string]string{"requestId": uuid.NewString()}
	testCall(t, api, "POST", claimPath("steps_new_beginnings"), token, body, nil, 426)
	full := uuid.New()
	if _, err := pool.Exec(ctx, `WITH fixture AS (
		INSERT INTO collection_events(id,owner_id,request_id,operation,payload_hash,token_delta,gem_delta,receipt)
		VALUES($1,$2,$1,'test_pack_storage','fixture',0,0,'{}') RETURNING id
	) INSERT INTO owned_packs(id,owner_id,pack_id,pack_version,exchange_id,acquired_at)
		SELECT gen_random_uuid(),$2,'woodland',20,fixture.id,clock_timestamp() FROM fixture,generate_series(1,50)`, full, owner); err != nil {
		t.Fatal(err)
	}
	call("POST", claimPath("steps_new_beginnings"), body, 409)
	if _, err := pool.Exec(ctx, "DELETE FROM owned_packs WHERE exchange_id=$1", full); err != nil {
		t.Fatal(err)
	}
	claimed := call("POST", claimPath("steps_new_beginnings"), body, 200)
	if len(claimed["packs"].([]any)) != 1 || !reflect.DeepEqual(claimed, call("POST", claimPath("steps_new_beginnings"), body, 200)) {
		t.Fatal(claimed)
	}
	alias := map[string]string{"requestId": uuid.NewString()}
	replayed := call("POST", claimPath("steps_new_beginnings"), alias, 200)
	if replayed["requestId"] != alias["requestId"] || replayed["milestoneEventId"] != claimed["milestoneEventId"] || !reflect.DeepEqual(replayed["packs"], claimed["packs"]) {
		t.Fatal(replayed)
	}
	call("POST", claimPath("steps_1000"), alias, 409)
	opened := call("POST", "/v1/me/packs/"+claimed["packs"].([]any)[0].(map[string]any)["ownedPackId"].(string)+"/open",
		map[string]string{"requestId": uuid.NewString()}, 200)
	if opened["packVersion"] != float64(20) {
		t.Fatal(opened)
	}
	species := opened["plant"].(map[string]any)["speciesId"]
	var speciesPinned bool
	if err := pool.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM milestone_species WHERE owner_id=$1 AND species_id=$2)", owner, species).Scan(&speciesPinned); err != nil || !speciesPinned {
		t.Fatalf("pack species not pinned: %s: %v", species, err)
	}
	if _, err := pool.Exec(ctx, `UPDATE milestone_state SET progress=progress||'{"activity_days":29}'::jsonb WHERE owner_id=$1`, owner); err != nil {
		t.Fatal(err)
	}
	call("POST", "/v1/me/garden/edits", map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2", "expectedLayoutVersion": 0,
		"actions": []map[string]any{{"action": "plant", "plantId": account["starterPlantId"], "x": 2, "y": 2, "rotationDegrees": 0}}}, 200)
	installation := uuid.NewString()
	enrolled := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(), "installationId": installation,
		"observedAt": start.Format(time.RFC3339Nano), "steps": 900, "workoutsAvailable": true}, 200)
	device := enrolled["device"].(map[string]any)
	enrolledAt, err := time.Parse(time.RFC3339Nano, device["enrolledAt"].(string))
	if err != nil {
		t.Fatal(err)
	}
	began := maxTime(start, enrolledAt.UTC().Truncate(time.Second)).Add(time.Minute)
	at := began.Add(time.Hour + time.Second)
	clock.Store(at.Unix())
	workout := modelWorkout(uuid.New(), 37, began, began.Add(time.Hour), 3_600_000)
	workout["distanceMetres"] = "10000.000"
	syncRequest := map[string]any{"requestId": uuid.NewString(), "deviceId": device["deviceId"], "installationId": installation, "observedAt": at.Format(time.RFC3339Nano),
		"days": []map[string]any{{"gameDate": at.In(zone).Format(time.DateOnly), "steps": 10900}}, "workoutsAvailable": true, "workouts": []map[string]any{workout}}
	synced := call("POST", "/v1/activity/sync", syncRequest, 200)
	if synced["activitySteps"] != "10000" || synced["workouts"].([]any)[0].(map[string]any)["newlyEligibleMinutes"] != "10" {
		t.Fatal(synced)
	}
	doc := read()
	for _, key := range []string{"steps_1000", "special_day_10000", "special_run_10km", "special_workout_60min", "event_go_event_growth"} {
		if entry := findMilestone(t, doc, key); entry["eligible"] != true {
			t.Fatal(entry)
		}
	}
	if lower := findMilestone(t, doc, "special_run_5km"); lower["eligible"] != false || lower["supersededBy"] != "special_run_10km" {
		t.Fatal(lower)
	}
	if dur := findMilestone(t, doc, "special_workout_60min"); dur["progress"] != "60" {
		t.Fatal(dur)
	}
	runClaim := call("POST", claimPath("special_run_10km"), map[string]string{"requestId": uuid.NewString()}, 200)
	if runClaim["gemBalance"] != "1" || !reflect.DeepEqual(runClaim["supersededMilestoneIds"], []any{"special_run_5km"}) {
		t.Fatal(runClaim)
	}
	bonusClaim := call("POST", claimPath("special_days_30"), map[string]string{"requestId": uuid.NewString()}, 200)
	if bonusClaim["gemsEarned"] != "5" || bonusClaim["gemBalance"] != "6" {
		t.Fatal(bonusClaim)
	}

	visitorInstallation := uuid.NewString()
	session := call("POST", "/v1/me/visitor-sessions", map[string]string{"requestId": uuid.NewString(), "installationId": visitorInstallation}, 200)
	opportunity := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_opportunities(id,garden_id,session_id,context_id,rule_version,slot,issued_at,expires_at,tokens,status)
		VALUES($1,$2,$3,$4,'development-visitors-v1',$5,$6,$7,1,'issued')`, opportunity, garden, session["session"].(map[string]any)["sessionId"],
		session["contextId"], at.Unix()/30-1, at.Add(-time.Second), at.Add(15*time.Second)); err != nil {
		t.Fatal(err)
	}
	call("POST", "/v1/me/visitor-opportunities/"+opportunity.String()+"/welcome", map[string]string{"requestId": uuid.NewString()}, 200)
	doc = read()
	if hosted := findMilestone(t, doc, "butterfly_1"); hosted["progress"] != "1" || hosted["eligible"] != true {
		t.Fatal(hosted)
	}
	if eventHosted := findMilestone(t, doc, "event_go_event_butterflies"); eventHosted["progress"] != "1" {
		t.Fatal(eventHosted)
	}
	var stateMinutes string
	var count, bonus int64
	if err := pool.QueryRow(ctx, `SELECT workout_minutes,(SELECT count(*) FROM milestone_claims WHERE owner_id=$1),
		(SELECT sum(amount) FROM milestone_bonus_grants WHERE owner_id=$1) FROM milestone_days WHERE owner_id=$1`, owner).
		Scan(&stateMinutes, &count, &bonus); err != nil || stateMinutes != "10" || count != 3 || bonus != 5 {
		t.Fatalf("minutes=%s claims=%d bonus=%d err=%v", stateMinutes, count, bonus, err)
	}
	clock.Store(start.Add(5 * time.Hour).Unix())
	after := read()
	if entry := findMilestone(t, after, "event_go_event_growth"); entry["eligible"] != false || entry["unavailableReason"] == nil {
		t.Fatal(entry)
	}
	call("POST", claimPath("event_go_event_growth"), map[string]string{"requestId": uuid.NewString()}, 409)
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	cutoff := time.Now().UTC().AddDate(0, 0, 8)
	if err := compactRequestHistory(ctx, tx, &cutoff); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var compacted bool
	if err := pool.QueryRow(ctx, "SELECT response IS NULL FROM api_requests WHERE user_id=$1 AND request_id=$2",
		owner, body["requestId"]).Scan(&compacted); err != nil || !compacted {
		t.Fatalf("milestone journal compacted = %v, error = %v", compacted, err)
	}
	recovery := call("POST", claimPath("steps_new_beginnings"), body, 200)
	if !reflect.DeepEqual(recovery, claimed) {
		t.Fatal(recovery)
	}
	exportRecoveryFixture(t, "milestone-claim", recovery)
}

func TestNativeLegacyMilestoneKeepsPriorFundingAfterActivation(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	if _, err := pool.Exec(ctx, "UPDATE game_catalogue SET version='woodland-v1' WHERE id=1"); err != nil {
		t.Fatal(err)
	}
	dev, err := DevelopmentVerifier("test", "legacy-milestone-test-development-key")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("legacy-milestones")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		r, _ := testCall(t, api, method, path, token, body, map[string]string{"X-Forest-Milestones": "1", "X-Forest-Recovery": "1", "X-Forest-Woodland": "1"}, status)
		return r
	}
	created := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, 200)
	owner := created["profile"].(map[string]any)["userId"]
	path := "/v1/me/milestones/first_movement/claim"
	request := map[string]string{"requestId": uuid.NewString()}
	call("POST", path, request, 409)
	if _, err := pool.Exec(ctx, "UPDATE player_progress SET activity_steps=1000 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}
	claimed := call("POST", path, request, 200)
	if claimed["tokensEarned"] != "300" || claimed["tokenBalance"] != "300" {
		t.Fatal(claimed)
	}
	seedMilestonePolicy(t, pool, time.Now().UTC().Add(-time.Hour))
	home := call("GET", "/v1/me/home-attention", nil, 200)
	if home["milestoneCount"] != float64(0) {
		t.Fatal(home)
	}
	after := call("GET", "/v1/me/collection?view=home", nil, 200)
	for _, key := range []string{"steps_1000", "steps_new_beginnings"} {
		row := findMilestone(t, after, key)
		if row["eligible"] != false || row["claimed"] != true || row["legacyMilestoneId"] != "first_movement" {
			t.Fatal(row)
		}
	}
	alias := call("POST", path, map[string]string{"requestId": uuid.NewString()}, 200)
	if !reflect.DeepEqual(alias, claimed) {
		t.Fatal(alias)
	}
	call("POST", "/v1/me/milestones/steps_new_beginnings/claim", map[string]string{"requestId": uuid.NewString()}, 409)
}

func TestMilestoneRollingWindowCountsLateDaysAtBothBoundaries(t *testing.T) {
	at := time.Date(2026, 11, 17, 0, 0, 0, 0, time.UTC)
	var days []time.Time
	for _, day := range []int{-14, -13, -8, -1, 0, 5, 6, 12, 13, 14} {
		days = append(days, at.AddDate(0, 0, day))
	}
	if best := milestoneRollingWindow(days, at); best != 5 {
		t.Fatalf("14-day window got %d active dates", best)
	}
}
