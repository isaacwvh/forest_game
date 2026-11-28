package server

import (
	"context"
	"encoding/json"
	"math"
	"math/big"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var milestoneSyncUnavailable = &apiError{503, "activity_milestones_unavailable", "Activity milestone progress is unavailable"}

func (s *Server) syncActivity(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	input, err := parseActivitySync(r)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	if value, err := replayRecoverableMutation(r, tx, owner.ID, input.key, activitySyncOperation, input.digest); err != nil || value != nil {
		return value, err
	}
	g, err := readGardenRecord(ctx, tx, owner.ID)
	if err != nil {
		return nil, err
	}
	catalog, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	device, err := readSyncDevice(ctx, tx, owner.ID, input)
	if err != nil {
		return nil, err
	}
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	zone, err := time.LoadLocation(owner.Timezone)
	if err != nil {
		return nil, gardenPresentationUnavailable
	}
	if err := validateActivityWindow(input, device, at, zone); err != nil {
		return nil, err
	}
	expedition, err := expeditionAt(ctx, tx, owner.ID, at)
	if err != nil {
		return nil, err
	}
	milestone, err := readMilestonePolicy(ctx, tx)
	if err != nil {
		return nil, err
	}
	if milestone.version != "" && at.Before(milestone.effective) {
		milestone = milestonePolicy{}
	}
	if milestone.version != "" && !milestone.valid {
		return nil, milestoneSyncUnavailable
	}
	if err := s.settleGardenDaily(ctx, tx, &g, at, owner.Timezone); err != nil {
		return nil, err
	}
	plants, err := readActivityPlants(ctx, tx, g)
	if err != nil {
		return nil, err
	}
	config, err := readGardenStrategy(ctx, tx, owner.ID, at)
	if err != nil {
		return nil, err
	}
	before, err := readEconomy(ctx, tx, owner.ID)
	if err != nil {
		return nil, err
	}
	today := calendarDate(at, zone)
	planner := syncBucketPlanner{ctx: ctx, tx: tx, boundary: at, today: today, observed: input.observed, zone: zone, device: &device, milestones: milestone.version != "",
		rules: syncRules{make(map[string]activityRule), make(map[time.Time]string), s.Environment == "local" || s.Environment == "test"}}
	workouts, err := planner.planWorkouts(owner.ID, input)
	if err != nil {
		return nil, err
	}
	entries := make(map[time.Time]syncEntry, len(input.days))
	for _, entry := range input.days {
		entries[entry.date] = entry
	}
	for date := range workouts.metrics {
		if _, ok := entries[date]; !ok {
			entries[date] = syncEntry{date: date}
		}
	}
	dates := make([]time.Time, 0, len(entries))
	for date := range entries {
		dates = append(dates, date)
	}
	slices.SortFunc(dates, time.Time.Compare)
	planner.existing, err = readSyncWatermarks(ctx, tx, owner.ID, dates)
	if err != nil {
		return nil, err
	}
	days := make([]syncDay, 0, len(dates))
	for _, date := range dates {
		day, err := planner.day(entries[date], workouts.metrics[date])
		if err != nil {
			return nil, err
		}
		days = append(days, day)
	}
	return s.commitActivitySync(r, tx, owner, g, catalog, input, device, days, workouts, config, plants, before, at, today, milestone, expedition)
}

func (s *Server) commitActivitySync(r *http.Request, tx pgx.Tx, owner Profile, g gardenRecord, catalog catalogueState,
	input syncInput, device syncDevice, days []syncDay, workouts workoutPlan, config gardenStrategy, plants []activityPlant, before economyFacts, at, today time.Time, milestone milestonePolicy, expedition *uuid.UUID) (any, error) {
	ctx := r.Context()
	items, err := readPlacedSkillItems(ctx, tx, g)
	if err != nil {
		return nil, err
	}
	initial := gardenFacts{plants: make([]gardenPlantFact, 0, len(plants)), items: items}
	for _, p := range plants {
		initial.plants = append(initial.plants, p.gardenFact(p.before))
	}
	if err := s.loadGardenSkills(ctx, tx, initial); err != nil {
		return nil, err
	}
	for i := range plants {
		plants[i].skill = initial.plants[i].skill
	}
	frozen, err := buildSkillSnapshot(config, initial)
	if err != nil {
		return nil, err
	}
	var stages map[uuid.UUID]string
	if expedition != nil {
		if err := observeExpeditionGarden(ctx, tx, expedition, g.id, at, nil); err != nil {
			return nil, err
		}
		stages = expeditionPlantStages(plants)
	}
	growth, err := simulateActivityGrowth(plants, days, frozen, at)
	if err != nil {
		return nil, err
	}
	sources := readStepGrantSources(items)
	var pending []stepGrant
	if len(sources) > 0 {
		pending, err = planStepGrants(ctx, tx, g, days)
		if err != nil {
			return nil, err
		}
	}
	var runtime *visitorRuntime
	needsAccounting := false
	for _, day := range days {
		needsAccounting = needsAccounting || day.CreditID != nil || day.flights > 0
	}
	if needsAccounting || len(pending) > 0 {
		runtime, err = s.settleVisitorState(ctx, tx, g.id, g.owner, at, false)
		if err != nil {
			return nil, err
		}
		if runtime.at.After(at) {
			return nil, visitorContextUnavailable
		}
	}
	if err := persistGrowthPlants(ctx, tx, g.owner, growth.plants, at); err != nil {
		return nil, err
	}
	if err := observeExpeditionGarden(ctx, tx, expedition, g.id, at, stages); err != nil {
		return nil, err
	}
	if len(pending) > 0 {
		tierConfig := config
		if config.levelPolicy {
			steps := before.steps
			for _, day := range days {
				if steps > math.MaxInt64-day.NewlyEligible {
					return nil, activityCounterExhausted
				}
				steps += day.NewlyEligible
			}
			tierConfig.setProgressLevel(levelForSteps(steps))
		}
		if err := s.settleStepGrants(ctx, tx, g, &growth, pending, sources, items, at, runtime, tierConfig, expedition); err != nil {
			return nil, err
		}
		g.stepGrantHistory = true
	}
	growth.refresh()
	steps, matured, version, metrics, err := advanceActivityProgress(ctx, tx, g.owner, before, days, growth, at)
	if err != nil {
		return nil, err
	}
	if err := persistActivityDays(ctx, tx, owner, input, device, days, at); err != nil {
		return nil, err
	}
	if err := workouts.persist(ctx, tx, owner.ID, at); err != nil {
		return nil, err
	}
	if err := growth.persistTraces(ctx, tx); err != nil {
		return nil, err
	}
	if len(growth.plants) > 0 && len(pending) == 0 {
		if err := discoverActivityStages(ctx, tx, g, at, false); err != nil {
			return nil, err
		}
	}
	if growth.changed {
		if g.state == math.MaxInt64 {
			return nil, activityCounterExhausted
		}
		g.state++
		if _, err := tx.Exec(ctx, "UPDATE gardens SET state_version=$2,updated_at=$3 WHERE id=$1", g.id, g.state, at); err != nil {
			return nil, err
		}
	}
	progress := progressionFor(steps, matured, version, &at)
	if config.levelPolicy {
		config.setProgressLevel(progress.Level)
	}
	for _, day := range days {
		if day.date.Equal(today) {
			if config.flights > math.MaxInt64-day.flights {
				return nil, activityCounterExhausted
			}
			config.flights += day.flights
		}
	}
	view, err := evaluateGarden(config, gardenFacts{plants: growth.facts, items: items})
	if err != nil {
		return nil, err
	}
	if needsAccounting {
		if _, err := tx.Exec(ctx, "DELETE FROM daily_skill_activity WHERE owner_id=$1 AND game_date<$2",
			g.owner, today.AddDate(0, 0, -7)); err != nil {
			return nil, err
		}
		if err := s.replaceGardenContext(ctx, tx, runtime, config, view); err != nil {
			return nil, err
		}
	}
	if milestone.version != "" {
		if err := observeMilestoneActivity(ctx, tx, owner, milestone, at, days, workouts.milestoneWorkouts, growth); err != nil {
			return nil, err
		}
	}
	gems, wallet, err := creditActivityGems(ctx, tx, g.owner, input.key, steps, before.wallet, at)
	if err != nil {
		return nil, err
	}
	if config.levelPolicy {
		if err := writeActivityLevelNotice(ctx, tx, g.owner, input.key, levelForSteps(before.steps), progress.Level, view.capacity, at); err != nil {
			return nil, err
		}
	}
	results := make([]syncDayResult, 0, len(days))
	for _, day := range days {
		results = append(results, day.syncDayResult)
	}
	recap, err := saveActivityRecap(ctx, tx, g.owner, input.key, days, results, workouts.receipts, growth.summary, gems, steps/100-before.steps/100, at)
	if err != nil {
		return nil, err
	}
	garden, _, err := presentGarden(r, tx, g, catalog, config, view, nil)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": input.key, "acceptedAt": at, "device": device.document(), "days": results, "garden": garden,
		"activitySteps": numberString(steps), "firstMaturityCount": matured, "recapId": recap, "workouts": workouts.receipts,
		"activityMetrics": metrics, "progression": progress, "wallet": wallet}
	return result, saveActivitySyncReceipt(r, tx, g, input, result)
}

