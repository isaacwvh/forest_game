package server

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
)

func runOperatorForTest(t *testing.T, pool *pgxpool.Pool, opts OperatorOptions) any {
	t.Helper()
	result, err := RunLocalOperator(context.Background(), pool, opts)
	if err != nil {
		t.Fatalf("%s: %v", opts.Command, err)
	}
	return result
}

func TestOperatorBackfillsAndReports(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	verifier, err := DevelopmentVerifier("test", "local-operator-tests-development-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: verifier, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	token, err := verifier.IssueDevelopmentToken("operator-test")
	if err != nil {
		t.Fatal(err)
	}
	request := uuid.NewString()
	body := map[string]string{"requestId": request, "gameTimezone": "Asia/Singapore"}
	headers := map[string]string{"X-Forest-Recovery": "1"}
	created, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, body, headers, 200)
	owner := created["profile"].(map[string]any)["userId"].(string)
	if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "publish-release", Apply: true}); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{
		"UPDATE player_progress SET activity_steps=25000 WHERE owner_id=$1",
		"UPDATE visitor_wallets SET progression_initialized=false,tokens=123 WHERE owner_id=$1",
	} {
		if _, err := pool.Exec(ctx, sql, owner); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pool.Exec(ctx, "UPDATE api_requests SET response_expires_at=now()-interval '1 day' WHERE request_id=$1", request); err != nil {
		t.Fatal(err)
	}

	progressionOpts := OperatorOptions{Command: "backfill-progression", Limit: 1}
	milestoneOpts := OperatorOptions{Command: "backfill-milestones", Limit: 1}
	historyOpts := OperatorOptions{Command: "compact-requests", Limit: 1}
	summary := runOperatorForTest(t, pool, OperatorOptions{Command: "history-backlog"}).(map[string]any)
	if summary["expiredRecoveryResponses"] != int64(1) {
		t.Fatal(summary)
	}
	storage := runOperatorForTest(t, pool, OperatorOptions{Command: "storage-report", Exact: true}).(map[string]any)
	usersFound := false
	for _, table := range storage["tables"].([]storageTable) {
		if table.Schema == "public" && table.Name == "users" {
			usersFound = table.Exact != nil && *table.Exact == 1 && table.Total > 0 && len(table.Referrers) > 0
		}
	}
	if !usersFound {
		t.Fatal("storage report did not include the account and referencing tables")
	}
	progress := runOperatorForTest(t, pool, progressionOpts).(map[string]any)
	milestones := runOperatorForTest(t, pool, milestoneOpts).(map[string]any)
	history := runOperatorForTest(t, pool, historyOpts).(workerReport)
	if progress["gems"] != "2" || progress["initialized"] != 0 || progress["wouldInitialize"] != 1 ||
		milestones["accounts"] != 1 || milestones["granted"] != false ||
		!history.DryRun || history.CommittedTransactions != 0 || history.Responses.Compacted != 1 {
		t.Fatal(progress, milestones, history)
	}
	verify := func(gems, entitlement, grants int, hasResponse bool) {
		t.Helper()
		var tokens, balance, states, ledger int
		var response bool
		err := pool.QueryRow(ctx, `SELECT tokens,gems,(SELECT count(*) FROM milestone_state WHERE owner_id=$1),
			(SELECT count(*) FROM gem_grants WHERE owner_id=$1),
			(SELECT response IS NOT NULL FROM api_requests WHERE request_id=$2) FROM visitor_wallets WHERE owner_id=$1`,
			owner, request).Scan(&tokens, &balance, &states, &ledger, &response)
		if err != nil || tokens != 123 || balance != gems || states != entitlement || ledger != grants || response != hasResponse {
			t.Fatal(tokens, balance, states, ledger, response, err)
		}
	}
	verify(0, 0, 0, true)
	progressionOpts.Apply, milestoneOpts.Apply, historyOpts.Apply = true, true, true
	for range 2 {
		runOperatorForTest(t, pool, progressionOpts)
		runOperatorForTest(t, pool, milestoneOpts)
		runOperatorForTest(t, pool, historyOpts)
		verify(2, 1, 1, false)
	}
	replay, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token, body, headers, 200)
	if replay["gardenId"] != created["gardenId"] {
		t.Fatal("operator compaction did not preserve the bootstrap receipt")
	}
}

