package server

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const testExpeditionTemplate = "forgotten-forest-observatory-v1"

func seedExpedition(t *testing.T, pool *pgxpool.Pool, month time.Time, launch *time.Time) {
	t.Helper()
	ctx := context.Background()
	raw, err := os.ReadFile("../../fixtures/expedition-test.json")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO expedition_templates(version,definition,published_at) VALUES($1,$2::jsonb,$3)`,
		testExpeditionTemplate, json.RawMessage(raw), month.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO expedition_schedule(month,template_version,published_at) VALUES($1,$2,$3)`,
		month, testExpeditionTemplate, month.Add(-time.Hour)); err != nil {
		t.Fatal(err)
	}
	if launch != nil {
		if _, err := pool.Exec(ctx, "INSERT INTO expedition_launches(month,starts_at) VALUES($1,$2)", month, *launch); err != nil {
			t.Fatal(err)
		}
	}
}

func expeditionQuest(t *testing.T, run map[string]any, id string) map[string]any {
	t.Helper()
	for _, q := range run["quests"].([]any) {
		quest := q.(map[string]any)
		if quest["id"] == id {
			return quest
		}
	}
	t.Fatalf("missing expedition quest %s", id)
	return nil
}

func TestNativeExpeditionRecursAndKeepsEvidenceAndRewardsSeparate(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	clockStart := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	month := expeditionMonth(clockStart)
	launch := clockStart.Add(30 * time.Minute).Add(250 * time.Millisecond)
	if !launch.AddDate(0, 0, 5).Before(month.AddDate(0, 1, 0)) {
		month = month.AddDate(0, 1, 0)
		launch = month.Add(12*time.Hour + 250*time.Millisecond)
	}
	seedExpedition(t, pool, month, &launch)
	dev, err := DevelopmentVerifier("test", "native-expedition-test-development-key")
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	clock.Store(clockStart.UnixMicro())
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return time.UnixMicro(clock.Load()).UTC()
	}}).Handler())
	t.Cleanup(api.Close)
	issue := func(subject string) string {
		t.Helper()
		token, err := dev.IssueDevelopmentToken(subject)
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	token := issue("native-expeditions")
	headers := map[string]string{"X-Forest-Expeditions": "1", "X-Forest-Item-Rotations": "1", "X-Forest-Recovery": "1"}
	call := func(method, path string, payload any, status int) map[string]any {
		t.Helper()
		r, _ := testCall(t, api, method, path, token, payload, headers, status)
		return r
	}
	created := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}, 200)
	owner := created["profile"].(map[string]any)["userId"].(string)
	garden := created["gardenId"].(string)
	const current = "/v1/me/expeditions/current"
	testCall(t, api, "GET", current, token, nil, nil, 426)
	if doc := call("GET", current, nil, 200); doc["current"] != nil {
		t.Fatal(doc)
	}
	installation := uuid.NewString()
	device := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(), "installationId": installation,
		"observedAt": clockStart.Format(time.RFC3339Nano), "steps": 900, "workoutsAvailable": true}, 200)["device"].(map[string]any)
	at := launch.AddDate(0, 0, 4).Add(time.Hour)
	clock.Store(at.UnixMicro())
	doc := call("GET", current, nil, 200)["current"].(map[string]any)
	run := doc["runId"].(string)
	if want := uuid.NewSHA1(uuid.NameSpaceURL, []byte("forest/expedition/"+owner+"/"+month.Format(time.DateOnly))).String(); run != want {
		t.Fatalf("run=%s want=%s", run, want)
	}
	coverage := doc["coverage"].([]any)
	first := coverage[0].(map[string]any)
	firstStart, err := time.Parse(time.RFC3339Nano, first["startsAt"].(string))
	if err != nil || !firstStart.Equal(launch) || len(coverage) != 5 {
		t.Fatal(coverage, err)
	}

	days := make([]map[string]any, 0, 3)
	for _, part := range coverage[:3] {
		row := part.(map[string]any)
		days = append(days, map[string]any{"gameDate": row["gameDate"], "startsAt": row["startsAt"], "through": row["through"],
			"steps": 11000, "workoutsComplete": true})
	}
	start := firstStart.Add(time.Minute)
	work := modelWorkout(uuid.New(), 52, start, start.Add(15*time.Minute), 900000)
	overlap := modelWorkout(uuid.New(), 52, start.Add(time.Minute), start.Add(16*time.Minute), 900000)
	body := map[string]any{"requestId": uuid.NewString(), "deviceId": device["deviceId"], "installationId": installation,
		"observedAt": at.Format(time.RFC3339Nano), "days": days, "workouts": []map[string]any{work, overlap}}
	runPath := "/v1/me/expeditions/" + run
	evidence := runPath + "/evidence"
	earliest := days[0]["startsAt"]
	days[0]["startsAt"] = launch.Add(-time.Millisecond).Format(time.RFC3339Nano)
	call("POST", evidence, body, 422)
	days[0]["startsAt"] = earliest
	accepted := call("POST", evidence, body, 200)
	if !reflect.DeepEqual(accepted, call("POST", evidence, body, 200)) {
		t.Fatal(accepted)
	}
	repeated := map[string]any{"requestId": uuid.NewString(), "deviceId": device["deviceId"], "installationId": installation,
		"observedAt": at.Format(time.RFC3339Nano), "days": days, "workouts": []map[string]any{
			work, overlap, modelWorkout(uuid.New(), 52, start, start.Add(15*time.Minute), 900000)}}
	if res := call("POST", evidence, repeated, 200); res["progressVersion"] != accepted["progressVersion"] {
		t.Fatal(res)
	}
	doc = call("GET", runPath, nil, 200)
	for _, id := range []string{"steps_days_3", "monthly_steps_30000"} {
		if q := expeditionQuest(t, doc, id); q["completedAt"] == nil || q["entitlement"] == nil {
			t.Fatal(q)
		}
	}
	if q := expeditionQuest(t, doc, "run_walk_sessions_3"); q["current"] != float64(1) {
		t.Fatal(q)
	}
	var credits, workouts, steps int64
	err = pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM activity_credits WHERE owner_id=$1),
		(SELECT count(*) FROM activity_workouts WHERE owner_id=$1),activity_steps FROM player_progress WHERE owner_id=$1`, owner).
		Scan(&credits, &workouts, &steps)
	if err != nil || credits != 0 || workouts != 0 || steps != 0 {
		t.Fatal(credits, workouts, steps, err)
	}

	if _, err := pool.Exec(ctx, `INSERT INTO item_definitions(id,version,display_name,description,rarity,asset_version,model_key,thumbnail_key,clearance_radius)
		VALUES('astronomers-satchel',1,'Satchel','Fixture','common','1.0.0','asset.usdz','image.png',0.52)`); err != nil {
		t.Fatal(err)
	}
	var item uuid.UUID
	var savedClaimPath string
	var savedClaim map[string]string
	var savedReceipt map[string]any
	for _, key := range []string{"steps_days_3", "monthly_steps_30000"} {
		quest := expeditionQuest(t, doc, key)
		entitlement := quest["entitlement"].(map[string]any)["id"].(string)
		route := runPath + "/rewards/" + entitlement + "/claim"
		claim := map[string]string{"requestId": uuid.NewString()}
		reward := call("POST", route, claim, 200)
		if !reflect.DeepEqual(reward, call("POST", route, claim, 200)) {
			t.Fatal(reward)
		}
		alias := map[string]string{"requestId": uuid.NewString()}
		replayed := call("POST", route, alias, 200)
		if replayed["requestId"] != alias["requestId"] || !reflect.DeepEqual(replayed["ownedItemIds"], reward["ownedItemIds"]) {
			t.Fatal(replayed)
		}
		if key == "steps_days_3" {
			item = uuid.MustParse(reward["ownedItemIds"].([]any)[0].(string))
		} else if reward["tokenBalance"] != "400" || reward["tokensEarned"] != "400" {
			t.Fatal(reward)
		} else {
			savedClaimPath, savedClaim, savedReceipt = route, claim, reward
		}
	}
	var resale, layoutState int64
	err = pool.QueryRow(ctx, `SELECT (SELECT token_value FROM item_valuations WHERE owned_item_id=$1),state_version FROM gardens WHERE id=$2`, item, garden).
		Scan(&resale, &layoutState)
	if err != nil || resale != 500 || layoutState != 1 {
		t.Fatal(resale, layoutState, err)
	}

	other := issue("other-expedition-account")
	testCall(t, api, "POST", "/v1/accounts/bootstrap", other, map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, headers, 200)
	testCall(t, api, "GET", runPath, other, nil, headers, 404)
	clock.Store(month.AddDate(0, 1, 2).UnixMicro())
	next := call("GET", current, nil, 200)
	if next["current"].(map[string]any)["runId"] == run || len(next["previous"].([]any)) != 1 ||
		next["previous"].([]any)[0].(map[string]any)["runId"] != run {
		t.Fatal(next)
	}
	page := call("GET", "/v1/me/expeditions?limit=1", nil, 200)
	cursor := page["nextCursor"].(string)
	past := call("GET", "/v1/me/expeditions?limit=1&before="+cursor, nil, 200)
	if len(past["runs"].([]any)) != 1 || past["runs"].([]any)[0].(map[string]any)["runId"] != run || past["nextCursor"] != nil {
		t.Fatal(past)
	}
	clock.Store(month.AddDate(0, 1, 7).UnixMicro())
	repeated["requestId"] = uuid.NewString()
	call("POST", evidence, repeated, 409)
	if !reflect.DeepEqual(accepted, call("POST", evidence, body, 200)) {
		t.Fatal("evidence receipt changed after expiry")
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	expire := time.Now().UTC().AddDate(0, 0, 8)
	if err := compactRequestHistory(ctx, tx, &expire); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	var compacted int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM api_requests
		WHERE user_id=$1 AND request_id IN ($2,$3) AND response IS NULL`, owner, savedClaim["requestId"], body["requestId"]).Scan(&compacted); err != nil || compacted != 2 {
		t.Fatalf("expedition journals compacted = %d, error = %v", compacted, err)
	}
	claimReplay := call("POST", savedClaimPath, savedClaim, 200)
	evidenceReplay := call("POST", evidence, body, 200)
	if !reflect.DeepEqual(claimReplay, savedReceipt) || !reflect.DeepEqual(evidenceReplay, accepted) {
		t.Fatal(claimReplay, evidenceReplay)
	}
	exportRecoveryFixture(t, "expedition-claim", claimReplay)
	exportRecoveryFixture(t, "expedition-evidence", evidenceReplay)
}

