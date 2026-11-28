package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type OperatorOptions struct {
	Command      string
	Apply        bool
	Exact        bool
	Limit        int
	Responses    bool
	Visitors     bool
	Growth       bool
	Event        MilestoneEventPublication
	OfferID      string
	OfferVersion int
	Pack         PackPublication
	Rules        VisitorRulePublication
}

func RunLocalOperator(ctx context.Context, pool *pgxpool.Pool, opts OperatorOptions) (any, error) {
	switch opts.Command {
	case "storage-report", "history-backlog":
		tx, err := pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly, IsoLevel: pgx.RepeatableRead})
		if err != nil {
			return nil, err
		}
		defer rollbackOperator(ctx, tx)
		if opts.Command == "storage-report" {
			return storageReport(ctx, tx, opts.Exact)
		}
		return readHistoryBacklog(ctx, tx)
	case "maintain-history", "compact-requests", "backfill-progression", "backfill-milestones":
		if opts.Limit < 1 || opts.Limit > 5000 {
			return nil, errors.New("limit must be between 1 and 5000")
		}
	case "schedule-milestone-event", "retire-offer", "activate-level-benefits", "publish-pack", "publish-visitor-rules":
	default:
		return nil, errors.New("unknown operator command")
	}
	if opts.Command == "maintain-history" || opts.Command == "compact-requests" {
		return runHistoryOperator(ctx, pool, opts)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer rollbackOperator(ctx, tx)
	switch opts.Command {
	case "schedule-milestone-event", "retire-offer", "activate-level-benefits", "publish-pack", "publish-visitor-rules":
		// Publication uses the same exclusive fence as the local release publisher.
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", maintenanceLock); err != nil {
			return nil, err
		}
	default:
		if err := admit(ctx, tx); err != nil {
			return nil, err
		}
	}
	var boundary time.Time
	if err := tx.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&boundary); err != nil {
		return nil, err
	}
	var report map[string]any
	switch opts.Command {
	case "backfill-progression":
		report, err = backfillProgression(ctx, tx, opts.Limit, boundary)
	case "backfill-milestones":
		report, err = backfillMilestones(ctx, tx, opts.Limit, boundary)
	case "schedule-milestone-event":
		report, err = publishMilestoneEvent(ctx, tx, opts.Event, boundary)
	case "retire-offer":
		report, err = retireExchangeOffer(ctx, tx, opts.OfferID, opts.OfferVersion)
	case "activate-level-benefits":
		report, err = activateLevelBenefits(ctx, tx, boundary)
	case "publish-pack":
		report, err = publishExchangePack(ctx, tx, opts.Pack)
	case "publish-visitor-rules":
		report, err = publishVisitorRules(ctx, tx, opts.Rules)
	}
	if err != nil {
		return nil, err
	}
	report["applied"] = opts.Apply
	if opts.Apply {
		return report, tx.Commit(ctx)
	}
	if opts.Command == "backfill-progression" {
		report["wouldInitialize"] = report["initialized"]
		report["initialized"] = 0
	}
	return report, tx.Rollback(ctx)
}

func rollbackOperator(ctx context.Context, tx pgx.Tx) {
	cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
	defer cancel()
	_ = tx.Rollback(cleanup)
}

func runHistoryOperator(ctx context.Context, pool *pgxpool.Pool, opts OperatorOptions) (workerReport, error) {
	config := WorkerConfig{
		BatchLimit: opts.Limit, Responses: opts.Responses, Visitors: opts.Visitors, Growth: opts.Growth,
	}
	if opts.Command == "compact-requests" {
		config.Responses = true
	}
	if !config.Responses && !config.Visitors && !config.Growth {
		return workerReport{}, errors.New("select at least one family: --responses, --visitors or --growth")
	}
	execution := workerExecution{
		config: config,
		report: workerReport{historyWorkerReport: &historyWorkerReport{DryRun: !opts.Apply}},
	}
	started := time.Now()
	ctx = context.WithValue(ctx, workerReportKey{}, &execution)
	app := Server{Pool: pool}
	execution.report.Status, execution.report.Reason = app.workerPass(ctx, runHistory)
	execution.report.ElapsedSeconds = time.Since(started).Seconds()
	switch execution.report.Status {
	case "ok", "skipped":
		return execution.report, nil
	default:
		return execution.report, fmt.Errorf("history pass returned %s", execution.report.Status)
	}
}

