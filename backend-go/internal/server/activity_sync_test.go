package server

import (
	"context"
	"encoding/json"
	"math/big"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestActivitySyncKeepsReferenceRequestDigest(t *testing.T) {
	body := `{"requestId":"98353819-b373-4b8e-969e-3f77ec5dae56","deviceId":"60f52339-ac07-4f1c-934e-c2af25ddf50e",
		"installationId":"3ebc07fa-8cdb-4c97-8567-c16ee1efbd1b","observedAt":"2026-11-27T17:36:21.1245+08:00",
		"workoutsAvailable":true,"workouts":[],"days":[
			{"gameDate":"2026-11-27","steps":1100,"walkingRunningDistanceMetres":"1500.050","activeEnergyKcal":null},
			{"gameDate":"2026-11-26","steps":null,"flightsClimbed":0}]}`
	req := httptest.NewRequest("POST", "/v1/activity/sync", strings.NewReader(body))
	input, err := parseActivitySync(req)
	// The reference value comes from SyncActivity and services.request_hash.
	if err != nil || input.digest != "8b5433197ba18c22dc9b73e371659f723ba84583f45648738ea13e4e63ef048b" {
		t.Fatal(input.digest, err)
	}
}

func TestActivitySyncDayWatermarksAndGrowth(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	if _, err := pool.Exec(ctx, `INSERT INTO level_benefits_policy VALUES ('level-benefits-v1','1970-01-02');
		INSERT INTO economy_configs (version,effective_at,is_fixture,rules)
		SELECT 'go-sync-capped','1970-01-02',true,jsonb_set(rules,'{metrics}', '{
			"steps":{"normalisation":"1000","water_micro_units":10000000,"daily_cap":15000},
			"walking_running_distance_km":{"normalisation":"1","water_micro_units":100,"daily_cap":1},
			"active_energy_kcal":{"normalisation":"1","water_micro_units":100},
			"flights_climbed":{"normalisation":"1","water_micro_units":100,"daily_cap":2}
		}'::jsonb) FROM economy_configs WHERE version='development-neutral-v1'`); err != nil {
		t.Fatal(err)
	}
	dev, err := DevelopmentVerifier("test", "activity-sync-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	var clock atomic.Int64
	clock.Store(start.Unix())
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time { return time.Unix(clock.Load(), 0).UTC() }}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("native-go-sync")
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
	plant := account["starterPlantId"].(string)
	call("POST", "/v1/me/garden/edits", map[string]any{"requestId": uuid.NewString(), "expectedLayoutVersion": 0,
		"catalogVersion": "development-woodland-v2", "actions": []map[string]any{{"action": "plant", "plantId": plant, "x": 2, "y": 2, "rotationDegrees": 0}}}, 200)
	installation := uuid.NewString()
	enrolled := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(),
		"installationId": installation, "observedAt": start.Format(time.RFC3339Nano)}, 200)
	deviceRow := enrolled["device"].(map[string]any)
	device := deviceRow["deviceId"]
	enrolledAt, err := time.Parse(time.RFC3339Nano, deviceRow["enrolledAt"].(string))
	if err != nil {
		t.Fatal(err)
	}
	// Enrollment uses the database clock. Move the test clock past it before the
	// first baseline, even if the database was busy during setup.
	start = maxTime(start, enrolledAt.UTC().Truncate(time.Second).Add(time.Second))
	clock.Store(start.Unix())
	const path = "/v1/activity/sync"
	newBody := func(at time.Time, steps any) map[string]any {
		return map[string]any{"requestId": uuid.NewString(), "deviceId": device, "installationId": installation, "observedAt": at.Format(time.RFC3339Nano),
			"days": []map[string]any{{"gameDate": at.Format(time.DateOnly), "steps": steps}}, "workoutsAvailable": true, "workouts": []any{}}
	}
	metricBody := func(at time.Time, steps any, distance, energy string, flights int) map[string]any {
		b := newBody(at, steps)
		d := b["days"].([]map[string]any)[0]
		d["walkingRunningDistanceMetres"], d["activeEnergyKcal"], d["flightsClimbed"] = distance, energy, flights
		return b
	}
	baseline := call("POST", path, metricBody(start, 900, "1000.000", "10.125", 4), 200)
	d := baseline["days"].([]any)[0].(map[string]any)
	if d["baselineEstablished"] != true || d["newlyEligibleSteps"] != float64(0) || baseline["recapId"] != nil ||
		baseline["device"].(map[string]any)["ready"] != true {
		t.Fatal(baseline)
	}
	at := start.Add(10 * time.Second)
	clock.Store(at.Unix())
	body := metricBody(at, 10900, "2500.000", "11.375", 7)
	first := call("POST", path, body, 200)
	d = first["days"].([]any)[0].(map[string]any)
	metrics := d["metrics"].(map[string]any)
	distance := metrics["walking_running_distance_km"].(map[string]any)
	flights := metrics["flights_climbed"].(map[string]any)
	garden := first["garden"].(map[string]any)
	grown := garden["plants"].([]any)[0].(map[string]any)
	if first["activitySteps"] != "10000" || first["progression"].(map[string]any)["level"] != float64(2) ||
		first["wallet"].(map[string]any)["gemBalance"] != "1" || grown["growthMicroUnits"] != "100000000" ||
		grown["growthStage"] != "seedling" || garden["stateVersion"] != float64(2) || first["recapId"] == nil ||
		distance["newlyEligible"] != "3/2" || distance["waterQuantity"] != "1" || flights["waterQuantity"] != "2" ||
		first["activityMetrics"].(map[string]any)["active_energy_kcal"] != "5/4" {
		t.Fatal(first)
	}
	if r := call("POST", path, body, 200); !reflect.DeepEqual(r, first) {
		t.Fatal("full replay changed its receipt", r)
	}
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response=NULL WHERE user_id=$1 AND request_id=$2", owner, body["requestId"]); err != nil {
		t.Fatal(err)
	}
	r := call("POST", path, body, 200)["recovery"].(map[string]any)
	if r["operation"] != "activity_sync" || r["outcome"].(map[string]any)["recapId"] != first["recapId"] {
		t.Fatal(r)
	}
	body["days"].([]map[string]any)[0]["steps"] = 12345
	call("POST", path, body, 409)
	clock.Store(start.Add(20 * time.Second).Unix())
	lower := call("POST", path, newBody(start.Add(20*time.Second), 500), 200)
	if lower["recapId"] != nil || lower["activitySteps"] != "10000" || lower["garden"].(map[string]any)["stateVersion"] != float64(2) {
		t.Fatal(lower)
	}
	clock.Store(start.Add(30 * time.Second).Unix())
	capped := call("POST", path, newBody(start.Add(30*time.Second), 21000), 200)
	d = capped["days"].([]any)[0].(map[string]any)
	if d["waterSteps"] != float64(5000) || d["newlyEligibleSteps"] != float64(10100) || capped["activitySteps"] != "20100" ||
		capped["garden"].(map[string]any)["plants"].([]any)[0].(map[string]any)["growthMicroUnits"] != "150000000" {
		t.Fatal(capped)
	}
	visitors := call("GET", "/v1/me/visitors", nil, 200)
	if visitors["totalAttractionMicroUnits"] != "5000000" || visitors["capacity"] != float64(750) {
		t.Fatal(visitors)
	}
	if call("GET", "/v1/me/account-summary", nil, 200)["levelUpNotice"] == nil {
		t.Fatal("level notice missing")
	}
	discovery := call("GET", "/v1/me/catalog-discovery", nil, 200)
	if discovery["discoveryVersion"] != float64(2) {
		t.Fatal(discovery)
	}

	tomorrow := calendarDate(start, time.UTC).AddDate(0, 0, 1)
	if _, err := pool.Exec(ctx, `INSERT INTO economy_configs (version,effective_at,is_fixture,rules)
		SELECT 'go-sync-next-day',$1,true,jsonb_set(rules,'{metrics,steps,water_micro_units}','20000000')
		FROM economy_configs WHERE version='go-sync-capped'`, tomorrow); err != nil {
		t.Fatal(err)
	}
	at = tomorrow.Add(time.Minute)
	clock.Store(at.Unix())
	twoDays := newBody(at, 1000)
	twoDays["days"] = append(twoDays["days"].([]map[string]any), map[string]any{"gameDate": start.Format(time.DateOnly), "steps": 21000})
	next := call("POST", path, twoDays, 200)
	results := next["days"].([]any)
	if results[0].(map[string]any)["ruleVersion"] != "go-sync-capped" || results[1].(map[string]any)["ruleVersion"] != "go-sync-next-day" ||
		next["activitySteps"] != "21100" || next["garden"].(map[string]any)["plants"].([]any)[0].(map[string]any)["growthMicroUnits"] != "170000000" {
		t.Fatal(next)
	}
	var credits, traces, recaps, gems int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM activity_credits WHERE owner_id=$1),
		(SELECT count(*) FROM plant_growth_credits c JOIN growth_provenance p ON p.id=c.provenance_id
		 WHERE c.plant_id=$2 AND c.context ? 'awardedMicroUnits' AND p.payload#>>'{skills,waterFactor}'='1'),
		(SELECT count(*) FROM reward_recaps WHERE owner_id=$1),
		(SELECT sum(amount) FROM gem_grants WHERE owner_id=$1)`, owner, plant).Scan(&credits, &traces, &recaps, &gems); err != nil ||
		credits != 3 || traces != 3 || recaps != 3 || gems != 2 {
		t.Fatal(credits, traces, recaps, gems, err)
	}

	bad := newBody(at, 1200)
	bad["installationId"] = uuid.NewString()
	call("POST", path, bad, 409)
	call("POST", path, newBody(at.Add(10*time.Minute), 1200), 422)
	withWorkout := newBody(at, 1200)
	withWorkout["workouts"] = []map[string]any{{"workoutId": uuid.NewString()}}
	if b := call("POST", path, withWorkout, 422); b["error"].(map[string]any)["code"] != "invalid_request" {
		t.Fatal(b)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO milestone_policies VALUES ('go-sync-guard','1970-01-02',true,'{}')`); err != nil {
		t.Fatal(err)
	}
	rejected := call("POST", path, newBody(at, 1200), 503)
	if rejected["error"].(map[string]any)["code"] != "activity_milestones_unavailable" ||
		call("GET", "/v1/me/activity", nil, 200)["activitySteps"] != "21100" {
		t.Fatal(rejected)
	}
}