func TestExpeditionEvidenceDigestMatchesReference(t *testing.T) {
	body := `{"requestId":"98353819-b373-4b3a-969e-3f77ec5dae56","deviceId":"60f52339-ac07-4f1c-934e-c2af25ddf50e",
		"installationId":"3ebc07fa-8cdb-4c97-8567-c16ee1efbd1b","observedAt":"2026-11-28T09:00:00.125+08:00",
		"days":[{"gameDate":"2026-11-28","startsAt":"2026-11-28T00:00:00.002Z","through":"2026-11-28T01:00:00.125Z"}]}`
	r := httptest.NewRequest("POST", "/", strings.NewReader(body))
	e, err := parseExpeditionEvidence(r, "expedition_evidence:7c126a42-d0e9-4f77-826e-ce0bc53e4017")
	if err != nil || e.digest != "592a5a45dd74dd9bf6ea01e64f34292e6cf5c1f95951db0b8d8f6d052f82c335" {
		t.Fatal(e.digest, err)
	}
}

func TestNativeExpeditionGardenWelcomeAndMilestones(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	at := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	seedExpedition(t, pool, expeditionMonth(at), nil)
	dev, err := DevelopmentVerifier("test", "expedition-observers-local-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time { return at }}).Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("expedition-observers")
	if err != nil {
		t.Fatal(err)
	}
	headers := map[string]string{"X-Forest-Expeditions": "1", "X-Forest-Items": "1", "X-Forest-Item-Rotations": "1", "X-Forest-Recovery": "1"}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		doc, _ := testCall(t, api, method, path, token, body, headers, status)
		return doc
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	garden := account["gardenId"].(string)
	herb := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO owned_plants(id,owner_id,species_id,variant_id,growth_profile_id,growth_profile_version,
		behaviour_profile_id,behaviour_profile_version,attraction_profile_id,attraction_profile_version,
		acquisition_source,acquisition_reference,growth_micro_units,clearance_radius)
		VALUES($1,$2,'moonwillow','standard','dev_moonwillow_growth',1,'dev_moonwillow_behaviour',1,
		'dev_moonwillow_attraction',1,'test',$3,400000000,1.1)`, herb, owner, herb.String()); err != nil {
		t.Fatal(err)
	}
	plants := []any{account["starterPlantId"], addResalablePlant(t, pool, owner, 100_000_000), herb,
		addResalablePlant(t, pool, owner, 1_000_000_000)}
	items := seedWaterItems(t, pool, owner, "worldseed-orrery", stepGrantFamily, alignmentProfile, 4)
	var planting, placing []map[string]any
	for i, id := range plants {
		planting = append(planting, map[string]any{"action": "plant", "plantId": id, "x": 1 + 3*(i%3), "y": 1.2 + 3*float64(i/3), "rotationDegrees": 0})
	}
	points := [][2]int{{4, 4}, {7, 4}, {1, 7}, {4, 7}}
	for i, id := range items {
		placing = append(placing, map[string]any{"action": "place", "itemId": id, "x": points[i][0], "y": points[i][1], "rotationDegrees": 0})
	}
	call("POST", "/v1/me/garden/edits", map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2",
		"expectedLayoutVersion": 0, "actions": planting, "itemActions": placing}, 200)
	const current = "/v1/me/expeditions/current"
	doc := call("GET", current, nil, 200)["current"].(map[string]any)
	if doc["completedCount"] != float64(2) || expeditionQuest(t, doc, "items_together_4")["completedAt"] == nil ||
		expeditionQuest(t, doc, "all_stages_together")["completedAt"] == nil {
		t.Fatal(doc)
	}
	session := call("POST", "/v1/me/visitor-sessions", map[string]string{"requestId": uuid.NewString(), "installationId": uuid.NewString()}, 200)
	arrival := uuid.New()
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_opportunities(id,garden_id,session_id,context_id,rule_version,slot,issued_at,expires_at,tokens,status)
		VALUES($1,$2,$3,$4,'development-visitors-v1',$5,$6,$7,1,'issued')`, arrival, garden, session["session"].(map[string]any)["sessionId"],
		session["contextId"], at.Unix()/30-1, at.Add(-time.Second), at.Add(15*time.Second)); err != nil {
		t.Fatal(err)
	}
	welcome := map[string]string{"requestId": uuid.NewString()}
	welcomePath := "/v1/me/visitor-opportunities/" + arrival.String() + "/welcome"
	call("POST", welcomePath, welcome, 200)
	call("POST", welcomePath, welcome, 200)
	doc = call("GET", current, nil, 200)["current"].(map[string]any)
	for _, key := range []string{"active_butterflies_100", "tree_herb_butterflies_50"} {
		if q := expeditionQuest(t, doc, key); q["current"] != float64(1) {
			t.Fatal(q)
		}
	}
	run := uuid.MustParse(doc["runId"].(string))
	complete := func(updates ...expeditionUpdate) {
		t.Helper()
		tx, err := pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, "SELECT id FROM users WHERE id=$1 FOR UPDATE", owner); err != nil {
			t.Fatal(err)
		}
		if err := setExpeditionProgress(ctx, tx, run, nil, at, updates); err != nil {
			t.Fatal(err)
		}
		if err := tx.Commit(ctx); err != nil {
			t.Fatal(err)
		}
	}
	complete(expeditionCount("steps_days_3", 3), expeditionCount("monthly_steps_30000", 30000))
	doc = call("GET", current, nil, 200)["current"].(map[string]any)
	if doc["completedCount"] != float64(4) || len(doc["rewards"].([]any)) != 5 {
		t.Fatal(doc)
	}
	complete(expeditionCount("active_butterflies_100", 100), expeditionCount("tree_herb_butterflies_50", 50),
		expeditionCount("run_walk_sessions_3", 3), expeditionCount("packs_opened_3", 3),
		expeditionUpdate{Key: "copies_advanced_4", Identities: []string{herb.String(), herb.String(), uuid.NewString(), uuid.NewString(), uuid.NewString()}})
	doc = call("GET", current, nil, 200)["current"].(map[string]any)
	if doc["completedCount"] != float64(9) || len(doc["rewards"].([]any)) != 11 {
		t.Fatal(doc)
	}
	complete(expeditionCount("items_together_4", 0), expeditionContribution("copies_advanced_4", herb))
	after := call("GET", current, nil, 200)["current"].(map[string]any)
	if after["progressVersion"] != doc["progressVersion"] || len(after["rewards"].([]any)) != 11 {
		t.Fatal(after)
	}
}
