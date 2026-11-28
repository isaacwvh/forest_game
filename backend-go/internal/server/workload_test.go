package server

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestVisitorHalfHourResultBudget(t *testing.T) {
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "local-reference-suite-signing-key-only")
	if err != nil {
		t.Fatal(err)
	}
	var seconds atomic.Int64
	base := time.Now().UTC().Truncate(time.Second).Add(time.Second)
	app := &Server{Pool: pool, Auth: dev, Environment: "test", visitorClock: func() time.Time {
		return base.Add(time.Duration(seconds.Load()) * time.Second)
	}}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	token, err := dev.IssueDevelopmentToken("visitor-budget")
	if err != nil {
		t.Fatal(err)
	}
	account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token,
		map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}, nil, 200)
	seedHotContext(t, pool, account["gardenId"].(string), visitorFraction{"11", "100"})

	var resultBytes, heartbeatBytes, welcomeBytes, welcomes int
	var sequence int64
	headers := map[string]string{"X-Forest-Recovery": "1"}
	installation := uuid.NewString()
	control := func(path string, initial bool) map[string]any {
		body := map[string]any{"requestId": uuid.NewString(), "installationId": installation,
			"controlProtocol": 1, "expectedControlSequence": sequence}
		if initial {
			body["arrivalProtocol"] = 2
		}
		summary, size := testCall(t, api, "POST", path, token, body, headers, 200)
		if strings.HasSuffix(path, "/heartbeat") {
			heartbeatBytes += size
		}
		resultBytes += size
		sequence++
		return summary
	}
	summary := control("/v1/me/visitor-sessions", true)
	session := summary["session"].(map[string]any)["sessionId"].(string)
	for second := int64(1); second <= 1800; second++ {
		seconds.Store(second)
		if second%10 == 0 {
			summary = control("/v1/me/visitor-sessions/"+session+"/heartbeat", false)
		}
		now := base.Add(time.Duration(second) * time.Second)
		for _, raw := range summary["opportunities"].([]any) {
			op := raw.(map[string]any)
			issued, err := time.Parse(time.RFC3339Nano, op["issuedAt"].(string))
			if err != nil {
				t.Fatal(err)
			}
			expires, err := time.Parse(time.RFC3339Nano, op["expiresAt"].(string))
			if err != nil {
				t.Fatal(err)
			}
			if now.Before(issued) || !now.Before(expires) {
				continue
			}
			receipt, size := testCall(t, api, "POST", "/v1/me/visitor-opportunities/"+op["opportunityId"].(string)+"/welcome",
				token, map[string]string{"requestId": uuid.NewString()}, headers, 200)
			summary = receipt["summary"].(map[string]any)
			resultBytes += size
			welcomeBytes += size
			welcomes++
		}
	}
	control("/v1/me/visitor-sessions/"+session+"/end", false)
	t.Logf("%d result bytes for visitor slice, including %d heartbeat bytes and %d bytes for %d welcomes",
		resultBytes, heartbeatBytes, welcomeBytes, welcomes)
	if welcomes < 150 || welcomes > 260 {
		t.Fatalf("visitor fixture produced %d welcomes", welcomes)
	}
	if heartbeatBytes > 250_000 || welcomeBytes > 600_000 || resultBytes > 850_000 {
		t.Fatal("projected PostgreSQL result-value budget exceeded")
	}
}

