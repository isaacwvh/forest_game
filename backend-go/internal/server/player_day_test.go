package server

import (
	"context"
	"fmt"
	"math"
	"net"
	"net/http/httptest"
	"os"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

type measuredSocket struct {
	net.Conn
	in *atomic.Int64
}

func (c measuredSocket) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	c.in.Add(int64(n))
	return n, err
}

func playerDayPool(t *testing.T, baseline *pgxpool.Pool, max int32, received *atomic.Int64) *pgxpool.Pool {
	t.Helper()
	config := baseline.Config()
	config.MaxConns = max
	dial := config.ConnConfig.DialFunc
	config.ConnConfig.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := dial(ctx, network, address)
		if err != nil {
			return nil, err
		}
		return measuredSocket{Conn: conn, in: received}, nil
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

type actionSamples struct {
	times               []time.Duration
	dbPayload, dbValues int64
}

func percentile(times []time.Duration, p float64) float64 {
	index := max(0, int(math.Ceil(float64(len(times))*p))-1)
	return float64(times[index]) / float64(time.Millisecond)
}

func TestSupportedGoPlayerDay(t *testing.T) {
	if os.Getenv("FOREST_GO_PLAYER_DAY") != "1" {
		t.Skip("set FOREST_GO_PLAYER_DAY=1 to run the full local measurement")
	}
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "commerce-test-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	var readFromDatabase atomic.Int64
	gamePool := playerDayPool(t, pool, 2, &readFromDatabase)
	workerPool := playerDayPool(t, pool, 1, &readFromDatabase)
	var clockSeconds atomic.Int64
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	app := &Server{Pool: gamePool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return start.Add(time.Duration(clockSeconds.Load()) * time.Second)
	}}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	worker := httptest.NewServer((&Server{Pool: workerPool, Environment: "test"}).WorkerHandler())
	t.Cleanup(worker.Close)
	token, err := dev.IssueDevelopmentToken("go-player-day")
	if err != nil {
		t.Fatal(err)
	}
	samples := map[string]*actionSamples{}
	totalBefore := readFromDatabase.Load()
	headers := make(map[string]string)
	for key, value := range commerceHeaders {
		headers[key] = value
	}
	for key, value := range gardenHeaders {
		headers[key] = value
	}
	headers["X-Forest-Milestones"] = "1"
	headers["X-Forest-Expeditions"] = "1"
	call := func(label string, host *httptest.Server, method, path, credential string, body any) map[string]any {
		beginBytes := readFromDatabase.Load()
		begin := time.Now()
		result, values := testCall(t, host, method, path, credential, body, headers, 200)
		bucket := samples[label]
		if bucket == nil {
			bucket = new(actionSamples)
			samples[label] = bucket
		}
		bucket.times = append(bucket.times, time.Since(begin))
		bucket.dbPayload += readFromDatabase.Load() - beginBytes
		bucket.dbValues += int64(values)
		return result
	}
	user := func(label, method, path string, body any) map[string]any {
		return call(label, api, method, path, token, body)
	}
	task := func(label, path string) map[string]any {
		return call(label, worker, "POST", path, "", nil)
	}

	call("cold readiness", api, "GET", "/health/ready", "", nil)
	zone := time.UTC
	if start.Hour() == 23 && start.Minute() >= 29 {
		zone, err = time.LoadLocation("Asia/Singapore")
		if err != nil {
			t.Fatal(err)
		}
	}
	account := user("account bootstrap", "POST", "/v1/accounts/bootstrap", map[string]string{
		"requestId": uuid.NewString(), "gameTimezone": zone.String(),
	})
	owner := account["profile"].(map[string]any)["userId"].(string)
	// Use a separate fixture pool so setup queries are outside the measured sockets.
	seedBenchOffers(t, pool)
	seedActiveSkillProfiles(t, pool)
	seedExpedition(t, pool, expeditionMonth(start), nil)
	event := seedMilestonePolicy(t, pool, start.Add(-time.Hour))
	if _, err := pool.Exec(context.Background(), `INSERT INTO milestone_events(event_id,policy_version,name,starts_at,ends_at,claim_until,definition)
		VALUES ('go_event',$1,'Benchmark Event',$2,$3,$4,$5::jsonb)`, testMilestonePolicy, start.Add(-time.Minute), start.Add(48*time.Hour), start.Add(72*time.Hour), event); err != nil {
		t.Fatal(err)
	}
	orrery := seedWaterItems(t, pool, owner, "worldseed-orrery", stepGrantFamily, alignmentProfile, 1)[0]
	harp := seedWaterItems(t, pool, owner, "rainharp", dailyWaterFamily, rainProfile, 1)[0]
	placeHarp := map[string]any{"action": "place", "itemId": harp, "x": 6.7, "y": 8.6, "rotationDegrees": 0}
	if _, err := pool.Exec(context.Background(), "UPDATE visitor_wallets SET tokens=3000 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}
	for range 22 {
		addResalablePlant(t, pool, owner, 0)
	}
	plant := addResalablePlant(t, pool, owner, 500_000_000)
	seedWorkoutBehaviour(t, pool)
	planted := []string{account["starterPlantId"].(string)}
	for range 2 {
		planted = append(planted, addResalablePlantWithBehaviour(t, pool, owner, 1_000_000_000, activeSkillBehaviour).String())
	}
	for range 20 {
		planted = append(planted, addResalablePlantWithBehaviour(t, pool, owner, 0, workoutPlantBehaviour).String())
	}
	if _, err := pool.Exec(context.Background(), `INSERT INTO visitor_rules (version,effective_at,is_fixture,rules)
		SELECT 'go-benchmark-arrivals', $1, true,
			jsonb_set(rules||'{"arrival_protocol":2}'::jsonb,'{curve,arrival_rate_multiplier}','"4.3"')
		FROM visitor_rules WHERE version='development-visitors-v1'`, start.Add(-time.Minute)); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(context.Background(), `INSERT INTO economy_configs (version,effective_at,is_fixture,rules)
		SELECT 'go-benchmark-activity','1970-01-02',true,jsonb_set(rules,'{metrics}',(rules->'metrics')||'{
			"walking_running_distance_km":{"normalisation":"1","water_micro_units":1000000},
			"active_energy_kcal":{"normalisation":"100","water_micro_units":1000000},
			"flights_climbed":{"normalisation":"10","water_micro_units":1000000},
			"workout_minutes.running":{"normalisation":"1","water_micro_units":1000000}
		}'::jsonb) FROM economy_configs WHERE version='development-neutral-v1'`); err != nil {
		t.Fatal(err)
	}
	placementActions := make([]map[string]any, 0, len(planted))
	for i, id := range planted {
		placementActions = append(placementActions, map[string]any{"action": "plant", "plantId": id,
			"x": float64(10+19*(i%5)) / 10, "y": float64(10+19*(i/5)) / 10, "rotationDegrees": 0})
	}
	edit := map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2",
		"expectedLayoutVersion": 0, "actions": placementActions,
		"itemActions": []map[string]any{
			{"action": "place", "itemId": orrery, "x": 8.6, "y": 8.6, "rotationDegrees": 0}, placeHarp,
		}}
	preview := user("garden preview", "POST", "/v1/me/garden/preview", edit)
	edit["expectedStrategyFingerprint"] = preview["fingerprint"]
	placed := user("garden planting", "POST", "/v1/me/garden/edits?knownInventoryStateVersion=0", edit)
	if len(placed["garden"].(map[string]any)["plants"].([]any)) != len(planted) {
		t.Fatal("native Go planting lost plants")
	}
	var layout, state int
	layout, state = 1, 1
	user("profile", "GET", "/v1/me", nil)
	user("catalogue cold", "GET", "/v1/catalog", nil)
	activityInstallation := uuid.NewString()
	enrolled := user("activity enrollment", "POST", "/v1/activity/enrolments", map[string]any{
		"requestId": uuid.NewString(), "installationId": activityInstallation, "observedAt": start.Format(time.RFC3339Nano), "steps": 900,
		"walkingRunningDistanceMetres": "500.000", "activeEnergyKcal": "20.000", "flightsClimbed": 1, "workoutsAvailable": true,
	})
	device := enrolled["device"].(map[string]any)["deviceId"]
	for range 4 {
		user("entry snapshot", "GET", "/v1/me/garden/snapshot?catalogVersion=development-woodland-v2", nil)
		user("account summary", "GET", "/v1/me/account-summary", nil)
		user("plant inventory", "GET", "/v1/me/inventory", nil)
		user("item inventory", "GET", "/v1/me/items", nil)
		user("discovery", "GET", "/v1/me/catalog-discovery", nil)
		user("activity status", "GET", "/v1/me/activity", nil)
		user("recap list", "GET", "/v1/me/reward-recaps", nil)
	}
	for range 3 {
		user("catalogue warm", "GET", "/v1/catalog", nil)
	}
	user("shop cold", "GET", "/v1/me/collection?view=shop", nil)
	user("pack definition", "GET", "/v1/pack-definitions/woodland/versions/2", nil)
	milestones := user("milestone tracks", "GET", "/v1/me/collection?view=home", nil)
	if entry := findMilestone(t, milestones, "steps_new_beginnings"); entry["eligible"] != true {
		t.Fatal(entry)
	}
	milestoneClaim := map[string]string{"requestId": uuid.NewString()}
	milestonePath := "/v1/me/milestones/steps_new_beginnings/claim"
	issuedBundle := user("milestone bundle claim", "POST", milestonePath, milestoneClaim)
	if len(issuedBundle["packs"].([]any)) != 1 {
		t.Fatal(issuedBundle)
	}
	user("milestone claim replay", "POST", milestonePath, milestoneClaim)

	user("visitor status cold", "GET", "/v1/me/visitors", nil)
	var sequence int64
	installation := uuid.NewString()
	control := func(label, path string, initial bool) map[string]any {
		body := map[string]any{"requestId": uuid.NewString(), "installationId": installation,
			"controlProtocol": 1, "expectedControlSequence": sequence}
		if initial {
			body["arrivalProtocol"] = 2
		}
		summary := user(label, "POST", path, body)
		sequence++
		return summary
	}
	summary := control("visitor start", "/v1/me/visitor-sessions", true)
	session := summary["session"].(map[string]any)["sessionId"].(string)
	sessions := "/v1/me/visitor-sessions/" + session
	var welcomes int
	var expeditionID string
	lastWorkoutEnd := start.Add(45 * time.Second)
	var lastWorkout map[string]any
	for second := int64(1); second <= 1800; second++ {
		clockSeconds.Store(second)
		if second%10 == 0 {
			summary = control("visitor heartbeat", sessions+"/heartbeat", false)
		}
		if second%30 == 0 {
			user("home attention", "GET", "/v1/me/home-attention", nil)
		}
		if second%450 == 0 && second < 1800 {
			saved := user("garden move, compact receipt", "POST", fmt.Sprintf("/v1/me/garden/edits?knownInventoryStateVersion=%d", state),
				map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2", "expectedLayoutVersion": layout,
					"actions": []map[string]any{{"action": "move", "plantId": planted[0], "x": 1, "y": 1 + float64(layout)*.02}}})
			if saved["inventory"] != nil || saved["inventoryBaseStateVersion"] != float64(state) {
				t.Fatal(saved)
			}
			layout++
			state++
		}
		current := start.Add(time.Duration(second) * time.Second)
		if second == 120 || second == 600 || second == 1550 {
			workoutEnd := current.Add(-2 * time.Second)
			workoutStart := lastWorkoutEnd.Add(5 * time.Second)
			workout := modelWorkout(uuid.New(), 37, workoutStart, workoutEnd, workoutEnd.Sub(workoutStart).Milliseconds())
			if second == 1550 {
				workout["distanceMetres"] = "2000.000"
			}
			records := []map[string]any{workout}
			if lastWorkout != nil {
				records = append(records, lastWorkout)
			}
			body := map[string]any{"requestId": uuid.NewString(), "deviceId": device, "installationId": activityInstallation,
				"observedAt": current.Format(time.RFC3339Nano), "workoutsAvailable": true, "workouts": records,
				"days": []map[string]any{{"gameDate": current.In(zone).Format(time.DateOnly), "steps": 900 + 4*second,
					"walkingRunningDistanceMetres": numberString(500 + 2*second), "activeEnergyKcal": numberString(20 + second/10),
					"flightsClimbed": 1 + second/120}}}
			label := "activity sync, steps and workout"
			wantTiers := int(4 * second / 2000)
			if wantTiers > 0 {
				label = "activity sync, workout and step-tier water"
			}
			synced := user(label, "POST", "/v1/activity/sync", body)
			garden := synced["garden"].(map[string]any)
			actual := int(garden["stateVersion"].(float64))
			workoutReceipts := synced["workouts"].([]any)
			if actual != state+1 || synced["activitySteps"] != numberString(4*second) ||
				workoutReceipts[len(workoutReceipts)-1].(map[string]any)["status"] != "accepted" ||
				len(garden["stepTierWater"].([]any)) != wantTiers {
				t.Fatal(synced)
			}
			lastWorkoutEnd, lastWorkout = workoutEnd, workout
			state = actual
			summary = user("visitor refresh after growth", "GET", "/v1/me/visitors", nil)
			if second == 600 {
				user("activity sync, replay", "POST", "/v1/activity/sync", body)
			}
			if second == 1550 {
				expedition := user("expedition current", "GET", "/v1/me/expeditions/current", nil)["current"].(map[string]any)
				expeditionID = expedition["runId"].(string)
				coverage := expedition["coverage"].([]any)
				day := coverage[len(coverage)-1].(map[string]any)
				path := "/v1/me/expeditions/" + expeditionID + "/evidence"
				evidence := map[string]any{"requestId": uuid.NewString(), "deviceId": device, "installationId": activityInstallation,
					"observedAt": current.Format(time.RFC3339Nano), "workouts": []map[string]any{workout}, "days": []map[string]any{{"gameDate": day["gameDate"], "startsAt": day["startsAt"],
						"through": day["through"], "steps": 4 * second, "workoutsComplete": true}}}
				accepted := user("expedition evidence", "POST", path, evidence)
				if accepted["runId"] != expeditionID {
					t.Fatal(accepted)
				}
			}
		}
		for _, value := range summary["opportunities"].([]any) {
			op := value.(map[string]any)
			issued, err := time.Parse(time.RFC3339Nano, op["issuedAt"].(string))
			if err != nil {
				t.Fatal(err)
			}
			expires, err := time.Parse(time.RFC3339Nano, op["expiresAt"].(string))
			if err != nil {
				t.Fatal(err)
			}
			if current.Before(issued) || !current.Before(expires) {
				continue
			}
			result := user("butterfly welcome", "POST", "/v1/me/visitor-opportunities/"+op["opportunityId"].(string)+"/welcome",
				map[string]string{"requestId": uuid.NewString()})
			summary = result["summary"].(map[string]any)
			welcomes++
		}
	}
	control("visitor end", sessions+"/end", false)
	user("stored visitor claim", "POST", "/v1/me/stored-visits/claim", map[string]string{"requestId": uuid.NewString()})

	for range 4 {
		user("shop warm", "GET", "/v1/me/collection?view=shop", nil)
		user("packs collection", "GET", "/v1/me/collection?view=packs", nil)
		user("pack list", "GET", "/v1/me/packs", nil)
	}
	exchange := user("pack exchange", "POST", "/v1/me/exchanges", map[string]any{
		"requestId": uuid.NewString(), "offerId": "woodland", "offerVersion": 2, "quantity": 3,
	})
	for _, value := range exchange["packs"].([]any) {
		pack := value.(map[string]any)["ownedPackId"].(string)
		user("pack open", "POST", "/v1/me/packs/"+pack+"/open", map[string]string{"requestId": uuid.NewString()})
		user("latest opening", "GET", "/v1/me/pack-openings?latest=true", nil)
	}
	user("opening history", "GET", "/v1/me/pack-openings", nil)
	if !expeditionMonth(start.Add(1550 * time.Second)).Equal(expeditionMonth(start.Add(1800 * time.Second))) {
		expeditionID = user("expedition current after renewal", "GET", "/v1/me/expeditions/current", nil)["current"].(map[string]any)["runId"].(string)
	}
	expeditionPath := "/v1/me/expeditions/" + expeditionID
	run := user("expedition detail", "GET", expeditionPath, nil)
	packsQuest := expeditionQuest(t, run, "packs_opened_3")
	entitlement := packsQuest["entitlement"].(map[string]any)
	claimPath := expeditionPath + "/rewards/" + entitlement["id"].(string) + "/claim"
	claim := map[string]string{"requestId": uuid.NewString()}
	if result := user("expedition claim", "POST", claimPath, claim); result["gemsEarned"] != "1" {
		t.Fatal(result)
	}
	user("expedition claim replay", "POST", claimPath, claim)
	user("expedition archive", "GET", "/v1/me/expeditions", nil)

	purchase := user("item purchase", "POST", "/v1/me/item-purchases", map[string]any{
		"requestId": uuid.NewString(), "offerId": "limited", "offerVersion": 1, "quantity": 2,
	})
	id := purchase["ownedItemIds"].([]any)[0].(string)
	user("garden item placement", "POST", "/v1/me/garden/edits",
		map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2", "expectedLayoutVersion": layout,
			"itemActions": []map[string]any{
				{"action": "place", "itemId": id, "x": 6.7, "y": 8.6, "rotationDegrees": 0}, {"action": "store", "itemId": harp},
			}})
	layout++
	user("garden item storage", "POST", "/v1/me/garden/edits",
		map[string]any{"requestId": uuid.NewString(), "catalogVersion": "development-woodland-v2", "expectedLayoutVersion": layout,
			"itemActions": []map[string]any{{"action": "store", "itemId": id}, placeHarp}})
	for _, value := range purchase["ownedItemIds"].([]any) {
		itemPath := "/v1/me/items/" + value.(string)
		quote := user("item sale quote", "GET", itemPath+"/sale-quote", nil)
		user("item sale", "POST", itemPath+"/sell", map[string]any{"requestId": uuid.NewString(),
			"valuationVersion": quote["valuationVersion"], "expectedTokens": quote["tokens"]})
	}
	plantPath := "/v1/me/plants/" + plant.String()
	user("plant detail", "GET", plantPath, nil)
	plantQuote := user("plant sale quote", "GET", plantPath+"/sale-quote", nil)
	user("plant sale", "POST", plantPath+"/sell", map[string]any{"requestId": uuid.NewString(),
		"valuationVersion": plantQuote["valuationVersion"], "expectedTokens": plantQuote["tokens"],
		"expectedGrowthMicroUnits": plantQuote["growthMicroUnits"]})

	midnight := activityDayStart(calendarDate(start, zone).AddDate(0, 0, 1), zone)
	clockSeconds.Store(int64(midnight.Sub(start)/time.Second) + 1)
	user("visitor status, daily water rollover", "GET", "/v1/me/visitors", nil)
	var recipients int
	err = pool.QueryRow(context.Background(), "SELECT count(*) FROM daily_item_grants WHERE owner_id=$1 AND boundary=$2", owner, midnight).Scan(&recipients)
	if err != nil || recipients != 21 {
		t.Fatalf("expected daily water for 21 growing plants, got %d: %v", recipients, err)
	}
	var eventVisits int
	err = pool.QueryRow(context.Background(), `SELECT (progress->>'butterflies')::int FROM milestone_event_state
		WHERE owner_id=$1 AND event_id='go_event'`, owner).Scan(&eventVisits)
	if err != nil || eventVisits != welcomes {
		t.Fatalf("expected all %d welcomes in milestone event, got %d: %v", welcomes, eventVisits, err)
	}

	playerBytes := readFromDatabase.Load() - totalBefore
	for range 1440 {
		if result := task("history idle", "/tasks/history"); result["status"] != "ok" {
			t.Fatal(result)
		}
	}
	for range 96 {
		if result := task("shop ready", "/tasks/shop"); result["status"] != "ready" {
			t.Fatal(result)
		}
	}

	var labels []string
	for label := range samples {
		labels = append(labels, label)
	}
	slices.Sort(labels)
	t.Log("action | count | p50 ms | p95 ms | PostgreSQL downstream bytes | result-value bytes")
	for _, label := range labels {
		stats := samples[label]
		slices.Sort(stats.times)
		t.Logf("%s | %d | %.3f | %.3f | %d | %d", label, len(stats.times), percentile(stats.times, .50),
			percentile(stats.times, .95), stats.dbPayload, stats.dbValues)
	}
	total := readFromDatabase.Load() - totalBefore
	t.Logf("player bytes=%d; idle worker bytes=%d; total PostgreSQL downstream bytes=%d; welcomes=%d",
		playerBytes, total-playerBytes, total, welcomes)
	if welcomes < 150 || welcomes > 260 {
		t.Fatalf("invalid modeled player day, welcomes=%d", welcomes)
	}
	if total > 2_000_000 {
		t.Fatalf("modeled local player-day exceeds the 2 MB PostgreSQL downstream budget: %d bytes", total)
	}
}
