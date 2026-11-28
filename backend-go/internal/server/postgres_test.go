package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"forestivity/backend/migrations"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

func localDatabase(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("FOREST_GO_TEST_ADMIN_DSN")
	if dsn == "" {
		t.Skip("FOREST_GO_TEST_ADMIN_DSN is required for disposable PostgreSQL tests")
	}
	u, err := url.Parse(dsn)
	if err != nil || u.Hostname() != "127.0.0.1" || u.Path != "/postgres" {
		t.Fatal("test admin DSN must use the loopback postgres database")
	}
	admin, err := pgx.Connect(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = admin.Close(context.Background()) })
	database := "forest_go_test_" + strings.ReplaceAll(uuid.NewString(), "-", "")
	name := pgx.Identifier{database}.Sanitize()
	if _, err := admin.Exec(context.Background(), "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(context.Background(), "DROP DATABASE "+name+" WITH (FORCE)"); err != nil {
			t.Error(err)
		}
	})
	u.Path = "/" + database
	if err := migrations.Apply(u.String()); err != nil {
		t.Fatal(err)
	}
	if err := migrations.Apply(u.String()); err != nil {
		t.Fatal("repeated baseline:", err)
	}
	pool, err := pgxpool.New(context.Background(), u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	fixture, err := os.ReadFile("../../fixtures/development.sql")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(context.Background(), string(fixture)); err != nil {
		t.Fatal(err)
	}
	return pool
}

func testCall(t *testing.T, host *httptest.Server, method, path, token string, payload any, headers map[string]string, status int) (map[string]any, int) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(method, host.URL+path, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	res, err := host.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	result, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	if res.StatusCode != status {
		t.Fatalf("%s %s status %d want %d: %s", method, path, res.StatusCode, status, result)
	}
	var output map[string]any
	if err := json.Unmarshal(result, &output); err != nil {
		t.Fatal(err)
	}
	returnBytes, _ := strconv.Atoi(res.Header.Get("X-Forest-DB-Result-Bytes"))
	return output, returnBytes
}

func exportRecoveryFixture(t *testing.T, name string, fixture map[string]any) {
	t.Helper()
	dir := os.Getenv("FOREST_GO_RECOVERY_FIXTURE_DIR")
	if dir == "" {
		return
	}
	data, err := json.Marshal(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, name+".json"), data, 0600); err != nil {
		t.Fatal(err)
	}
}

