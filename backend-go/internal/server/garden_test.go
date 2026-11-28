package server

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestGardenEditPreservesReferenceDigest(t *testing.T) {
	r := httptest.NewRequest("POST", "/v1/me/garden/edits", strings.NewReader(`{"requestId":"98353819-b373-4b8e-969e-3f77ec5dae56",
		"expectedLayoutVersion":2,"catalogVersion":"v","actions":[{"action":"move","plantId":"60f52339-ac07-4f1c-934e-c2af25ddf50e",
		"x":2,"y":0.125}],"itemActions":[{"action":"store","itemId":"3ebc07fa-8cdb-4c97-8567-c16ee1efbd1b"}]}`))
	req, err := readGardenRequest(r)
	// Computed with the FastAPI GardenEditRequest and services.request_hash for the same body.
	if err != nil || req.digest != "43f0fa3c7e541b3da7e0a067b53e354abd8761ed138f1d4d0617720f518d4793" {
		t.Fatal(req.digest, err)
	}
}

var gardenHeaders = map[string]string{"X-Forest-Items": "1", "X-Forest-Snapshot": "1", "X-Forest-Item-Commerce": "1",
	"X-Forest-Item-Rotations": "1", "X-Forest-Recovery": "1"}

func TestGardenNativePreviewEditSnapshotAndVisitorSettlement(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	seedBenchOffers(t, pool)
	dev, err := DevelopmentVerifier("test", "garden-local-signing-key-for-test")
	if err != nil {
		t.Fatal(err)
	}
	var elapsed atomic.Int64
	start := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return start.Add(time.Duration(elapsed.Load()) * time.Second)
	}}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("garden-integration")
	if err != nil {
		t.Fatal(err)
	}
	call := func(method, path string, body any, status int) map[string]any {
		t.Helper()
		result, _ := testCall(t, api, method, path, token, body, gardenHeaders, status)
		return result
	}
	account := call("POST", "/v1/accounts/bootstrap", map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	plant := account["starterPlantId"].(string)
	other := addResalablePlant(t, pool, owner, 0).String()
	if _, err := pool.Exec(ctx, "UPDATE visitor_wallets SET tokens=2000 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}
	purchase := call("POST", "/v1/me/item-purchases", map[string]any{"requestId": uuid.NewString(), "offerId": "limited", "offerVersion": 1, "quantity": 1}, 200)
	item := purchase["ownedItemIds"].([]any)[0].(string)
	catalog := "development-woodland-v2"
	const editPath = "/v1/me/garden/edits"
	const previewPath = "/v1/me/garden/preview"
	edit := func(layout int, plants, items []map[string]any) map[string]any {
		body := map[string]any{"requestId": uuid.NewString(), "catalogVersion": catalog, "expectedLayoutVersion": layout}
		if len(plants) > 0 {
			body["actions"] = plants
		}
		if len(items) > 0 {
			body["itemActions"] = items
		}
		return body
	}
	place := []map[string]any{{"action": "plant", "plantId": plant, "x": 2, "y": 2, "rotationDegrees": 35.25}}
	placeItem := []map[string]any{{"action": "place", "itemId": item, "x": 5, "y": 5, "rotationDegrees": 12}}
	body := edit(0, place, placeItem)
	preview := call("POST", previewPath, body, 200)
	if preview["totalAttractionMicroUnits"] != "2000000" || preview["offlineCapacity"] != float64(30) {
		t.Fatal(preview)
	}
	var state, contexts, placements int
	if err := pool.QueryRow(ctx, `SELECT (SELECT state_version FROM gardens WHERE owner_id=$1),
		(SELECT count(*) FROM visitor_contexts),(SELECT count(*) FROM garden_placements)`, owner).Scan(&state, &contexts, &placements); err != nil ||
		state != 1 || contexts != 0 || placements != 0 {
		t.Fatal(state, contexts, placements, err)
	}
	body["expectedStrategyFingerprint"] = strings.Repeat("a", 64)
	if refusal := call("POST", editPath, body, 409); refusal["error"].(map[string]any)["code"] != "strategy_changed" {
		t.Fatal(refusal)
	}
	body["expectedStrategyFingerprint"] = preview["fingerprint"]
	result := call("POST", editPath+"?knownInventoryStateVersion=1", body, 200)
	garden := result["garden"].(map[string]any)
	if garden["layoutVersion"] != float64(1) || garden["stateVersion"] != float64(2) ||
		len(garden["plants"].([]any)) != 1 || len(garden["items"].([]any)) != 1 ||
		result["inventoryBaseStateVersion"] != nil || len(result["inventory"].(map[string]any)["plants"].([]any)) != 1 {
		t.Fatal(result)
	}
	visitor := call("GET", "/v1/me/visitors", nil, 200)
	if visitor["totalAttractionMicroUnits"] != "2000000" || len(visitor["sources"].([]any)) != 1 || visitor["claimableVisits"] != "0" {
		t.Fatal(visitor)
	}
	contextID := visitor["contextId"]
	elapsed.Store(120)
	move := edit(1, []map[string]any{{"action": "move", "plantId": plant, "x": 3, "y": 2}}, nil)
	move["expectedStrategySignature"] = "2000000#30##" + plant + ":1:"
	moved := call("POST", editPath+"?knownInventoryStateVersion=2", move, 200)
	movedPlant := moved["updatedPlants"].([]any)[0].(map[string]any)["placement"].(map[string]any)
	if movedPlant["rotationDegrees"] != 35.25 || moved["inventory"] != nil || moved["itemInventory"] != nil ||
		moved["inventoryBaseStateVersion"] != float64(2) || moved["garden"].(map[string]any)["stateVersion"] != float64(3) {
		t.Fatal(moved)
	}
	visitor = call("GET", "/v1/me/visitors", nil, 200)
	if visitor["contextId"] != contextID || visitor["storedVisitsMicroUnits"] != "500000" {
		t.Fatal(visitor)
	}
	replayed := call("POST", editPath+"?knownInventoryStateVersion=3", move, 200)
	if replayed["replayed"] != true || replayed["garden"].(map[string]any)["layoutVersion"] != float64(2) {
		t.Fatal(replayed)
	}
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response=NULL WHERE user_id=$1 AND request_id=$2", owner, move["requestId"]); err != nil {
		t.Fatal(err)
	}
	recovered := call("POST", editPath, move, 200)["recovery"].(map[string]any)
	if recovered["operation"] != "garden_edits" || recovered["refreshRequired"] != true {
		t.Fatal(recovered)
	}
	move["expectedStrategySignature"] = "different"
	call("POST", editPath, move, 409)

	overlap := call("POST", previewPath, edit(2, []map[string]any{
		{"action": "plant", "plantId": other, "x": 5, "y": 5, "rotationDegrees": 0}}, nil), 422)
	if problem := overlap["error"].(map[string]any); problem["code"] != "clearance_overlap" || len(problem["details"].(map[string]any)["plantIds"].([]any)) != 2 {
		t.Fatal(overlap)
	}
	outside := call("POST", editPath, edit(2, []map[string]any{
		{"action": "move", "plantId": plant, "x": 0, "y": 0}}, nil), 422)
	if outside["error"].(map[string]any)["code"] != "out_of_bounds" {
		t.Fatal(outside)
	}
	call("POST", editPath, edit(1, place, nil), 409)
	call("POST", editPath, edit(2, []map[string]any{{"action": "move", "plantId": plant, "x": 2.0001, "y": 2}}, nil), 422)
	snapshot := call("GET", "/v1/me/garden/snapshot?catalogVersion="+catalog, nil, 200)
	if snapshot["catalogue"] != nil || snapshot["supportsStrategyDigest"] != true ||
		snapshot["garden"].(map[string]any)["layoutVersion"] != float64(2) {
		t.Fatal(snapshot)
	}
	noChange := call("POST", editPath+"?knownInventoryStateVersion=3", edit(2, []map[string]any{
		{"action": "rotate", "plantId": plant, "rotationDegrees": 35.25}}, nil), 200)
	if noChange["garden"].(map[string]any)["layoutVersion"] != float64(2) || noChange["inventoryBaseStateVersion"] != float64(3) {
		t.Fatal(noChange)
	}

	elapsed.Store(240)
	stored := call("POST", editPath, edit(2, []map[string]any{{"action": "store", "plantId": plant}},
		[]map[string]any{{"action": "store", "itemId": item}}), 200)
	garden = stored["garden"].(map[string]any)
	if len(garden["plants"].([]any)) != 0 || len(garden["items"].([]any)) != 0 || garden["layoutVersion"] != float64(3) {
		t.Fatal(stored)
	}
	visitor = call("GET", "/v1/me/visitors", nil, 200)
	if visitor["contextId"] == contextID || visitor["claimableVisits"] != "1" || visitor["totalAttractionMicroUnits"] != "0" {
		t.Fatal(visitor)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO expedition_templates VALUES ('garden-guard','{}',now());
		INSERT INTO expedition_schedule VALUES (date_trunc('month',now() AT TIME ZONE 'UTC')::date,'garden-guard',now())`); err != nil {
		t.Fatal(err)
	}
	guard := call("POST", editPath, edit(3, place, nil), 503)
	if guard["error"].(map[string]any)["code"] != "garden_expedition_unavailable" {
		t.Fatal(guard)
	}
	if err := pool.QueryRow(ctx, `SELECT (SELECT state_version FROM gardens WHERE owner_id=$1),
		(SELECT count(*) FROM garden_placements)`, owner).Scan(&state, &placements); err != nil || state != 4 || placements != 0 {
		t.Fatal(state, placements, err)
	}
}
