package server

import (
	"context"
	"encoding/json"
	"math"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

var commerceHeaders = map[string]string{
	"X-Forest-Item-Commerce": "1", "X-Forest-Item-Rotations": "1", "X-Forest-Expeditions": "1", "X-Forest-Recovery": "1",
}

func seedBenchOffers(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	_, err := pool.Exec(context.Background(), `
INSERT INTO item_definitions (id,version,display_name,description,rarity,asset_version,model_key,thumbnail_key,clearance_radius)
VALUES ('wooden-bench',1,'Wooden Bench','A place to rest.','common','1.0.0',
	'assets/items/wooden-bench/v1/models/wooden-bench-standard.usdz','assets/items/wooden-bench/v1/ui/wooden-bench-standard.png',0.750);
INSERT INTO item_value_definitions (item_id,item_version,valuation_version,token_value,resale_basis_points)
VALUES('wooden-bench',1,'item-resale-v1',550,2500);
INSERT INTO item_shop_offers (id,version,item_id,item_version,token_cost)
VALUES('wooden-bench',1,'wooden-bench',1,550),('limited',1,'wooden-bench',1,500),('expired',1,'wooden-bench',1,500);
INSERT INTO shop_releases (version,effective_week,catalogue,policy,published_at)
VALUES ('commerce-fixture',date_trunc('week',now() at time zone 'UTC')::date,'[]','{"algorithm":1,"featuredLimit":2}',now());
INSERT INTO shop_weeks (week_start,release_version,seed,plan)
VALUES (date_trunc('week',now() at time zone 'UTC')::date,'commerce-fixture','fixture','{}');
INSERT INTO shop_days (shop_date,week_start,starts_at,ends_at)
VALUES ((now() at time zone 'UTC')::date,date_trunc('week',now() at time zone 'UTC')::date,now()-interval '1 hour',now()+interval '1 hour');
INSERT INTO shop_offer_windows (offer_id,offer_version,shop_date,slot,starts_at,ends_at,purchase_limit)
VALUES ('limited',1,(now() at time zone 'UTC')::date,'rare',now()-interval '1 hour',now()+interval '1 hour',2),
       ('expired',1,(now() at time zone 'UTC')::date,'epic',now()-interval '2 hours',now()-interval '1 hour',2);
`)
	if err != nil {
		t.Fatal(err)
	}
}

func addResalablePlant(t *testing.T, pool *pgxpool.Pool, owner string, growth int64) uuid.UUID {
	t.Helper()
	return addResalablePlantWithBehaviour(t, pool, owner, growth, "dev_oak_behaviour")
}

func addResalablePlantWithBehaviour(t *testing.T, pool *pgxpool.Pool, owner string, growth int64, behaviour string) uuid.UUID {
	t.Helper()
	plant := uuid.New()
	_, err := pool.Exec(context.Background(), `INSERT INTO owned_plants (id,owner_id,species_id,variant_id,
		growth_profile_id,growth_profile_version,behaviour_profile_id,behaviour_profile_version,
		attraction_profile_id,attraction_profile_version,acquisition_source,acquisition_reference,
		growth_micro_units,clearance_radius)
	VALUES ($1,$2,'oak','standard','dev_oak_growth',1,$5,1,'dev_oak_attraction',1,
		'benchmark_award',$3,$4,0.9)`, plant, owner, plant.String(), growth, behaviour)
	if err != nil {
		t.Fatal(err)
	}
	return plant
}

func TestCommerceContract(t *testing.T) {
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "commerce-test-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	app := &Server{Pool: pool, Auth: dev, Environment: "test"}
	api := httptest.NewServer(app.Handler())
	worker := httptest.NewServer(app.WorkerHandler())
	t.Cleanup(worker.Close)
	t.Cleanup(api.Close)
	newAccount := func(subject string) (string, map[string]any) {
		t.Helper()
		token, err := dev.IssueDevelopmentToken(subject)
		if err != nil {
			t.Fatal(err)
		}
		account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, map[string]any{
			"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}, nil, 200)
		return token, account
	}
	token, account := newAccount("buyer")
	other, _ := newAccount("other-buyer")
	owner := account["profile"].(map[string]any)["userId"].(string)
	ctx := context.Background()
	seedBenchOffers(t, pool)
	if _, err := pool.Exec(ctx, "UPDATE visitor_wallets SET tokens=2000 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}

	purchase := map[string]any{"requestId": uuid.NewString(), "offerId": "limited", "offerVersion": 1, "quantity": 2}
	testCall(t, api, "POST", "/v1/me/item-purchases", token, purchase, nil, 426)
	for _, offer := range []string{"wooden-bench", "expired"} {
		testCall(t, api, "POST", "/v1/me/item-purchases", token, map[string]any{"requestId": uuid.NewString(), "offerId": offer, "offerVersion": 1, "quantity": 1}, commerceHeaders, 409)
	}
	bought, _ := testCall(t, api, "POST", "/v1/me/item-purchases", token, purchase, commerceHeaders, 200)
	if bought["tokenBalance"] != "1000" || bought["gardenStateVersion"] != float64(1) || bought["remainingAllowance"] != float64(0) {
		t.Fatal(bought)
	}
	testCall(t, api, "POST", "/v1/me/item-purchases", token, map[string]any{"requestId": uuid.NewString(), "offerId": "limited", "offerVersion": 1, "quantity": 1}, commerceHeaders, 409)
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response_expires_at=now() WHERE user_id=$1 AND request_id=$2", owner, purchase["requestId"]); err != nil {
		t.Fatal(err)
	}
	report, _ := testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	if report["responses"].(map[string]any)["compacted"] != float64(1) || report["committedTransactions"] != float64(1) {
		t.Fatal(report)
	}
	replay, _ := testCall(t, api, "POST", "/v1/me/item-purchases", token, purchase, commerceHeaders, 200)
	if !reflect.DeepEqual(replay, bought) {
		t.Fatal("purchase did not replay")
	}
	exportRecoveryFixture(t, "item-purchase", replay)
	purchase["quantity"] = 1
	testCall(t, api, "POST", "/v1/me/item-purchases", token, purchase, commerceHeaders, 409)

	inventory, _ := testCall(t, api, "GET", "/v1/me/items?limit=1", token, nil, commerceHeaders, 200)
	cursor := inventory["nextCursor"].(string)
	item := inventory["items"].([]any)[0].(map[string]any)
	if item["ownedItemId"] != cursor || item["strategyRules"].(map[string]any)["profileId"] != "wooden-bench" {
		t.Fatal(inventory)
	}
	testCall(t, api, "GET", "/v1/me/items?limit=1&after="+cursor, token, nil, commerceHeaders, 200)
	testCall(t, api, "GET", "/v1/me/items?after="+cursor, other, nil, commerceHeaders, 400)
	testCall(t, api, "GET", "/v1/me/garden/snapshot", token, nil, commerceHeaders, 200)
	itemPath := "/v1/me/items/" + cursor
	testCall(t, api, "GET", itemPath+"/sale-quote", other, nil, commerceHeaders, 404)
	quote, _ := testCall(t, api, "GET", itemPath+"/sale-quote", token, nil, commerceHeaders, 200)
	if quote["tokens"] != "125" || quote["tokenValue"] != "500" {
		t.Fatal(quote)
	}
	sale := map[string]any{"requestId": uuid.NewString(), "valuationVersion": "item-resale-v1", "expectedTokens": "137"}
	testCall(t, api, "POST", itemPath+"/sell", token, sale, commerceHeaders, 409)
	sale["expectedTokens"] = "125"
	sold, _ := testCall(t, api, "POST", itemPath+"/sell", token, sale, commerceHeaders, 200)
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response_expires_at=now() WHERE user_id=$1 AND request_id=$2", owner, sale["requestId"]); err != nil {
		t.Fatal(err)
	}
	report, _ = testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	if report["responses"].(map[string]any)["compacted"] != float64(1) {
		t.Fatal(report)
	}
	again, _ := testCall(t, api, "POST", itemPath+"/sell", token, sale, commerceHeaders, 200)
	if !reflect.DeepEqual(sold, again) || sold["tokenBalance"] != "1125" {
		t.Fatal(sold, again)
	}
	testCall(t, api, "GET", itemPath+"/sale-quote", token, nil, commerceHeaders, 404)
	testCall(t, api, "GET", "/v1/me/plants/"+account["starterPlantId"].(string)+"/sale-quote", token, nil, commerceHeaders, 409)

	plant := addResalablePlant(t, pool, owner, 500_000_000)
	plantPath := "/v1/me/plants/" + plant.String()
	plantValue, _ := testCall(t, api, "GET", plantPath+"/sale-quote", token, nil, commerceHeaders, 200)
	plantSale := map[string]any{"requestId": uuid.NewString(), "valuationVersion": "plant-resale-v1",
		"expectedTokens": plantValue["tokens"], "expectedGrowthMicroUnits": "0"}
	testCall(t, api, "POST", plantPath+"/sell", token, plantSale, commerceHeaders, 409)
	plantSale["expectedGrowthMicroUnits"] = plantValue["growthMicroUnits"]
	sold, _ = testCall(t, api, "POST", plantPath+"/sell", token, plantSale, commerceHeaders, 200)
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response_expires_at=now() WHERE user_id=$1 AND request_id=$2", owner, plantSale["requestId"]); err != nil {
		t.Fatal(err)
	}
	report, _ = testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	if report["responses"].(map[string]any)["compacted"] != float64(1) {
		t.Fatal(report)
	}
	again, _ = testCall(t, api, "POST", plantPath+"/sell", token, plantSale, commerceHeaders, 200)
	if !reflect.DeepEqual(sold, again) {
		t.Fatal("plant sale did not replay")
	}
	var receipts int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM collection_events WHERE owner_id=$1)
		+(SELECT count(*) FROM item_sales WHERE owner_id=$1)+(SELECT count(*) FROM plant_sales WHERE owner_id=$1)`, owner).
		Scan(&receipts); err != nil || receipts != 3 {
		t.Fatalf("ledger contains %d entries: %v", receipts, err)
	}
}

func TestPlantPricingDoesNotOverflowAtBigintLimit(t *testing.T) {
	amount, err := plantSalePrice(960, 12000, math.MaxInt64, math.MaxInt64)
	if err != nil || amount != 576 {
		t.Fatalf("price %d, error %v", amount, err)
	}
}

func TestItemPresentationExpandsWorkoutProfile(t *testing.T) {
	rules := []byte(`{"effects":[{"id":"fixture_workout","name":"Fixture workout","description":"A workout boost.","scope":"activity","metric":"workouts"}]}`)
	descriptions, strategy, err := itemSkillPresentation("pinned-workout", 2, rules)
	if err != nil {
		t.Fatal(err)
	}
	effects := strategy["effects"].([]map[string]json.RawMessage)
	if len(descriptions) != 1 || len(effects) != 7 || strategy["profileVersion"] != 2 {
		t.Fatalf("unexpected item presentation: %v, %v", descriptions, strategy)
	}
	if string(effects[0]["metric"]) != `"workout_minutes.cycling"` || string(effects[6]["metric"]) != `"workout_minutes.yoga"` ||
		string(effects[0]["stackingRule"]) != `"strongest"` {
		t.Fatal("incorrect workout expansion or effect defaults")
	}
}