func TestOperatorContentPreviewAndRepeat(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "publish-release", Apply: true}); err != nil {
		t.Fatal(err)
	}
	start := time.Now().UTC().Add(time.Hour)
	event := OperatorOptions{Command: "schedule-milestone-event", Event: MilestoneEventPublication{
		ID: "garden_day", Name: "Garden day", Starts: start,
		Ends: start.Add(time.Hour), ClaimUntil: start.Add(3 * time.Hour), Attribution: "collection_time",
	}}
	offer := OperatorOptions{Command: "retire-offer", OfferID: "woodland", OfferVersion: 20}
	runOperatorForTest(t, pool, event)
	runOperatorForTest(t, pool, offer)
	verify := func(events, packs int, active bool) {
		t.Helper()
		var eventCount, packCount int
		var offerActive bool
		err := pool.QueryRow(ctx, `SELECT
			(SELECT count(*) FROM milestone_events WHERE event_id='garden_day'),
			(SELECT count(*) FROM pack_definitions WHERE id='woodland' AND version=20),
			(SELECT active FROM exchange_offers WHERE id='woodland' AND version=20)`).
			Scan(&eventCount, &packCount, &offerActive)
		if err != nil || eventCount != events || packCount != packs || offerActive != active {
			t.Fatal(eventCount, packCount, offerActive, err)
		}
	}
	verify(0, 1, true)
	event.Apply, offer.Apply = true, true
	for range 2 {
		runOperatorForTest(t, pool, event)
		runOperatorForTest(t, pool, offer)
		verify(1, 1, false)
	}
	event.Event.Name = "Attempted replacement"
	if _, err := RunLocalOperator(ctx, pool, event); err == nil {
		t.Fatal("published event could be changed")
	}
	var name string
	if err := pool.QueryRow(ctx, "SELECT name FROM milestone_events WHERE event_id='garden_day'").Scan(&name); err != nil || name != "Garden day" {
		t.Fatal(name, err)
	}
}

func TestOperatorLevelActivationPreservesSettledHistory(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	verifier, err := DevelopmentVerifier("test", "level-activation-test-development-signing-key")
	if err != nil {
		t.Fatal(err)
	}
	api := httptest.NewServer((&Server{Pool: pool, Auth: verifier, Environment: "test"}).Handler())
	t.Cleanup(api.Close)
	token, err := verifier.IssueDevelopmentToken("level-test")
	if err != nil {
		t.Fatal(err)
	}
	created, _ := testCall(t, api, "POST", "/v1/accounts/bootstrap", token,
		map[string]string{"requestId": uuid.NewString(), "gameTimezone": "Asia/Singapore"}, nil, 200)
	testCall(t, api, "POST", "/v1/me/garden/edits", token, map[string]any{
		"requestId": uuid.NewString(), "catalogVersion": developmentRelease, "expectedLayoutVersion": 0,
		"actions": []map[string]any{{"action": "plant", "plantId": created["starterPlantId"], "x": 2, "y": 2, "rotationDegrees": 0}},
	}, nil, 200)
	owner := created["profile"].(map[string]any)["userId"].(string)
	if _, err := pool.Exec(ctx, "UPDATE player_progress SET activity_steps=25000 WHERE owner_id=$1", owner); err != nil {
		t.Fatal(err)
	}
	garden := created["gardenId"].(string)
	readContext := func() (string, int64, string, int) {
		t.Helper()
		var id, capacity string
		var version int64
		var notices int
		err := pool.QueryRow(ctx, `SELECT v.context_id::text,v.version,COALESCE(c.snapshot#>>'{levelBenefits,base}',''),
			(SELECT count(*) FROM level_up_notices WHERE owner_id=$2)
			FROM garden_visitor_state v JOIN visitor_contexts c ON c.id=v.context_id WHERE v.garden_id=$1`,
			garden, owner).Scan(&id, &version, &capacity, &notices)
		if err != nil {
			t.Fatal(err)
		}
		return id, version, capacity, notices
	}
	original, version, _, _ := readContext()
	opts := OperatorOptions{Command: "activate-level-benefits"}
	runOperatorForTest(t, pool, opts)
	if current, after, _, _ := readContext(); current != original || after != version {
		t.Fatal("preview changed confirmed visitor state")
	}
	opts.Apply = true
	runOperatorForTest(t, pool, opts)
	current, after, capacity, notices := readContext()
	if current == original || after <= version || capacity != "825" || notices != 0 {
		t.Fatal(current, original, after, version, capacity, notices)
	}
	runOperatorForTest(t, pool, opts)
	var reached, presented, previousContexts int64
	err = pool.QueryRow(ctx, `SELECT reached_level,presented_level,
		(SELECT count(*) FROM visitor_contexts WHERE id=$2) FROM account_level_state WHERE owner_id=$1`,
		owner, original).Scan(&reached, &presented, &previousContexts)
	if err != nil || reached != 4 || presented != 4 || previousContexts != 1 {
		t.Fatal(reached, presented, previousContexts, err)
	}
	if replay, version, _, _ := readContext(); replay != current || version != after {
		t.Fatal("repeated activation changed confirmed visitor state")
	}
}