func advanceActivityProgress(ctx context.Context, tx pgx.Tx, owner string, before economyFacts, days []syncDay, growth growthResult, at time.Time) (steps, matured, version int64, metrics map[string]string, err error) {
	metrics = make(map[string]string)
	if err = json.Unmarshal(before.metrics, &metrics); err != nil {
		return
	}
	steps = before.steps
	for _, day := range days {
		if steps > math.MaxInt64-day.NewlyEligible {
			err = activityCounterExhausted
			return
		}
		steps += day.NewlyEligible
		for name, delta := range day.newMetrics {
			value := new(big.Rat)
			if old := metrics[name]; old != "" {
				var ok bool
				if value, ok = value.SetString(old); !ok || value.Sign() < 0 {
					err = invalidActivityRules
					return
				}
			}
			metrics[name] = value.Add(value, delta).RatString()
		}
	}
	if before.version == math.MaxInt64 || before.matured > math.MaxInt64-growth.matured {
		err = activityCounterExhausted
		return
	}
	matured, version = before.matured+growth.matured, before.version+1
	var seedling *time.Time
	if growth.seedling {
		seedling = &at
	}
	_, err = tx.Exec(ctx, `INSERT INTO player_progress (owner_id,activity_steps,first_maturity_count,last_sync_at,
		activity_metrics,first_seedling_at,progression_version) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7)
		ON CONFLICT(owner_id) DO UPDATE SET activity_steps=excluded.activity_steps,first_maturity_count=excluded.first_maturity_count,
		last_sync_at=excluded.last_sync_at,activity_metrics=excluded.activity_metrics,
		first_seedling_at=COALESCE(player_progress.first_seedling_at,excluded.first_seedling_at),progression_version=excluded.progression_version`,
		owner, steps, matured, at, metrics, seedling, version)
	return
}

