package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func TestRecordedWorkoutRequestMatchesReferenceDigest(t *testing.T) {
	body := `{"requestId":"98353819-b373-4b8e-969e-3f77ec5dae56","deviceId":"60f52339-ac07-4f1c-934e-c2af25ddf50e",
		"installationId":"3ebc07fa-8cdb-4c97-8567-c16ee1efbd1b","observedAt":"2026-11-27T17:36:21.1245+08:00",
		"workoutsAvailable":true,"workouts":[{"workoutId":"98fd3c7b-4276-460a-93dd-c3fb6573263a","originalType":37,
		"start":"2026-11-27T17:25:00+08:00","end":"2026-11-27T17:29:00+08:00","durationMilliseconds":180000,
		"sourceBundleIdentifier":"tracker.é","hasSegments":true,"segments":[{"originalType":13,"start":"2026-11-27T09:25:01Z",
		"end":"2026-11-27T09:27:01Z","durationMilliseconds":100000}]}],"days":[{"gameDate":"2026-11-27","steps":null}]}`
	input, err := parseActivitySync(httptest.NewRequest("POST", "/v1/activity/sync", strings.NewReader(body)))
	// Computed by the reference SyncActivity DTO and request hash.
	if err != nil || input.digest != "5e25e417f57c9f49de6303eb90c9a0c85cbdebba33a872b80ecbf72883e7baae" {
		t.Fatal(input.digest, err)
	}
}

func TestRecordedWorkoutUploadAcceptsLargeValidBatch(t *testing.T) {
	start := time.Date(2026, 11, 27, 8, 0, 0, 0, time.UTC)
	records := make([]map[string]any, 501)
	for i := range records {
		records[i] = modelWorkout(uuid.New(), 37, start, start.Add(time.Minute), 60_000)
	}
	body := map[string]any{"requestId": uuid.New(), "installationId": uuid.New(), "deviceId": uuid.New(),
		"observedAt": start.Add(time.Hour).Format(time.RFC3339), "workoutsAvailable": true,
		"days": []map[string]any{{"gameDate": start.Format(time.DateOnly), "steps": nil}}}
	for _, count := range []int{500, 501} {
		body["workouts"] = records[:count]
		wire, err := json.Marshal(body)
		if err != nil || len(wire) <= 65536 {
			t.Fatal(len(wire), err)
		}
		request := httptest.NewRequest("POST", "/v1/activity/sync", bytes.NewReader(wire))
		input, err := parseActivitySync(request)
		if count == 500 && (err != nil || len(input.workouts) != 500) || count == 501 && err != invalid {
			t.Fatal(count, len(input.workouts), err)
		}
	}
}

const workoutPlantBehaviour = "go-recorded-workout"

func seedWorkoutBehaviour(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), `INSERT INTO growth_rule_profiles (id,version,rules) VALUES($1,1,'{
		"schemaVersion":3,"metricMultipliers":{"steps":1,"workout_minutes.*":1},"conditionalModifiers":[],"gardenEffects":[],
		"conversionRates":{"workout_minutes.*":{"normalisation":"1","water_micro_units":1000000}}}'::jsonb)`, workoutPlantBehaviour); err != nil {
		t.Fatal(err)
	}
}

func modelWorkout(id uuid.UUID, kind int, start, end time.Time, millis int64) map[string]any {
	return map[string]any{"workoutId": id, "originalType": kind, "start": start.Format(time.RFC3339Nano),
		"end": end.Format(time.RFC3339Nano), "durationMilliseconds": millis, "sourceBundleIdentifier": "local.synthetic.tracker"}
}