func TestOperatorPublishesVersionedPacksAndFutureRules(t *testing.T) {
	ctx := context.Background()
	pool := localDatabase(t)
	if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "publish-release", Apply: true}); err != nil {
		t.Fatal(err)
	}
	var pack, rules json.RawMessage
	var pinnedGrowth string
	if err := pool.QueryRow(ctx, `SELECT
		(SELECT definition FROM pack_definitions WHERE id='woodland' AND version=20),
		(SELECT rules FROM visitor_rules WHERE NOT is_fixture ORDER BY effective_at DESC LIMIT 1),
		(SELECT growth_profile_id FROM pack_members WHERE pack_id='woodland' AND pack_version=20
			ORDER BY species_id,variant_id LIMIT 1)`).Scan(&pack, &rules, &pinnedGrowth); err != nil {
		t.Fatal(err)
	}
	p := OperatorOptions{Command: "publish-pack", Pack: PackPublication{
		ID: "woodland", Version: 21, Definition: pack, OfferID: "woodland", OfferVersion: 21, TokenCost: 350, Currency: "tokens",
	}}
	r := OperatorOptions{Command: "publish-visitor-rules", Rules: VisitorRulePublication{
		Version: "operator-rules-v1", Definition: rules, Effective: time.Now().UTC().Add(time.Hour),
	}}
	runOperatorForTest(t, pool, p)
	runOperatorForTest(t, pool, r)
	verify := func(published bool) {
		t.Helper()
		var oldPack, newPack, oldOffer, newOffer, newRules bool
		err := pool.QueryRow(ctx, `SELECT
			EXISTS(SELECT 1 FROM pack_definitions WHERE id='woodland' AND version=20),
			EXISTS(SELECT 1 FROM pack_definitions WHERE id='woodland' AND version=21),
			EXISTS(SELECT 1 FROM exchange_offers WHERE id='woodland' AND version=20 AND active),
			EXISTS(SELECT 1 FROM exchange_offers WHERE id='woodland' AND version=21 AND active),
			EXISTS(SELECT 1 FROM visitor_rules WHERE version='operator-rules-v1')`).
			Scan(&oldPack, &newPack, &oldOffer, &newOffer, &newRules)
		if err != nil || !oldPack || newPack != published || oldOffer == published || newOffer != published || newRules != published {
			t.Fatal(oldPack, newPack, oldOffer, newOffer, newRules, err)
		}
	}
	verify(false)
	invalidPack := p
	invalidPack.Pack.Definition = bytes.ReplaceAll(pack, []byte(strconv.Quote(pinnedGrowth)), []byte(`"missing_growth_profile"`))
	if _, _, err := parsePackDefinition(invalidPack.Pack.Definition); err != nil || bytes.Equal(invalidPack.Pack.Definition, pack) {
		t.Fatal("test needs a valid manifest with a missing pinned profile", err)
	}
	invalidPack.Apply = true
	if _, err := RunLocalOperator(ctx, pool, invalidPack); err == nil {
		t.Fatal("a pack without a valid pinned growth profile was accepted")
	}
	verify(false)
	p.Apply, r.Apply = true, true
	for range 2 {
		runOperatorForTest(t, pool, p)
		runOperatorForTest(t, pool, r)
		verify(true)
	}
	if _, err := RunLocalRelease(ctx, pool, ReleaseOptions{Command: "publish-release", Apply: true}); err != nil {
		t.Fatal(err)
	}
	verify(true)
	p.Pack.TokenCost++
	if _, err := RunLocalOperator(ctx, pool, p); err == nil {
		t.Fatal("published offer could be changed")
	}
	r.Rules.Effective = r.Rules.Effective.Add(time.Hour)
	if _, err := RunLocalOperator(ctx, pool, r); err == nil {
		t.Fatal("published rule boundary could be changed")
	}
	verify(true)
}