func backfillOwners(ctx context.Context, tx pgx.Tx, query string, limit int) ([]string, bool, error) {
	rows, err := tx.Query(ctx, query, limit+1)
	if err != nil {
		return nil, false, err
	}
	result, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if len(result) > limit {
		return result[:limit], true, err
	}
	return result, false, err
}

func backfillProgression(ctx context.Context, tx pgx.Tx, limit int, at time.Time) (map[string]any, error) {
	owners, more, err := backfillOwners(ctx, tx, `SELECT u.id::text FROM users u
		LEFT JOIN visitor_wallets w ON w.owner_id=u.id WHERE w.progression_initialized IS DISTINCT FROM true
		ORDER BY u.id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	var total big.Int
	examined := 0
	for _, owner := range owners {
		if _, err := tx.Exec(ctx, "SELECT id FROM users WHERE id=$1 FOR UPDATE", owner); err != nil {
			return nil, err
		}
		var initialized bool
		err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM visitor_wallets WHERE owner_id=$1 AND progression_initialized)`, owner).Scan(&initialized)
		if err != nil {
			return nil, err
		}
		if initialized {
			continue
		}
		economy, err := readEconomy(ctx, tx, owner)
		if err != nil {
			return nil, err
		}
		source := uuid.NewSHA1(uuid.NameSpaceURL, []byte("step-progression-v1/backfill/"+owner))
		amount, _, err := creditActivityGems(ctx, tx, owner, source, economy.steps, economy.wallet, at)
		if err != nil {
			return nil, err
		}
		total.Add(&total, big.NewInt(amount))
		examined++
	}
	return map[string]any{"examined": examined, "initialized": examined, "gems": total.String(), "hasMore": more}, nil
}

func backfillMilestones(ctx context.Context, tx pgx.Tx, limit int, at time.Time) (map[string]any, error) {
	policy, err := readMilestonePolicy(ctx, tx)
	if err != nil {
		return nil, err
	}
	if !policy.valid || at.Before(policy.effective) {
		return nil, errors.New("activate a valid milestone policy first")
	}
	owners, more, err := backfillOwners(ctx, tx, `SELECT u.id::text FROM users u
		WHERE NOT EXISTS (SELECT 1 FROM milestone_state m WHERE m.owner_id=u.id)
		ORDER BY u.id LIMIT $1`, limit)
	if err != nil {
		return nil, err
	}
	preview := make([]map[string]any, 0, len(owners))
	for _, owner := range owners {
		if _, err := tx.Exec(ctx, "SELECT id FROM users WHERE id=$1 FOR UPDATE", owner); err != nil {
			return nil, err
		}
		var enrolled bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM milestone_state WHERE owner_id=$1)`, owner).Scan(&enrolled); err != nil {
			return nil, err
		}
		if enrolled {
			continue
		}
		if err := refreshMilestoneEntitlements(ctx, tx, owner, at); err != nil {
			return nil, err
		}
		var entitlements json.RawMessage
		err := tx.QueryRow(ctx, `SELECT COALESCE(jsonb_agg(jsonb_build_object(
			'milestoneId',milestone_id,'legacyMilestoneId',legacy_id,'supersededBy',superseded_by,
			'rewardTokens',definition->'rewardTokens','rewardGems',definition->'rewardGems',
			'rewardPacks',definition->'rewardPacks') ORDER BY milestone_id),'[]'::jsonb)
			FROM milestone_entitlements WHERE owner_id=$1`, owner).Scan(&entitlements)
		if err != nil {
			return nil, err
		}
		preview = append(preview, map[string]any{"ownerId": owner, "entitlements": entitlements})
	}
	return map[string]any{"accounts": len(preview), "hasMore": more, "granted": false, "preview": preview}, nil
}
