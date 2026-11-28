package server

import (
	"context"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/google/uuid"
)

func TestCollectionShopAndPacks(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "collection-test-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	createAccount := func(subject string) (string, string) {
		t.Helper()
		token, err := dev.IssueDevelopmentToken(subject)
		if err != nil {
			t.Fatal(err)
		}
		account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token,
			map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, nil, 200)
		return token, account["profile"].(map[string]any)["userId"].(string)
	}
	token, owner := createAccount("collection-contract")
	other, _ := createAccount("collection-other")
	call := func(method, path string, payload any, status int) map[string]any {
		t.Helper()
		result, _ := testCall(t, api, method, path, token, payload, commerceHeaders, status)
		return result
	}
	seedBenchOffers(t, pool)
	if _, err := pool.Exec(ctx, `
		UPDATE visitor_wallets SET tokens=100,gems=25,lifetime_gems_earned=25 WHERE owner_id=$1;
	`, owner); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO exchange_offers (id,version,pack_id,pack_version,token_cost,currency,active)
		VALUES ('gem-copy',1,'moonwillow',1,7,'gems',true)`); err != nil {
		t.Fatal(err)
	}
	testCall(t, api, "GET", "/v1/me/collection?view=shop", token, nil, nil, 426)
	shop := call("GET", "/v1/me/collection?view=shop", nil, 200)
	offers := shop["offers"].([]any)
	items := shop["itemOffers"].([]any)
	if len(offers) != 3 || len(items) != 1 || items[0].(map[string]any)["offerId"] != "limited" ||
		items[0].(map[string]any)["remainingAllowance"] != float64(2) || shop["shop"].(map[string]any)["shopTimezone"] != "UTC" {
		t.Fatal(shop)
	}
	latestDef := call("GET", "/v1/pack-definitions/woodland/versions/2", nil, 200)
	legacyDef := call("GET", "/v1/pack-definitions/woodland/versions/1", nil, 200)
	if latestDef["schemaVersion"] != float64(2) || latestDef["totalWeight"] != float64(100) ||
		legacyDef["schemaVersion"] != float64(1) || legacyDef["isFixture"] != true {
		t.Fatal(latestDef, legacyDef)
	}
	call("GET", "/v1/pack-definitions/missing/versions/1", nil, 503)
	home := call("GET", "/v1/me/collection?view=home", nil, 200)
	if len(home["milestones"].([]any)) != 0 || len(home["offers"].([]any)) != 0 {
		t.Fatal(home)
	}

	firstRequest := map[string]any{"requestId": uuid.NewString(), "offerId": "moonwillow", "offerVersion": 1, "quantity": 2}
	exchange := call("POST", "/v1/me/exchanges", firstRequest, 200)
	if exchange["tokenBalance"] != "84" || exchange["tokensSpent"] != "16" || exchange["economyVersion"] != float64(1) {
		t.Fatal(exchange)
	}
	if _, err := pool.Exec(ctx, "DELETE FROM api_requests WHERE user_id=$1 AND request_id=$2", owner, firstRequest["requestId"]); err != nil {
		t.Fatal(err)
	}
	if saved := call("POST", "/v1/me/exchanges", firstRequest, 200); !reflect.DeepEqual(saved, exchange) {
		t.Fatal(saved, exchange)
	}
	firstRequest["quantity"] = 3
	call("POST", "/v1/me/exchanges", firstRequest, 409)
	gemRequest := map[string]any{"requestId": uuid.NewString(), "offerId": "gem-copy", "offerVersion": 1}
	gemExchange := call("POST", "/v1/me/exchanges", gemRequest, 200)
	if gemExchange["tokenBalance"] != "84" || gemExchange["gemBalance"] != "18" ||
		gemExchange["gemsSpent"] != "7" || gemExchange["quantity"] != float64(1) {
		t.Fatal(gemExchange)
	}
	gemRequest["requestId"], gemRequest["quantity"] = uuid.NewString(), 20
	if insufficient := call("POST", "/v1/me/exchanges", gemRequest, 409); insufficient["error"].(map[string]any)["code"] != "insufficient_gems" {
		t.Fatal(insufficient)
	}
	gemRequest["quantity"] = nil
	call("POST", "/v1/me/exchanges", gemRequest, 422)

	list := call("GET", "/v1/me/packs?limit=1", nil, 200)
	pack := list["packs"].([]any)[0].(map[string]any)["ownedPackId"].(string)
	if list["nextCursor"] != pack {
		t.Fatal(list)
	}
	testCall(t, api, "GET", "/v1/me/packs?after="+pack, other, nil, nil, 400)
	openPath := "/v1/me/packs/" + pack + "/open"
	originalID := uuid.NewString()
	testCall(t, api, "POST", openPath, other, map[string]string{"requestId": originalID}, nil, 404)
	opened := call("POST", openPath, map[string]string{"requestId": originalID}, 200)
	plant := opened["plant"].(map[string]any)
	if plant["speciesId"] != "moonwillow" || plant["growthStage"] != "sprout" || opened["gardenStateVersion"] != float64(1) ||
		opened["economyVersion"] != float64(3) || opened["tokenBalance"] != "84" {
		t.Fatal(opened)
	}
	discovery, _ := testCall(t, api, "GET", "/v1/me/catalog-discovery", token, nil, map[string]string{"X-Forest-Discovery": "2"}, 200)
	if discovery["discoveryVersion"] != float64(2) {
		t.Fatal(discovery)
	}
	next := call("GET", "/v1/me/packs?limit=1&after="+pack, nil, 200)
	secondPack := next["packs"].([]any)[0].(map[string]any)["ownedPackId"].(string)

	aliasID := uuid.NewString()
	aliasPayload := map[string]string{"requestId": aliasID}
	if alias := call("POST", openPath, aliasPayload, 200); !reflect.DeepEqual(alias, opened) {
		t.Fatal(alias, opened)
	}
	// Include an alias written by the earlier Go port with an unversioned proof.
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET completion=completion-'version' WHERE user_id=$1 AND request_id=$2", owner, aliasID); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(8 * 24 * time.Hour)
	if err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error { return compactRequestHistory(ctx, tx, &at) }); err != nil {
		t.Fatal(err)
	}
	var compacted int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM api_requests
		WHERE user_id=$1 AND request_id IN ($2,$3) AND response IS NULL AND completion->>'version'='1'`,
		owner, originalID, aliasID).Scan(&compacted); err != nil || compacted != 2 {
		t.Fatalf("pack journals compacted = %d, error = %v", compacted, err)
	}
	testCall(t, api, "POST", openPath, token, aliasPayload, nil, 426)
	packReplay := call("POST", openPath, aliasPayload, 200)
	if !reflect.DeepEqual(packReplay, opened) {
		t.Fatal(packReplay, opened)
	}
	exportRecoveryFixture(t, "pack-open", packReplay)
	if replay := call("POST", openPath, map[string]string{"requestId": originalID}, 200); !reflect.DeepEqual(replay, opened) {
		t.Fatal(replay, opened)
	}
	secondOpening := call("POST", "/v1/me/packs/"+secondPack+"/open", map[string]string{"requestId": uuid.NewString()}, 200)
	history := call("GET", "/v1/me/pack-openings?limit=1", nil, 200)
	if history["nextCursor"] != secondOpening["openingId"] {
		t.Fatal(history)
	}
	latest := call("GET", "/v1/me/pack-openings?latest=true", nil, 200)
	if latest["nextCursor"] != nil || !reflect.DeepEqual(latest["openings"].([]any)[0], secondOpening) {
		t.Fatal(latest, secondOpening)
	}
	older := call("GET", "/v1/me/pack-openings?after="+secondOpening["openingId"].(string), nil, 200)
	if !reflect.DeepEqual(older["openings"].([]any)[0], opened) {
		t.Fatal(older, opened)
	}
	testCall(t, api, "GET", "/v1/me/pack-openings?after="+opened["openingId"].(string), other, nil, nil, 400)

	if _, err := pool.Exec(ctx, `INSERT INTO expedition_templates VALUES ('collection-guard','{}',now());
		INSERT INTO expedition_schedule VALUES (date_trunc('month',now() AT TIME ZONE 'UTC')::date,'collection-guard',now())`); err != nil {
		t.Fatal(err)
	}
	finalPack := gemExchange["packs"].([]any)[0].(map[string]any)["ownedPackId"].(string)
	guard := call("POST", "/v1/me/packs/"+finalPack+"/open", map[string]string{"requestId": uuid.NewString()}, 503)
	if guard["error"].(map[string]any)["code"] != "pack_progress_unavailable" {
		t.Fatal(guard)
	}
	final := call("GET", "/v1/me/collection?view=packs", nil, 200)
	if final["capacity"].(map[string]any)["unopenedPacks"] != float64(1) || final["economyVersion"] != float64(4) {
		t.Fatal(final)
	}
}