func creditActivityGems(ctx context.Context, tx pgx.Tx, owner string, source uuid.UUID, steps int64, before json.RawMessage, at time.Time) (int64, json.RawMessage, error) {
	var current struct {
		StepGems    int64 `json:"stepGemsEarned,string"`
		Gems        int64 `json:"gemBalance,string"`
		Lifetime    int64 `json:"lifetimeGemsEarned,string"`
		Initialized bool  `json:"initialized"`
		Version     int64 `json:"economyVersion"`
	}
	if err := json.Unmarshal(before, &current); err != nil {
		return 0, nil, err
	}
	entitlement := steps / 10000
	if entitlement < current.StepGems {
		return 0, nil, activityCounterExhausted
	}
	add := entitlement - current.StepGems
	if add == 0 && current.Initialized {
		return 0, before, nil
	}
	if current.Gems > math.MaxInt64-add || current.Lifetime > math.MaxInt64-add || current.Version == math.MaxInt64 {
		return 0, nil, amountOverflow
	}
	if add > 0 {
		kind := "steps"
		if !current.Initialized {
			kind = "backfill"
		}
		if _, err := tx.Exec(ctx, `INSERT INTO gem_grants (id,owner_id,source_id,kind,rules_version,start_milestone,end_milestone,amount,created_at)
			VALUES($1,$2,$3,$4,'step-progression-v1',$5,$6,$7,$8)`,
			uuid.New(), owner, source, kind, current.StepGems, entitlement, add, at); err != nil {
			return 0, nil, err
		}
	}
	_, err := tx.Exec(ctx, `INSERT INTO visitor_wallets (owner_id,tokens,hosted_active,hosted_offline,gems,lifetime_gems_earned,
		step_gems_earned,economy_version,progression_initialized) VALUES($1,0,0,0,$2,$3,$4,$5,true)
		ON CONFLICT(owner_id) DO UPDATE SET gems=excluded.gems,lifetime_gems_earned=excluded.lifetime_gems_earned,
		step_gems_earned=excluded.step_gems_earned,economy_version=excluded.economy_version,progression_initialized=true`,
		owner, current.Gems+add, current.Lifetime+add, entitlement, current.Version+1)
	if err != nil {
		return 0, nil, err
	}
	var wallet map[string]json.RawMessage
	if err := json.Unmarshal(before, &wallet); err != nil {
		return 0, nil, err
	}
	encodeAmount := func(value int64) json.RawMessage { return json.RawMessage(strconv.Quote(numberString(value))) }
	wallet["gemBalance"], wallet["lifetimeGemsEarned"], wallet["stepGemsEarned"] = encodeAmount(current.Gems+add), encodeAmount(current.Lifetime+add), encodeAmount(entitlement)
	wallet["economyVersion"], wallet["initialized"] = json.RawMessage(numberString(current.Version+1)), json.RawMessage("true")
	out, err := json.Marshal(wallet)
	return add, out, err
}