func TestShopWorkerPersistsWeek(t *testing.T) {
	pool := localDatabase(t)
	ctx := context.Background()
	items := []shopItem{}
	for i, rarity := range []string{"common", "common", "common", "rare", "epic"} {
		id := fmt.Sprintf("go-shop-item-%d", i)
		if _, err := pool.Exec(ctx, `INSERT INTO item_definitions
			(id,version,display_name,description,rarity,asset_version,model_key,thumbnail_key,clearance_radius)
			VALUES ($1,1,$1,'Test fixture',$2,'local','model','thumb',1)`, id, rarity); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO item_value_definitions
			(item_id,item_version,valuation_version,token_value,resale_basis_points) VALUES ($1,1,'local',10,2500)`, id); err != nil {
			t.Fatal(err)
		}
		items = append(items, shopItem{id, rarity, 1, 1, 10})
	}
	if _, err := pool.Exec(ctx, `INSERT INTO shop_releases (version,effective_week,catalogue,policy,published_at)
		VALUES ('go-shop-test',date_trunc('week',clock_timestamp() at time zone 'UTC')::date,
			$1::jsonb,'{"algorithm":1,"featuredLimit":2}',clock_timestamp())`, items); err != nil {
		t.Fatal(err)
	}
	var downstream atomic.Int64
	app := &Server{Pool: playerDayPool(t, pool, 1, &downstream), Environment: "test"}
	worker := httptest.NewServer(app.WorkerHandler())
	t.Cleanup(worker.Close)
	for pass := range 2 {
		start, before := time.Now(), downstream.Load()
		result, _ := testCall(t, worker, "POST", "/tasks/shop", "", nil, nil, 200)
		if pass == 0 {
			t.Logf("prepare and persist a shop week: %.2f ms, %d PostgreSQL downstream bytes (cold worker connection)",
				float64(time.Since(start))/float64(time.Millisecond), downstream.Load()-before)
		}
		if result["status"] != "ready" {
			t.Fatal(result)
		}
	}
	var weeks, days, offers, unlimited int
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM shop_weeks),(SELECT count(*) FROM shop_days),
		(SELECT count(*) FROM shop_offer_windows),(SELECT count(*) FROM shop_offer_windows WHERE purchase_limit IS NULL)`).
		Scan(&weeks, &days, &offers, &unlimited); err != nil {
		t.Fatal(err)
	}
	if weeks < 1 || days != 7*weeks || offers != 26*weeks || unlimited != 21*weeks {
		t.Fatalf("unexpected persisted shop: weeks=%d days=%d offers=%d common=%d", weeks, days, offers, unlimited)
	}
}

func TestHistoryCompactsExactIntervalsAndReplays(t *testing.T) {
	pool := localDatabase(t)
	dev, err := DevelopmentVerifier("test", "local-reference-suite-signing-key-only")
	if err != nil {
		t.Fatal(err)
	}
	app := &Server{Pool: pool, Auth: dev, Environment: "test"}
	api := httptest.NewServer(app.Handler())
	t.Cleanup(api.Close)
	var downstream atomic.Int64
	worker := httptest.NewServer((&Server{Pool: playerDayPool(t, pool, 1, &downstream), Environment: "test"}).WorkerHandler())
	t.Cleanup(worker.Close)
	token, err := dev.IssueDevelopmentToken("history-test")
	if err != nil {
		t.Fatal(err)
	}
	body := map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}
	headers := map[string]string{"X-Forest-Recovery": "1"}
	account, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, body, headers, 200)
	garden := account["gardenId"].(string)
	owner := account["profile"].(map[string]any)["userId"].(string)
	state, _ := testCall(t, api, "GET", "/v1/me/visitors", token, nil, nil, 200)
	ctx := context.Background()
	yesterday := time.Now().UTC().AddDate(0, 0, -8).Truncate(24 * time.Hour)
	id := uuid.NewString()
	detail := map[string]visitorFraction{"before": {"0", "1"}, "after": {"1", "1"}, "generated": {"3", "1"}, "discarded": {"2", "1"}}
	if _, err := pool.Exec(ctx, `INSERT INTO visitor_settlements (id,garden_id,context_id,start_at,end_at,mode,detail)
		VALUES ($1,$2,$3,$4,$5,'inactive',$6::jsonb)`, id, garden, state["contextId"],
		yesterday.Add(-time.Second), yesterday.Add(2*time.Second), detail); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE api_requests SET recovery_version=1,response_expires_at=now()-interval '1 day'
		WHERE user_id=$1 AND request_id=$2`, owner, body["requestId"]); err != nil {
		t.Fatal(err)
	}
	begin := time.Now()
	testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	t.Logf("compact one acknowledged account receipt and one UTC-spanning visitor interval: %.2f ms, %d PostgreSQL downstream bytes (cold worker connection)",
		float64(time.Since(begin))/float64(time.Millisecond), downstream.Load())
	testCall(t, worker, "POST", "/tasks/history", "", nil, nil, 200)
	replayed, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, body, headers, 200)
	if replayed["starterPlantId"] != account["starterPlantId"] {
		t.Fatal("compacted account receipt did not replay")
	}
	var count int
	var retained bool
	var discarded string
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM visitor_day_summaries WHERE garden_id=$1),
		EXISTS(SELECT 1 FROM visitor_settlements WHERE id=$2),
		(SELECT discarded->>'numerator' FROM visitor_day_summaries WHERE garden_id=$1 AND day=$3::date)`,
		garden, id, yesterday).Scan(&count, &retained, &discarded); err != nil {
		t.Fatal(err)
	}
	if count != 2 || retained || discarded != "2" {
		t.Fatalf("unexpected rolled interval: %d, %v, %q", count, retained, discarded)
	}
}