func TestShopReadPersistsBoundedCatchup(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "collection-test-development-key-only")
	if err != nil {
		t.Fatal(err)
	}
	token, err := dev.IssueDevelopmentToken("shop-read-catchup")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	testCall(t, api, "POST", "/v1/accounts/bootstrap", token,
		map[string]string{"requestId": uuid.NewString(), "gameTimezone": "UTC"}, nil, 200)
	if _, err := pool.Exec(ctx, `INSERT INTO shop_releases (version,effective_week,catalogue,policy,published_at)
		VALUES ('shop-read-catchup',date_trunc('week',now() AT TIME ZONE 'UTC')::date-63,'[]','{"algorithm":1,"featuredLimit":2}',now())`); err != nil {
		t.Fatal(err)
	}
	path := "/v1/me/collection?view=shop"
	preparing, _ := testCall(t, api, "GET", path, token, nil, commerceHeaders, 503)
	if preparing["error"].(map[string]any)["code"] != "shop_preparing" {
		t.Fatal(preparing)
	}
	var weeks int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM shop_weeks").Scan(&weeks); err != nil || weeks != 8 {
		t.Fatal(weeks, err)
	}
	ready, _ := testCall(t, api, "GET", path, token, nil, commerceHeaders, 200)
	if ready["shop"].(map[string]any)["shopTimezone"] != "UTC" {
		t.Fatal(ready)
	}
}

func TestSpeciesPackRollUsesIndependentWeights(t *testing.T) {
	pack := packDefinition{SchemaVersion: 2, Rarities: []packPool{
		{Rarity: "rare", Weight: 20, Species: []packSpecies{
			{SpeciesID: "birch", Variants: []packOutcome{{VariantID: "standard", Weight: 5}}},
			{SpeciesID: "ash", Variants: []packOutcome{{VariantID: "white", Weight: 2}, {VariantID: "blue", Weight: 8}}},
		}},
		{Rarity: "common", Weight: 80},
	}}
	rolls := []int{80, 0, 8}
	totals := []int{100, 2, 10}
	rarity, result, err := choosePack(pack, 100, func(max int) (int, error) {
		if len(totals) == 0 || max != totals[0] {
			t.Fatalf("unexpected draw range: %d", max)
		}
		roll := rolls[0]
		rolls, totals = rolls[1:], totals[1:]
		return roll, nil
	})
	if err != nil || rarity != "rare" || result.SpeciesID != "ash" || result.VariantID != "white" || len(rolls) != 0 {
		t.Fatal(rarity, result, err)
	}
}