func TestPostgresDockerContract(t *testing.T) {
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "local-reference-suite-signing-key-only")
	if err != nil {
		t.Fatal(err)
	}
	app := &Server{Pool: pool, Auth: dev, Environment: "test"}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	worker := httptest.NewServer(app.WorkerHandler())
	t.Cleanup(worker.Close)
	token, err := dev.IssueDevelopmentToken("go-tests")
	if err != nil {
		t.Fatal(err)
	}
	other, err := dev.IssueDevelopmentToken("other-worktree-test")
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	testCall(t, api, "GET", "/health/ready", "", nil, nil, 200)
	testCall(t, api, "GET", "/v1/me", "", nil, nil, 401)
	testCall(t, api, "GET", "/v1/me", other, nil, nil, 403)
	request := map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}
	account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, request, nil, 200)
	owner := account["profile"].(map[string]any)["userId"].(string)
	garden := account["gardenId"].(string)
	starter := account["starterPlantId"].(string)
	again, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, request, nil, 200)
	if again["starterPlantId"] != starter {
		t.Fatal("bootstrap minted a second starter")
	}
	change := map[string]string{"requestId": uuid.NewString(), "displayName": "Forest Test"}
	p, _ := testCall(t, api, "PATCH", "/v1/me", token, change, nil, 200)
	if p["displayName"] != "Forest Test" {
		t.Fatal("profile was not updated")
	}
	change["displayName"] = "Different"
	testCall(t, api, "PATCH", "/v1/me", token, change, nil, 409)
	testCall(t, api, "GET", "/v1/catalog", token, nil, nil, 200)
	items, _ := testCall(t, api, "GET", "/v1/me/inventory", token, nil, nil, 200)
	if len(items["plants"].([]any)) != 1 {
		t.Fatal("missing starter inventory")
	}
	testCall(t, api, "GET", "/v1/me/plants/"+starter, token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/activity", token, nil, nil, 200)
	reporter := uuid.NewString()
	enrolment := map[string]any{"requestId": uuid.NewString(), "installationId": reporter, "observedAt": time.Now().UTC().Format(time.RFC3339Nano),
		"steps": 100, "walkingRunningDistanceMetres": "200.120", "activeEnergyKcal": "12.5", "flightsClimbed": 5, "workoutsAvailable": true}
	enrolled, _ := testCall(t, api, "POST", "/v1/activity/enrolments", token, enrolment, nil, 200)
	device := enrolled["device"].(map[string]any)
	if device["baselineSteps"] != float64(100) || device["installationId"] != reporter {
		t.Fatal("invalid enrollment baseline")
	}
	enrolment["requestId"], enrolment["steps"] = uuid.NewString(), 200
	enrolledAgain, _ := testCall(t, api, "POST", "/v1/activity/enrolments", token, enrolment, nil, 200)
	if enrolledAgain["device"].(map[string]any)["baselineSteps"] != float64(100) {
		t.Fatal("same reporter reset its baseline")
	}
	enrolment["requestId"], enrolment["installationId"] = uuid.NewString(), uuid.NewString()
	testCall(t, api, "POST", "/v1/activity/enrolments", token, enrolment, nil, 409)
	testCall(t, api, "GET", "/v1/me/account-summary", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/home-attention", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/reward-recaps", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/garden/snapshot", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/garden/snapshot?catalogVersion=development-woodland-v2", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/items", token, nil, nil, 200)
	testCall(t, api, "GET", "/v1/me/catalog-discovery", token, nil, map[string]string{"X-Forest-Discovery": "2"}, 200)
	testCall(t, worker, "POST", "/tasks/shop", "", nil, nil, 200)
	testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)

	seedHotContext(t, pool, garden, visitorFraction{"15", "1"})
	first, cold := testCall(t, api, "GET", "/v1/me/visitors", token, nil, nil, 200)
	second, warm := testCall(t, api, "GET", "/v1/me/visitors", token, nil, nil, 200)
	if len(first["sources"].([]any)) != 23 || len(second["sources"].([]any)) != 23 || cold-warm < 2000 || warm >= 1400 {
		t.Fatalf("visitor projection returned %d cold / %d warm bytes", cold, warm)
	}

	controlHeaders := map[string]string{"X-Forest-Recovery": "1"}
	installation := uuid.NewString()
	startRequest := map[string]any{"requestId": uuid.NewString(), "installationId": installation,
		"arrivalProtocol": 2, "controlProtocol": 1, "expectedControlSequence": 0}
	start, _ := testCall(t, api, "POST", "/v1/me/visitor-sessions", token, startRequest, controlHeaders, 200)
	session := start["session"].(map[string]any)["sessionId"].(string)
	repeat, _ := testCall(t, api, "POST", "/v1/me/visitor-sessions", token, startRequest, controlHeaders, 200)
	if repeat["recovery"].(map[string]any)["status"] != "completed" {
		t.Fatal("lost control receipt was not recovered")
	}
	opportunities := start["opportunities"].([]any)
	if len(opportunities) == 0 {
		t.Fatal("no server-authorized scheduled arrivals")
	}
	id := opportunities[0].(map[string]any)["opportunityId"].(string)
	// The first tutorial arrival is published slightly in the future.
	time.Sleep(150 * time.Millisecond)
	welcomePath := "/v1/me/visitor-opportunities/" + id + "/welcome"
	welcomeID := map[string]string{"requestId": uuid.NewString()}
	welcome, firstTap := testCall(t, api, "POST", welcomePath, token, welcomeID, controlHeaders, 200)
	again, _ = testCall(t, api, "POST", welcomePath, token, welcomeID, controlHeaders, 200)
	if welcome["eventId"] != again["eventId"] || welcome["tokens"] != "1" {
		t.Fatal("replayed welcome changed the award")
	}
	var ledger int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM visitor_wallet_entries WHERE owner_id=$1", owner).Scan(&ledger); err != nil || ledger != 1 {
		t.Fatalf("expected exactly one wallet entry, got %d: %v", ledger, err)
	}
	heartbeat := map[string]any{"requestId": uuid.NewString(), "installationId": installation, "controlProtocol": 1, "expectedControlSequence": 1}
	_, heartbeatBytes := testCall(t, api, "POST", "/v1/me/visitor-sessions/"+session+"/heartbeat", token, heartbeat, controlHeaders, 200)
	ended := map[string]any{"requestId": uuid.NewString(), "installationId": installation, "controlProtocol": 1, "expectedControlSequence": 2}
	testCall(t, api, "POST", "/v1/me/visitor-sessions/"+session+"/end", token, ended, controlHeaders, 200)
	var remaining int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM visitor_opportunities WHERE garden_id=$1 AND status='issued'", garden).Scan(&remaining); err != nil || remaining != 0 {
		t.Fatalf("issued opportunities remain after close: %d, %v", remaining, err)
	}
	if heartbeatBytes <= 0 || firstTap <= 0 {
		t.Fatal("database metrics missing")
	}
	t.Logf("projected visitor status %d cold / %d warm bytes; dense scheduled heartbeat %d; welcome %d", cold, warm, heartbeatBytes, firstTap)
}

func seedHotContext(t *testing.T, pool *pgxpool.Pool, garden string, activeRate visitorFraction) {
	t.Helper()
	ctx := context.Background()
	contextID := uuid.NewString()
	// A persisted revision-2 context is representative of the hot path. Its large
	// explanation must not cross the database connection on status or controls.
	offline := visitorFraction{"1", "100"}
	rate := activeRate
	zero := visitorFraction{"0", "1"}
	var rules json.RawMessage
	if err := pool.QueryRow(ctx, `SELECT rules||'{"arrival_protocol":2}'::jsonb FROM visitor_rules WHERE version='development-visitors-v1'`).Scan(&rules); err != nil {
		t.Fatal(err)
	}
	sources := make([]map[string]any, 23)
	for i := range sources {
		sources[i] = map[string]any{"plantId": uuid.NewString(), "stage": "adult", "attractionMicroUnits": "100000",
			"profile": map[string]any{"id": fmt.Sprintf("planted-profile-%02d", i), "version": 1}}
	}
	snapshot := map[string]any{"sources": sources, "skills": strings.Repeat("x", 51_794), "attraction": "2300000",
		"capacity": 30, "offlineRate": offline, "activeRate": rate, "probability": zero, "rules": rules}
	batch := pgx.Batch{}
	batch.Queue(`INSERT INTO visitor_contexts (id,garden_id,effective_at,rule_version,snapshot)
		VALUES ($1,$2,clock_timestamp(),'development-visitors-v1',$3::jsonb)`, contextID, garden, snapshot)
	batch.Queue(`INSERT INTO garden_visitor_state (garden_id,settled_at,context_id,stored_whole,remainder,last_slot,gap_slots,version)
		VALUES ($1,clock_timestamp(),$2,0,'{}',0,0,0)`, garden, contextID)
	if err := pool.SendBatch(ctx, &batch).Close(); err != nil {
		t.Fatal(err)
	}
}
