package server

import (
	"context"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const alignmentProfile = `{"effects":[],"triggeredGrants":[
	{"type":"daily_placed_steps_flat_water","family":"alignment_of_worlds","name":"Alignment of Worlds",
	"tiers":[{"steps":2000,"water":"3"},{"steps":4000,"water":"4"},{"steps":6000,"water":"5"}]}]}`

const rainProfile = `{"effects":[],"dailyGrant":{"family":"morning_rain","water":"2.5"}}`

func TestDailyWaterMidnightAcrossOffsetTransitions(t *testing.T) {
	for _, tc := range []struct{ zone, date, expected string }{
		{"America/Sao_Paulo", "2018-11-04", "2018-11-04T03:00:00Z"},
		{"America/Havana", "2021-11-07", "2021-11-07T04:00:00Z"},
	} {
		zone, err := time.LoadLocation(tc.zone)
		if err != nil {
			t.Fatal(err)
		}
		day, err := time.Parse(time.DateOnly, tc.date)
		if err != nil {
			t.Fatal(err)
		}
		if boundary := dailyWaterBoundary(day, zone); boundary.Format(time.RFC3339) != tc.expected {
			t.Fatalf("%s %s: obtained %s, want %s", tc.zone, tc.date, boundary, tc.expected)
		}
	}
}

func TestDailyWaterStopsAtAdultEvenWithHigherGrowthMaximum(t *testing.T) {
	plant := activityPlant{growth: 999_000_000, maximum: 1_500_000_000,
		thresholds: map[string]int64{"seedling": 100_000_000, "adult": 1_000_000_000}}
	var growth growthResult
	at := time.Now()
	award, err := growth.applyFlatWater(&plant, dailyWaterAmount, at)
	if err != nil || award.Awarded != 1_000_000 || growth.matured != 1 || plant.maturedAt == nil || !plant.maturedAt.Equal(at) {
		t.Fatalf("award=%#v matured=%d at=%v err=%v", award, growth.matured, plant.maturedAt, err)
	}
}

var itemWaterHeaders = map[string]string{
	"X-Forest-Items": "1", "X-Forest-Item-Commerce": "1", "X-Forest-Item-Rotations": "1",
	"X-Forest-Expeditions": "1", "X-Forest-Recovery": "1",
}

func seedWaterItems(t *testing.T, pool *pgxpool.Pool, owner, item, profile, rules string, count int) []string {
	t.Helper()
	ctx := context.Background()
	queries := []string{
		`INSERT INTO item_definitions (id,version,display_name,description,rarity,asset_version,model_key,thumbnail_key,clearance_radius)
		VALUES ($1,1,$1,'Fixture grant item','epic','1.0.0','models/grant.usdz','ui/grant.png',0.55)`,
		`INSERT INTO item_skill_profiles VALUES($1,1,$2::jsonb)`,
		`INSERT INTO item_skill_bindings VALUES($1,1,$2,1)`,
	}
	args := [][]any{{item}, {profile, rules}, {item, profile}}
	for i, query := range queries {
		if _, err := pool.Exec(ctx, query, args[i]...); err != nil {
			t.Fatal(err)
		}
	}
	items := make([]string, 0, count)
	for range count {
		id := uuid.NewString()
		if _, err := pool.Exec(ctx, `WITH identity AS (
			INSERT INTO item_identities(id,owner_id,item_id,item_version,source,reference,ordinal)
			VALUES ($1,$2,$3,1,'test',$1::uuid::text,0) RETURNING id,owner_id
		) INSERT INTO owned_items(id,owner_id) SELECT id,owner_id FROM identity`, id, owner, item); err != nil {
			t.Fatal(err)
		}
		items = append(items, id)
	}
	return items
}

func TestNativeStepTierWaterSharesProgressAndKeepsExistingReceipts(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "step-tier-local-signing-key-for-tests")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	zone := time.UTC
	if start.Hour() == 23 && start.Minute() >= 54 {
		zone, err = time.LoadLocation("Asia/Singapore")
		if err != nil {
			t.Fatal(err)
		}
	}
	gameDate := start.In(zone).Format(time.DateOnly)
	var seconds atomic.Int64
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return start.Add(time.Duration(seconds.Load()) * time.Second)
	}}).Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("step-tier-test")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any) map[string]any {
		t.Helper()
		result, _ := testCall(t, api, method, path, token, body, itemWaterHeaders, 200)
		return result
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": zone.String()})
	owner := account["profile"].(map[string]any)["userId"].(string)
	items := seedWaterItems(t, pool, owner, "worldseed-orrery", stepGrantFamily, alignmentProfile, 2)
	plant := account["starterPlantId"].(string)
	installation := uuid.NewString()
	device := call("POST", "/v1/activity/enrolments", map[string]any{
		"requestId": uuid.NewString(), "installationId": installation, "observedAt": start.Format(time.RFC3339Nano), "steps": 900,
	})["device"].(map[string]any)["deviceId"]

	sync := func(elapsed, steps int64) (map[string]any, map[string]any) {
		t.Helper()
		seconds.Store(elapsed)
		body := map[string]any{"requestId": uuid.NewString(), "deviceId": device, "installationId": installation,
			"observedAt": start.Add(time.Duration(elapsed) * time.Second).Format(time.RFC3339Nano),
			"days":       []map[string]any{{"gameDate": gameDate, "steps": steps}}}
		return call("POST", "/v1/activity/sync", body), body
	}

	sync(60, 1900) // This upload preceded placement.
	edit := func(layout int, actions, itemActions []map[string]any) map[string]any {
		t.Helper()
		body := map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2",
			"expectedLayoutVersion": layout, "itemActions": itemActions}
		if actions != nil {
			body["actions"] = actions
		}
		return call("POST", "/v1/me/garden/edits", body)["garden"].(map[string]any)
	}
	placeA := map[string]any{"action": "place", "itemId": items[0], "x": 4, "y": 4, "rotationDegrees": 0}
	placeB := map[string]any{"action": "place", "itemId": items[1], "x": 7, "y": 7, "rotationDegrees": 0}
	garden := edit(0, []map[string]any{{"action": "plant", "plantId": plant, "x": 1, "y": 1, "rotationDegrees": 0}}, []map[string]any{placeA, placeB})
	skills := garden["skillSummary"].(map[string]any)["activeSkills"].([]any)
	var sourceCount int
	for _, row := range skills {
		value := row.(map[string]any)
		if value["id"] == stepGrantFamily {
			sourceCount = len(value["eligibleSourceItemIds"].([]any))
		}
	}
	if sourceCount != 2 {
		t.Fatal(skills)
	}
	checkWater := func(sync map[string]any, count int, tier float64, water string) {
		t.Helper()
		values := sync["garden"].(map[string]any)["stepTierWater"].([]any)
		if len(values) != count {
			t.Fatal(values)
		}
		if count > 0 {
			first := values[0].(map[string]any)
			if first["gameDate"] != gameDate || first["tier"] != tier || first["water"] != water || first["plantCount"] != float64(1) {
				t.Fatal(values)
			}
		}
	}
	result, _ := sync(120, 3500)
	checkWater(result, 0, 0, "")
	result, first := sync(180, 3900)
	checkWater(result, 1, 2000, "3")
	edit(1, nil, []map[string]any{{"action": "store", "itemId": items[0]}, {"action": "store", "itemId": items[1]}})
	result, _ = sync(240, 5900)
	checkWater(result, 1, 2000, "3")
	edit(2, nil, []map[string]any{placeA})
	result, _ = sync(300, 9900)
	checkWater(result, 3, 6000, "5")
	replay := call("POST", "/v1/activity/sync", first)
	checkWater(replay, 1, 2000, "3")
	var steps, grants, firstSources int
	err = pool.QueryRow(ctx, `SELECT s.steps,count(g.tier),max(jsonb_array_length(g.provenance->'sources')) FILTER (WHERE g.tier=2000)
		FROM item_step_state s JOIN item_step_grants g USING(owner_id,game_date,family)
		WHERE s.owner_id=$1 GROUP BY s.steps`, owner).Scan(&steps, &grants, &firstSources)
	if err != nil || steps != 6000 || grants != 3 || firstSources != 2 {
		t.Fatalf("steps=%d grants=%d sources=%d err=%v", steps, grants, firstSources, err)
	}
}

