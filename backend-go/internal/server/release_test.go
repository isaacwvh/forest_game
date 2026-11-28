package server

import (
	"context"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestLocalReleasePublicationAndGameplay(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "local-release-tests-development-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: dev, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	headers := map[string]string{
		"X-Forest-Item-Commerce": "1", "X-Forest-Item-Rotations": "1", "X-Forest-Expeditions": "1",
		"X-Forest-Milestones": "1", "X-Forest-Woodland": "1", "X-Forest-Recovery": "1",
	}
	const subject = "release-playtest"
	token, err := dev.IssueDevelopmentToken(subject)
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, payload any) map[string]any {
		t.Helper()
		doc, _ := testCall(t, api, method, path, token, payload, headers, 200)
		return doc
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"})
	owner := account["profile"].(map[string]any)["userId"].(string)
	garden := account["gardenId"].(string)
	call("POST", "/v1/me/garden/edits", map[string]any{
		"requestId": uuid.NewString(), "catalogVersion": developmentRelease, "expectedLayoutVersion": 0,
		"actions": []map[string]any{{"action": "plant", "plantId": account["starterPlantId"], "x": 2, "y": 2, "rotationDegrees": 0}},
	})
	for i := 0; i < 24; i++ {
		addResalablePlant(t, pool, owner, 1_000_000_000)
	}
	legacy := uuid.New()
	_, err = pool.Exec(ctx, `WITH origin AS (
		INSERT INTO collection_events (id,owner_id,request_id,operation,payload_hash,token_delta,gem_delta,receipt)
		VALUES ($1,$2,$1,'test_pack_storage','fixture',0,0,'{}') RETURNING id
	) INSERT INTO owned_packs (id,owner_id,pack_id,pack_version,exchange_id,acquired_at)
	  SELECT $1,$2,'woodland',2,origin.id,clock_timestamp() FROM origin`, legacy, owner)
	if err != nil {
		t.Fatal(err)
	}

	apply := func(options ReleaseOptions) map[string]any {
		t.Helper()
		report, err := RunLocalRelease(ctx, pool, options)
		if err != nil {
			t.Fatal(err)
		}
		return report
	}
	assertPreviewUntouched := func() {
		t.Helper()
		var version string
		var offers, milestones, weeks, expeditions int
		err := pool.QueryRow(ctx, `SELECT version,
			(SELECT count(*) FROM exchange_offers WHERE active), (SELECT count(*) FROM milestone_policies),
			(SELECT count(*) FROM shop_weeks), (SELECT count(*) FROM expedition_schedule) FROM game_catalogue`).
			Scan(&version, &offers, &milestones, &weeks, &expeditions)
		if err != nil || version != developmentRelease || offers != 2 || milestones != 0 || weeks != 0 || expeditions != 0 {
			t.Fatalf("unexpected state after rollback: %s, %d offers, %d milestones, %d weeks, %d expeditions, %v",
				version, offers, milestones, weeks, expeditions, err)
		}
	}
	options := ReleaseOptions{Command: "publish-release"}
	if report := apply(options); report["shop"] != "ready" || report["applied"] != false {
		t.Fatal(report)
	}
	assertPreviewUntouched()
	options.Apply = true
	if _, err := pool.Exec(ctx, "ALTER TABLE expedition_schedule ADD CONSTRAINT reject_test_release CHECK (FALSE)"); err != nil {
		t.Fatal(err)
	}
	if _, err := RunLocalRelease(ctx, pool, options); err == nil {
		t.Fatal("late publication failure unexpectedly committed")
	}
	assertPreviewUntouched()
	if _, err := pool.Exec(ctx, "ALTER TABLE expedition_schedule DROP CONSTRAINT reject_test_release"); err != nil {
		t.Fatal(err)
	}
	report := apply(options)
	if report["shop"] != "ready" {
		t.Fatal(report)
	}
	repeated := apply(options)
	for _, group := range []string{"woodland", "items", "milestones", "expedition"} {
		for table, writes := range repeated[group].(map[string]int64) {
			if writes != 0 {
				t.Fatalf("reapplying %s wrote %d %s rows", group, writes, table)
			}
		}
	}
	var layout, owned int
	var pinned string
	err = pool.QueryRow(ctx, `SELECT layout_version,
		(SELECT count(*) FROM owned_plants WHERE owner_id=$2),
		(SELECT growth_profile_id FROM owned_plants WHERE id=$3) FROM gardens WHERE id=$1`,
		garden, owner, account["starterPlantId"]).Scan(&layout, &owned, &pinned)
	if err != nil || layout != 1 || owned != 25 || pinned != "dev_oak_growth" {
		t.Fatal(layout, owned, pinned, err)
	}

	if shop := apply(ReleaseOptions{Command: "preview-shop", Week: targetWeek(time.Now(), false)}); shop["plan"] == nil {
		t.Fatal(shop)
	}
	if funding := apply(ReleaseOptions{Command: "fund-release-test", Subject: subject}); funding["tokenGrant"] != int64(20000) {
		t.Fatal(funding)
	}
	for _, amount := range []int64{20000, 0} {
		if grant := apply(ReleaseOptions{Command: "fund-release-test", Subject: subject, Apply: true}); grant["tokenGrant"] != amount {
			t.Fatal(grant)
		}
	}
	snapshot := call("GET", "/v1/me/garden/snapshot", nil)
	behaviours := snapshot["catalogue"].(map[string]any)["profiles"].(map[string]any)["behaviour"].([]any)
	foundAmberfan := false
	for _, value := range behaviours {
		profile := value.(map[string]any)
		if profile["id"] != "woodland_amberfan" {
			continue
		}
		effect := profile["gardenEffects"].([]any)[0].(map[string]any)
		selector := effect["magnitude"].(map[string]any)["selector"].(map[string]any)
		if effect["minimumStage"] != "adult" || effect["operation"] != "percent" ||
			!reflect.DeepEqual(selector["tags"], []any{"tree"}) || !reflect.DeepEqual(selector["species"], []any{}) ||
			!reflect.DeepEqual(selector["variants"], []any{}) || !reflect.DeepEqual(selector["stages"], []any{}) {
			t.Fatal(effect)
		}
		foundAmberfan = true
		break
	}
	if !foundAmberfan {
		t.Fatal("published Amberfan behaviour missing from the garden catalogue")
	}
	exportRecoveryFixture(t, "release-garden-snapshot", snapshot)
	call("GET", "/v1/me/visitors", nil)
	shop := call("GET", "/v1/me/collection?view=shop", nil)
	if shop["catalogVersion"] != woodlandRelease || len(shop["offers"].([]any)) != 3 || shop["shop"] == nil {
		t.Fatal(shop)
	}
	entries := shop["itemOffers"].([]any)
	if len(entries) < 3 {
		t.Fatal(entries)
	}
	offer := entries[0].(map[string]any)
	replay := func(path string, payload any) map[string]any {
		t.Helper()
		first := call("POST", path, payload)
		if second := call("POST", path, payload); !reflect.DeepEqual(first, second) {
			t.Fatalf("receipt changed for %s: %v, %v", path, first, second)
		}
		return first
	}
	replay("/v1/me/item-purchases", map[string]any{"requestId": uuid.NewString(), "offerId": offer["offerId"], "offerVersion": offer["offerVersion"], "quantity": 1})
	doc := call("GET", "/v1/me/expeditions/current", nil)["current"].(map[string]any)
	path := "/v1/me/expeditions/" + doc["runId"].(string)
	call("GET", "/v1/pack-definitions/woodland/versions/20", nil)
	if old := replay("/v1/me/packs/"+legacy.String()+"/open", map[string]string{"requestId": uuid.NewString()}); old["packVersion"] != float64(2) {
		t.Fatal(old)
	}
	if track := findMilestone(t, call("GET", "/v1/me/collection?view=home", nil), "steps_new_beginnings"); track["eligible"] != true {
		t.Fatal(track)
	}
	claim := replay("/v1/me/milestones/steps_new_beginnings/claim", map[string]string{"requestId": uuid.NewString()})
	packs := append(claim["packs"].([]any), replay("/v1/me/exchanges", map[string]any{
		"requestId": uuid.NewString(), "offerId": "woodland", "offerVersion": 20, "quantity": 2,
	})["packs"].([]any)...)
	for _, pack := range packs {
		id := pack.(map[string]any)["ownedPackId"].(string)
		opened := replay("/v1/me/packs/"+id+"/open", map[string]string{"requestId": uuid.NewString()})
		if opened["packVersion"] != float64(20) {
			t.Fatal(opened)
		}
	}
	quest := expeditionQuest(t, call("GET", path, nil), "packs_opened_3")
	entitlement := quest["entitlement"].(map[string]any)["id"].(string)
	replay(path+"/rewards/"+entitlement+"/claim", map[string]string{"requestId": uuid.NewString()})
	var entriesCount int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM collection_events WHERE owner_id=$1 AND operation='item_purchase'`, owner).
		Scan(&entriesCount); err != nil || entriesCount != 1 {
		t.Fatal(entriesCount, err)
	}
}

func TestLocalReleasePublishesOnEmptySchema(t *testing.T) {
	ctx := context.Background()
	pool := emptyLocalDatabase(t)
	if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "activate-milestones", Apply: true}); err == nil {
		t.Fatal("milestone activation allowed without Woodland")
	}
	for _, command := range []string{"publish-woodland", "publish-item-catalogue", "activate-milestones"} {
		if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: command, Apply: true}); err != nil {
			t.Fatal(command, err)
		}
	}
	var now time.Time
	if err := pool.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&now); err != nil {
		t.Fatal(err)
	}
	month := expeditionMonth(now).AddDate(0, 1, 0)
	options := ReleaseOptions{Command: "publish-expedition", Month: month, Apply: true}
	for range 2 {
		report, err := RunLocalRelease(ctx, pool, options)
		if err != nil || report["expeditionMonth"] != month.Format(time.DateOnly) {
			t.Fatal(report, err)
		}
	}
	result, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "prepare-shop", Apply: true})
	if err != nil || result["shop"] != "ready" {
		t.Fatal(result, err)
	}
	var runtime, launches, weeks int
	expectedWeeks := 1
	if now.UTC().Weekday() == time.Sunday {
		expectedWeeks++
	}
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM runtime_control),
		(SELECT count(*) FROM expedition_launches), (SELECT count(*) FROM shop_weeks)`).Scan(&runtime, &launches, &weeks); err != nil || runtime != 1 || launches != 0 || weeks != expectedWeeks {
		t.Fatal(runtime, launches, weeks, err)
	}
}