func writeActivityLevelNotice(ctx context.Context, tx pgx.Tx, owner string, source uuid.UUID, old, next, capacity int64, at time.Time) error {
	if next <= old {
		return nil
	}
	var reached int64
	if err := tx.QueryRow(ctx, `SELECT COALESCE((SELECT reached_level FROM account_level_state WHERE owner_id=$1),$2)`, owner, old).
		Scan(&reached); err != nil {
		return err
	}
	if next <= reached {
		return nil
	}
	start := max(old, reached)
	fromLimit, _ := plantLimitForLevel(start)
	toLimit, _ := plantLimitForLevel(next)
	id := uuid.New()
	payload := map[string]any{"id": id, "policyVersion": "level-benefits-v1", "fromLevel": start, "toLevel": next,
		"baseOfflineBefore": offlineCapacity(start), "baseOfflineAfter": offlineCapacity(next), "effectiveOfflineAfter": capacity,
		"plantLimitBefore": fromLimit, "plantLimitAfter": toLimit}
	var batch pgx.Batch
	batch.Queue(`INSERT INTO level_up_notices (id,owner_id,source_id,from_level,to_level,payload,created_at)
		VALUES($1,$2,$3,$4,$5,$6::jsonb,$7)`, id, owner, source, start, next, payload, at)
	batch.Queue(`INSERT INTO account_level_state(owner_id,reached_level,presented_level) VALUES($1,$2,$3)
		ON CONFLICT(owner_id) DO UPDATE SET reached_level=excluded.reached_level`, owner, next, old)
	return tx.SendBatch(ctx, &batch).Close()
}

func saveActivityRecap(ctx context.Context, tx pgx.Tx, owner string, input uuid.UUID, days []syncDay, results []syncDayResult, workouts []workoutReceipt,
	plants []map[string]any, gems, xp int64, at time.Time) (*uuid.UUID, error) {
	credits := make([]uuid.UUID, 0, len(days))
	isAccepted := false
	for _, day := range days {
		if day.CreditID != nil {
			credits = append(credits, *day.CreditID)
		}
		isAccepted = isAccepted || day.NewlyEligible > 0
		for _, delta := range day.newMetrics {
			isAccepted = isAccepted || delta.Sign() > 0
		}
	}
	if len(credits) == 0 && !isAccepted && gems == 0 {
		return nil, nil
	}
	resource := make(map[string]string)
	if gems > 0 {
		resource["gems"] = numberString(gems)
	}
	payload := map[string]any{"kind": "activity_growth", "creditIds": credits, "plants": plants, "activityDays": results,
		"activitySummaryVersion": 1, "workouts": workouts, "resourceDeltas": resource, "progressionDeltas": map[string]string{"xp": numberString(xp)}}
	event, recap := uuid.New(), uuid.New()
	var batch pgx.Batch
	batch.Queue("INSERT INTO reward_events(id,owner_id,request_id,accepted_at,payload) VALUES($1,$2,$3,$4,$5::jsonb)",
		event, owner, input, at, payload)
	batch.Queue("INSERT INTO reward_recaps(id,owner_id,event_id,created_at,payload) VALUES($1,$2,$3,$4,$5::jsonb)",
		recap, owner, event, at, payload)
	return &recap, tx.SendBatch(ctx, &batch).Close()
}

func saveActivitySyncReceipt(r *http.Request, tx pgx.Tx, g gardenRecord, input syncInput, result map[string]any) error {
	recovery := 0
	if r.Header.Get("X-Forest-Recovery") == "1" {
		recovery = 1
	}
	facts := map[string]any{"version": 1, "outcome": map[string]any{"requestId": input.key, "acceptedAt": result["acceptedAt"],
		"recapId": result["recapId"], "gardenId": g.id}}
	_, err := tx.Exec(r.Context(), `WITH boundary AS (SELECT clock_timestamp() AS at)
		INSERT INTO api_requests (user_id,request_id,operation,payload_hash,response,completion,created_at,recovery_version,response_expires_at)
		SELECT $1,$2,'activity_sync',$3,$4::jsonb,$5::jsonb,at,$6,CASE WHEN $6=1 THEN at+interval '30 days' END FROM boundary`,
		g.owner, input.key, input.digest, result, facts, recovery)
	return err
}