func TestMorningRainCatchesUpAtLocalMidnightBeforeVisitorAccounting(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "morning-rain-local-signing-key-for-tests")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Date(2026, 11, 27, 15, 50, 0, 0, time.UTC)
	var elapsed atomic.Int64
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return start.Add(time.Duration(elapsed.Load()) * time.Second)
	}}).Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("morning-rain-test")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any) map[string]any {
		t.Helper()
		result, _ := testCall(t, api, method, path, token, body, itemWaterHeaders, 200)
		return result
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"})
	owner := account["profile"].(map[string]any)["userId"].(string)
	harps := seedWaterItems(t, pool, owner, "rainharp", dailyWaterFamily, rainProfile, 2)
	plant := account["starterPlantId"].(string)
	stored := addResalablePlant(t, pool, owner, 998_000_000)
	nearMaturity := addResalablePlant(t, pool, owner, 998_000_000)
	if _, err := pool.Exec(ctx, `UPDATE owned_plants SET growth_micro_units=98000000 WHERE id=$1`, plant); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO shop_releases(version,effective_week,catalogue,policy,published_at)
		VALUES('rain-test','2026-11-23','[]','{}',$1)`, start.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	edit := func(layout int, actions, items []map[string]any) map[string]any {
		t.Helper()
		body := map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2",
			"expectedLayoutVersion": layout, "itemActions": items}
		if actions != nil {
			body["actions"] = actions
		}
		return call("POST", "/v1/me/garden/edits", body)["garden"].(map[string]any)
	}
	placeHarps := []map[string]any{
		{"action": "place", "itemId": harps[0], "x": 4, "y": 4, "rotationDegrees": 0},
		{"action": "place", "itemId": harps[1], "x": 7, "y": 7, "rotationDegrees": 0},
	}
	initial := edit(0,
		[]map[string]any{
			{"action": "plant", "plantId": plant, "x": 1, "y": 1, "rotationDegrees": 0},
			{"action": "plant", "plantId": nearMaturity, "x": 4, "y": 1, "rotationDegrees": 0},
		}, placeHarps)
	if len(initial["dailyWater"].([]any)) != 0 {
		t.Fatal(initial)
	}
	elapsed.Store(24*3600 + 700)
	call("GET", "/v1/me/visitors", nil)
	garden := call("GET", "/v1/me/garden", nil)
	daily := garden["dailyWater"].([]any)
	if len(daily) != 2 || garden["stateVersion"] != float64(3) {
		t.Fatal(daily, garden["stateVersion"])
	}
	first, second := daily[1].(map[string]any), daily[0].(map[string]any)
	if first["gameDate"] != "2026-11-28" || first["water"] != "4.5" || first["plantCount"] != float64(2) ||
		second["gameDate"] != "2026-11-29" || second["water"] != "2.5" || second["plantCount"] != float64(1) {
		t.Fatal(daily)
	}
	garden = edit(1, nil, []map[string]any{{"action": "store", "itemId": harps[0]}, {"action": "store", "itemId": harps[1]}})
	if len(garden["dailyWater"].([]any)) != 2 {
		t.Fatal(garden["dailyWater"])
	}
	elapsed.Add(24 * 3600)
	garden = edit(2, nil, placeHarps)
	if len(garden["dailyWater"].([]any)) != 2 {
		t.Fatal(garden["dailyWater"])
	}
	var growth, storedGrowth, steps, maturities, version, rowCount, sources int64
	var seedling, maturity, firstBoundary time.Time
	err = pool.QueryRow(ctx, `SELECT activity_steps,first_maturity_count,progression_version,first_seedling_at,
		(SELECT growth_micro_units FROM owned_plants WHERE id=$2),
		(SELECT growth_micro_units FROM owned_plants WHERE id=$3),
		(SELECT first_matured_at FROM owned_plants WHERE id=$4), count(g.plant_id),
		max(jsonb_array_length(g.provenance->'sources')),min(g.boundary)
		FROM player_progress p JOIN daily_item_grants g ON g.owner_id=p.owner_id WHERE p.owner_id=$1
		GROUP BY p.owner_id`, owner, plant, stored, nearMaturity).
		Scan(&steps, &maturities, &version, &seedling, &growth, &storedGrowth, &maturity, &rowCount, &sources, &firstBoundary)
	midnight := start.Add(10 * time.Minute)
	if err != nil || steps != 0 || maturities != 1 || version != 0 || growth != 103_000_000 || storedGrowth != 998_000_000 ||
		rowCount != 3 || sources != 2 || !seedling.Equal(midnight) || !maturity.Equal(midnight) || !firstBoundary.Equal(midnight) {
		t.Fatalf("steps=%d maturities=%d version=%d growth=%d stored=%d rows=%d sources=%d seedling=%s maturity=%s first=%s err=%v",
			steps, maturities, version, growth, storedGrowth, rowCount, sources, seedling, maturity, firstBoundary, err)
	}
}