func TestActivityGrowthCarriesNumericLegacyRemainder(t *testing.T) {
	p := activityPlant{growth: 0, maximum: 6, thresholds: map[string]int64{"sprout": 0, "seedling": 2, "young": 4, "adult": 6},
		coefficients: map[string]json.RawMessage{"steps": json.RawMessage("1.0")},
		fraction:     map[string]json.RawMessage{"numerator": json.RawMessage("1"), "denominator": json.RawMessage("3")}}
	credit := uuid.New()
	day := syncDay{syncDayResult: syncDayResult{CreditID: &credit, WaterSteps: 1}, rates: map[string]activityRate{"steps": {Normalisation: "3", Water: 1}}}
	if _, _, err := p.applyActivity(day, gardenStrategy{}, nil); err != nil || p.growth != 0 || string(p.fraction["numerator"]) != "\"2\"" {
		t.Fatal(p, err)
	}
	if _, _, err := p.applyActivity(day, gardenStrategy{}, nil); err != nil || p.growth != 1 || len(p.fraction) != 0 {
		t.Fatal(p, err)
	}
}

func TestActivityGrowthUsesPinnedMetricConversion(t *testing.T) {
	const energy = "active_energy_kcal"
	p := activityPlant{maximum: 100, thresholds: map[string]int64{"sprout": 0, "seedling": 25, "young": 50, "adult": 100},
		coefficients: map[string]json.RawMessage{energy: json.RawMessage("0.5")},
		conversions:  map[string]activityRate{energy: {Normalisation: "2", Water: 20}}}
	credit := uuid.New()
	day := syncDay{syncDayResult: syncDayResult{CreditID: &credit}, quantities: map[string]*big.Rat{energy: big.NewRat(3, 2)},
		rates: map[string]activityRate{"steps": {Normalisation: "1", Water: 1}, energy: {Normalisation: "1", Water: 100}}}
	trace, _, err := p.applyActivity(day, gardenStrategy{}, nil)
	if err != nil || p.growth != 7 || trace.Context["calculatedMicroUnits"] != "15/2" ||
		string(p.fraction["numerator"]) != "\"1\"" || string(p.fraction["denominator"]) != "\"2\"" {
		t.Fatal(p, trace, err)
	}
}
