package server

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

const activeSkillBehaviour = "go-active-canopy"

func seedActiveSkillProfiles(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	if _, err := pool.Exec(context.Background(), `
	INSERT INTO growth_rule_profiles (id,version,rules) VALUES ('go-active-canopy',1,'{
	  "schemaVersion":3,"metricMultipliers":{"steps":1},"conditionalModifiers":[],"conversionRates":{},"gardenEffects":[
	    {"id":"first_steps","name":"First Steps","description":"More early step growth.","system":"growth","scope":"activity",
	     "metric":"steps","target":"all_planted_plants","magnitude":{"value":"0.50"},"stackingGroup":"early_steps","componentVersion":2,"stepBand":"first_2000"},
	    {"id":"late_steps","name":"Late Steps","description":"More late step growth.","system":"growth","scope":"activity",
	     "metric":"steps","target":"all_planted_plants","magnitude":{"value":"0.10"},"stackingGroup":"late_steps","componentVersion":2,"stepBand":"after_2000"},
	    {"id":"seedling_water","name":"Sprout Water","description":"More water for sprouts.","system":"growth","scope":"water",
	     "target":"selected_plants","recipients":{"stages":["sprout"],"tags":["woodland"]},
	     "magnitude":{"value":"0.20"},"stackingGroup":"sprout_water"},
	    {"id":"roomier_garden","name":"Roomier Garden","description":"More offline space.","system":"visitors","scope":"offline_capacity",
	     "target":"garden","magnitude":{"value":"0.25"},"stackingGroup":"roomier_garden"},
	    {"id":"flight_canopy","name":"Flight Canopy","description":"Daily flights strengthen attraction.","system":"visitors","scope":"attraction_garden",
	     "target":"garden","componentVersion":2,
	     "magnitude":{"type":"daily_flights","value":"0.01","maximum":"0.10"},"stackingGroup":"flight_canopy"}
	  ]}'::jsonb);
	INSERT INTO item_skill_profiles (id,version,rules) VALUES ('go-bench-passive',1,'{"effects":[
	  {"id":"bench_rest","name":"Bench Rest","description":"Visitors stay longer.","system":"visitors","scope":"welcome_duration",
	   "target":"garden","magnitude":{"value":"0.25"},"stackingGroup":"bench_rest"},
	  {"id":"bench_storage","name":"Bench Storage","description":"Adds three offline slots.","system":"visitors","scope":"offline_capacity",
	   "target":"garden","operation":"flat","magnitude":{"value":"3"},"stackingGroup":"bench_storage"}
	]}'::jsonb);
	INSERT INTO item_skill_bindings (item_id,item_version,profile_id,profile_version)
	VALUES ('wooden-bench',1,'go-bench-passive',1)`); err != nil {
		t.Fatal(err)
	}
}