func TestRecordedWorkoutSyncCrossesDaysAndDeduplicatesCoverage(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	seedWorkoutBehaviour(t, pool)
	if _, err := pool.Exec(ctx, `INSERT INTO economy_configs (version,effective_at,is_fixture,rules)
		SELECT 'go-workouts-capped','1970-01-02',true,jsonb_set(rules||'{"workout_daily_cap_seconds":900}'::jsonb,
			'{metrics}',(rules->'metrics')||'{"workout_minutes.running":{"normalisation":"1","water_micro_units":7},
			"workout_minutes.cycling":{"normalisation":"1","water_micro_units":11},
			"workout_minutes.swimming":{"normalisation":"1","water_micro_units":19}}'::jsonb)
		FROM economy_configs WHERE version='development-neutral-v1'`); err != nil {
		t.Fatal(err)
	}
	dev, err := DevelopmentVerifier("test", "recorded-workout-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	clock.Store(time.Now().UTC().Truncate(time.Second).Unix())
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time { return time.Unix(clock.Load(), 0).UTC() }}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("go-native-recorded-workouts")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		r, _ := testCall(t, api, method, path, token, body, gardenHeaders, status)
		return r
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	plant := addResalablePlantWithBehaviour(t, pool, owner, 0, workoutPlantBehaviour)
	call("POST", "/v1/me/garden/edits", map[string]any{"requestId": uuid.NewString(), "expectedLayoutVersion": 0,
		"catalogVersion": "development-woodland-v2", "actions": []map[string]any{{"action": "plant", "plantId": plant, "x": 2, "y": 2, "rotationDegrees": 0}}}, 200)
	installation := uuid.New()
	enrol := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(),
		"installationId": installation, "observedAt": time.Now().UTC().Format(time.RFC3339Nano), "steps": 100, "workoutsAvailable": true}, 200)
	device := enrol["device"].(map[string]any)
	start, err := time.Parse(time.RFC3339Nano, device["enrolledAt"].(string))
	if err != nil {
		t.Fatal(err)
	}
	midnight := calendarDate(start, time.UTC).AddDate(0, 0, 2)
	at := midnight.Add(36 * time.Minute)
	clock.Store(at.Unix())
	body := func(records ...map[string]any) map[string]any {
		return map[string]any{"requestId": uuid.NewString(), "deviceId": device["deviceId"], "installationId": installation,
			"observedAt": at.Format(time.RFC3339Nano), "workoutsAvailable": true, "workouts": records,
			"days": []map[string]any{{"gameDate": at.Format(time.DateOnly), "steps": nil}}}
	}
	runID, cycleID := uuid.New(), uuid.New()
	run := modelWorkout(runID, 37, midnight.Add(-10*time.Minute), midnight.Add(20*time.Minute), 15*60_000)
	cycle := modelWorkout(cycleID, 13, midnight.Add(5*time.Minute), midnight.Add(35*time.Minute), 20*60_000)
	cycle["hasSegments"] = true
	segment := func(from, to int) map[string]any {
		return map[string]any{"originalType": 13, "start": midnight.Add(time.Duration(from) * time.Minute).Format(time.RFC3339Nano),
			"end": midnight.Add(time.Duration(to) * time.Minute).Format(time.RFC3339Nano), "durationMilliseconds": 10 * 60_000}
	}
	cycle["segments"] = []map[string]any{segment(20, 30), segment(5, 15)}
	manualID, futureID, oldID := uuid.New(), uuid.New(), uuid.New()
	manual := modelWorkout(manualID, 37, midnight.Add(30*time.Minute), midnight.Add(35*time.Minute), 5*60_000)
	manual["wasUserEntered"] = true
	future := modelWorkout(futureID, 37, midnight.Add(40*time.Minute), midnight.Add(41*time.Minute), 60_000)
	old := modelWorkout(oldID, 37, start.Add(-3*time.Minute), start.Add(-2*time.Minute), 60_000)

	const path = "/v1/activity/sync"
	request := body(cycle, run, manual, future, old)
	result := call("POST", path, request, 200)
	receipts := result["workouts"].([]any)
	want := map[string][2]string{
		runID.String(): {"accepted", "15"}, cycleID.String(): {"accepted", "5"}, manualID.String(): {"manual_excluded", "0"},
		futureID.String(): {"future_excluded", "0"}, oldID.String(): {"before_baseline_or_window", "0"},
	}
	if len(receipts) != len(want) || receipts[1].(map[string]any)["workoutId"] != runID.String() {
		t.Fatal(receipts)
	}
	for _, v := range receipts {
		obj := v.(map[string]any)
		want := want[obj["workoutId"].(string)]
		if obj["status"] != want[0] || obj["newlyEligibleMinutes"] != want[1] {
			t.Fatal(receipts)
		}
	}
	grown := result["garden"].(map[string]any)["plants"].([]any)[0].(map[string]any)
	metrics := result["activityMetrics"].(map[string]any)
	if result["activitySteps"] != "0" || grown["growthMicroUnits"] != "20000000" ||
		metrics["workout_minutes.running"] != "15" || metrics["workout_minutes.cycling"] != "5" {
		t.Fatal(result)
	}
	days := result["days"].([]any)
	first := days[0].(map[string]any)
	last := days[1].(map[string]any)
	if len(days) != 2 || first["gameDate"] != midnight.AddDate(0, 0, -1).Format(time.DateOnly) || first["available"] != false ||
		first["metrics"].(map[string]any)["workout_minutes.running"].(map[string]any)["waterQuantity"] != "5" ||
		last["metrics"].(map[string]any)["workout_minutes.running"].(map[string]any)["waterQuantity"] != "10" {
		t.Fatal(days)
	}
	recap := call("GET", "/v1/me/reward-recaps", nil, 200)["recaps"].([]any)[0].(map[string]any)["payload"].(map[string]any)
	if !reflect.DeepEqual(recap["workouts"], receipts) {
		t.Fatal(recap)
	}
	if replay := call("POST", path, request, 200); !reflect.DeepEqual(replay, result) {
		t.Fatal("same request changed its receipt")
	}
	overlap := modelWorkout(uuid.New(), 46, midnight.Add(25*time.Minute), midnight.Add(30*time.Minute), 5*60_000)
	duplicate := call("POST", path, body(overlap, run), 200)
	followUp := duplicate["workouts"].([]any)
	if followUp[0].(map[string]any)["status"] != "already_processed" || followUp[1].(map[string]any)["status"] != "no_new_eligible_minutes" ||
		duplicate["recapId"] != nil || !reflect.DeepEqual(duplicate["activityMetrics"], metrics) {
		t.Fatal(duplicate)
	}
	var imported, buckets, credits int
	var covered [][2]string
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM activity_workouts WHERE owner_id=$1),
		(SELECT count(*) FROM activity_workout_days WHERE owner_id=$1),
		(SELECT count(*) FROM activity_credits WHERE owner_id=$1),
		(SELECT covered_intervals FROM activity_workout_days WHERE owner_id=$1 AND game_date=$2)`, owner, midnight).
		Scan(&imported, &buckets, &credits, &covered); err != nil || imported != 6 || buckets != 2 || credits != 2 ||
		len(covered) != 1 || covered[0][1] != pythonTime(midnight.Add(30*time.Minute)) {
		t.Fatal(imported, buckets, credits, covered, err)
	}
	bad := modelWorkout(uuid.New(), 37, midnight, midnight.Add(time.Second), 1001)
	call("POST", path, body(bad), 422)
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM activity_workouts WHERE owner_id=$1", owner).Scan(&imported); err != nil || imported != 6 {
		t.Fatal(imported, err)
	}

	at = midnight.AddDate(0, 0, 1).Add(10 * time.Minute)
	clock.Store(at.Unix())
	newRecord := modelWorkout(uuid.New(), 37, at.Add(-2*time.Minute), at.Add(-time.Minute), 60_000)
	outcomes := make(chan string, 2)
	t.Run("overlapping requests", func(t *testing.T) {
		for i := range 2 {
			t.Run(fmt.Sprint(i), func(t *testing.T) {
				t.Parallel()
				value, _ := testCall(t, api, "POST", path, token, body(newRecord), gardenHeaders, 200)
				outcomes <- value["workouts"].([]any)[0].(map[string]any)["status"].(string)
			})
		}
	})
	close(outcomes)
	counts := make(map[string]int)
	for value := range outcomes {
		counts[value]++
	}
	if counts["accepted"] != 1 || counts["already_processed"] != 1 {
		t.Fatal(counts)
	}
}

func TestWorkerTransactionLockHonorsExistingSessionLock(t *testing.T) {
	pool := localDatabase(t)
	ctx := context.Background()
	holder, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Release()
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_lock($1)", workerLock); err != nil {
		t.Fatal(err)
	}
	worker := httptest.NewServer((&Server{Pool: pool}).WorkerHandler())
	t.Cleanup(worker.Close)
	result, _ := testCall(t, worker, "POST", "/tasks/shop", "", nil, nil, 200)
	if result["status"] != "skipped" || result["reason"] != "busy" {
		t.Fatal(result)
	}
	if _, err := holder.Exec(ctx, "SELECT pg_advisory_unlock($1)", workerLock); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		result, _ = testCall(t, worker, "POST", "/tasks/shop", "", nil, nil, 200)
		if result["status"] != "ready" {
			t.Fatal(result)
		}
	}
}