func TestActiveGardenSkillsPreviewGrowthAndMidnight(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	seedBenchOffers(t, pool)
	seedActiveSkillProfiles(t, pool)
	dev, err := DevelopmentVerifier("test", "active-garden-skill-development-key")
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	clock.Store(time.Now().UTC().Unix())
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time { return time.Unix(clock.Load(), 0).UTC() }}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("go-active-garden-skills")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any) map[string]any {
		t.Helper()
		r, _ := testCall(t, api, method, path, token, body, gardenHeaders, 200)
		return r
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"})
	owner := account["profile"].(map[string]any)["userId"].(string)
	starter := account["starterPlantId"].(string)
	adult := addResalablePlantWithBehaviour(t, pool, owner, 1_000_000_000, activeSkillBehaviour)
	if _, err := pool.Exec(ctx, "UPDATE visitor_wallets SET tokens=1500 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}
	purchase := call("POST", "/v1/me/item-purchases", map[string]any{"requestId": uuid.NewString(), "offerId": "limited", "offerVersion": 1, "quantity": 1})
	bench := purchase["ownedItemIds"].([]any)[0].(string)
	installation := uuid.New()
	enrol := call("POST", "/v1/activity/enrolments", map[string]any{"requestId": uuid.NewString(), "installationId": installation,
		"observedAt": time.Now().UTC().Format(time.RFC3339Nano), "steps": 100})
	device := enrol["device"].(map[string]any)["deviceId"]
	midnight := calendarDate(time.Now(), time.UTC).AddDate(0, 0, 2)
	at := midnight.Add(-20 * time.Minute)
	clock.Store(at.Unix())
	if _, err := pool.Exec(ctx, "INSERT INTO daily_skill_activity (owner_id,game_date,flights) VALUES ($1,$2,10)", owner, calendarDate(at, time.UTC)); err != nil {
		t.Fatal(err)
	}
	body := map[string]any{"requestId": uuid.NewString(), "expectedLayoutVersion": 0, "catalogVersion": "development-woodland-v2",
		"actions": []map[string]any{{"action": "plant", "plantId": starter, "x": 2, "y": 2, "rotationDegrees": 0},
			{"action": "plant", "plantId": adult, "x": 5, "y": 2, "rotationDegrees": 0}},
		"itemActions": []map[string]any{{"action": "place", "itemId": bench, "x": 5, "y": 5, "rotationDegrees": 0}}}
	preview := call("POST", "/v1/me/garden/preview", body)
	summary := preview["skillSummary"].(map[string]any)
	effects := summary["activeSkills"].([]any)
	if preview["totalAttractionMicroUnits"] != "24200000" || preview["offlineCapacity"] != float64(40) || len(effects) != 7 {
		t.Fatal(preview)
	}
	body["expectedStrategyFingerprint"] = preview["fingerprint"]
	placed := call("POST", "/v1/me/garden/edits", body)
	if placed["garden"].(map[string]any)["totalAttractionMicroUnits"] != "24200000" {
		t.Fatal(placed)
	}
	activeDefinition := call("GET", "/v1/me/plants/"+adult.String(), nil)["gardenSkills"]
	for _, value := range placed["garden"].(map[string]any)["plants"].([]any) {
		plant := value.(map[string]any)
		if plant["plantId"] == adult.String() {
			want, _ := canonicalJSON(activeDefinition)
			got, _ := canonicalJSON(plant["gardenSkills"])
			if len(plant["gardenSkills"].([]any)) != 5 || string(want) != string(got) {
				t.Fatal("garden response changed the published skill definition")
			}
		}
	}
	before := call("GET", "/v1/me/visitors", nil)
	if before["capacity"] != float64(40) || before["totalAttractionMicroUnits"] != "24200000" {
		t.Fatal(before)
	}
	var life int64
	if err := pool.QueryRow(ctx, "SELECT (snapshot->>'welcomeDurationMicroseconds')::bigint FROM visitor_contexts WHERE id=$1", before["contextId"]).Scan(&life); err != nil || life != 25_000_000 {
		t.Fatal(life, err)
	}
	at = at.Add(10 * time.Second)
	clock.Store(at.Unix())
	synced := call("POST", "/v1/activity/sync", map[string]any{"requestId": uuid.NewString(), "deviceId": device, "installationId": installation,
		"observedAt": at.Format(time.RFC3339), "days": []map[string]any{{"gameDate": at.Format(time.DateOnly), "steps": 3000}}})
	garden := synced["garden"].(map[string]any)
	for _, p := range garden["plants"].([]any) {
		row := p.(map[string]any)
		if row["plantId"] == starter && row["growthMicroUnits"] != "49200000" {
			t.Fatal(row)
		}
	}
	recaps := call("GET", "/v1/me/reward-recaps", nil)["recaps"].([]any)
	recap := recaps[0].(map[string]any)["payload"].(map[string]any)["plants"].([]any)
	if len(recap) != 1 || recap[0].(map[string]any)["skillBonusGrowthMicroUnits"] != "19200000" {
		t.Fatal(recaps)
	}
	var trace string
	err = pool.QueryRow(ctx, `SELECT p.payload#>>'{skills,stepBandSegments,0,waterSteps}' FROM plant_growth_credits c
		JOIN growth_provenance p ON p.id=c.provenance_id WHERE c.plant_id=$1`, starter).Scan(&trace)
	if err != nil || trace != "2000" {
		t.Fatal(trace, err)
	}
	clock.Store(midnight.Add(10 * time.Second).Unix())
	after := call("GET", "/v1/me/visitors", nil)
	if after["contextId"] == before["contextId"] || after["totalAttractionMicroUnits"] != "22000000" || after["capacity"] != float64(40) {
		t.Fatal(after)
	}
	var oldCut, newCut bool
	err = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM visitor_settlements WHERE garden_id=$1 AND end_at=$2),
		EXISTS (SELECT 1 FROM visitor_settlements WHERE garden_id=$1 AND start_at=$2)`, account["gardenId"], midnight).Scan(&oldCut, &newCut)
	if err != nil || !oldCut || !newCut {
		t.Fatal(oldCut, newCut, err)
	}
	published := midnight.Add(20 * time.Second)
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_rules (version,effective_at,is_fixture,rules)
		SELECT 'go-skill-new-visitor-rules',$1,true,jsonb_set(rules,'{curve,base_capacity}','50'::jsonb)
		FROM visitor_rules WHERE version='development-visitors-v1'`, published); err != nil {
		t.Fatal(err)
	}
	clock.Store(published.Add(10 * time.Second).Unix())
	changed := call("GET", "/v1/me/visitors", nil)
	if changed["ruleVersion"] != "go-skill-new-visitor-rules" || changed["capacity"] != float64(65) {
		t.Fatal(changed)
	}
	err = pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM visitor_settlements WHERE garden_id=$1 AND end_at=$2),
		EXISTS (SELECT 1 FROM visitor_settlements WHERE garden_id=$1 AND start_at=$2)`, account["gardenId"], published).Scan(&oldCut, &newCut)
	if err != nil || !oldCut || !newCut {
		t.Fatal(oldCut, newCut, err)
	}
}

func TestVisitorSoftcapTailMatchesReference(t *testing.T) {
	curve := gardenCurve{Strategy: "linear_softcap_v2", K: 2_000_000, Starter: "0.5", Max: "0.8", Slot: 30,
		OfflineFraction: "0.25", OfflineCap: "0.01", Knee: 300_000_000, KneeProbability: "0.6", TailScale: 120_000_000, Multiplier: "1"}
	for input, expected := range map[int64]string{
		300000001:  "1500000004166666649305555603780864097/2500000000000000000000000000000000000",
		490000000:  "237169396401255670495714373236800293/312500000000000000000000000000000000",
		8000000000: "99999999999999999999999999781087230932586991537781679981520849/125000000000000000000000000000000000000000000000000000000000000",
	} {
		r, _, _, err := gardenVisitorRates(curve, input, true)
		if err != nil || strings.TrimSpace(r.RatString()) != expected {
			t.Fatal(input, r, err)
		}
	}
}

func TestPublishedWoodlandSkillSummaryMatchesReference(t *testing.T) {
	data, err := os.ReadFile("../../../backend/src/forest_api/data/woodland-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	type species struct {
		ID         string
		Tags       []string
		Attraction map[string]int64
		Behaviour  struct {
			SchemaVersion int
			GardenEffects json.RawMessage
		}
	}
	var content struct{ Species []species }
	if err := json.Unmarshal(data, &content); err != nil || len(content.Species) < 2 {
		t.Fatal(err)
	}
	caps := map[string]any{"schemaVersion": float64(1), "flatCapacity": float64(10), "activityBonus": "1.5", "waterBonus": "1.5",
		"plantAttractionBonus": "0.5", "gardenAttractionBonus": "0.5", "totalAttractionBonus": "1", "flatAttractionPoints": "10",
		"flatAttractionBaseFraction": "0.25", "capacityBonus": "2"}
	config := gardenStrategy{policy: "b8-caps-v1", caps: caps, base: 600, maximum: 1800, flights: 17,
		def: gardenVisitorRules{CapacityFlat: 10, Welcome: 20}}
	var facts gardenFacts
	for _, group := range []struct {
		rows  []species
		stage string
	}{
		{content.Species, "adult"}, {content.Species[:2], "sprout"},
	} {
		for _, row := range group.rows {
			ref := packRef{ID: "p-" + row.ID, Version: 1}
			effects, err := parseSkillEffects(row.Behaviour.GardenEffects, false)
			if err != nil {
				t.Fatal(row.ID, err)
			}
			id := uuid.UUID{15: byte(len(facts.plants) + 1)}
			facts.plants = append(facts.plants, gardenPlantFact{id: id, stage: group.stage, attraction: row.Attraction[group.stage],
				skill: skillPlant{species: row.ID, variant: "standard", tags: row.Tags, behaviour: ref, schema: row.Behaviour.SchemaVersion, effects: effects}})
		}
	}
	result, err := evaluateGarden(config, facts)
	if err != nil {
		t.Fatal(err)
	}
	wire, err := canonicalJSON(map[string]any{"totalAttractionMicroUnits": numberString(result.attraction),
		"offlineCapacity": result.capacity, "skillSummary": result.summary, "signature": skillSignature(result)})
	if err != nil {
		t.Fatal(err)
	}
	// The reference SkillSnapshot used the same published species, UUID order, stages and flights.
	if digest := fmt.Sprintf("%x", sha256.Sum256(wire)); digest != "dce6cf8fe765107f90887398a176677a86f821c64416f221400e59b3ea2d6220" {
		t.Fatalf("summary mismatch: %s, attraction=%d capacity=%d effects=%d", digest, result.attraction, result.capacity,
			len(result.summary["activeSkills"].([]map[string]any)))
	}
}
