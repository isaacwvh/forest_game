package server

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

const visitorEarningsDue = `e.summarized_at IS NULL AND e.kind IN ('active_welcome','offline_claim')`

const visitorSessionUnused = `NOT EXISTS (SELECT 1 FROM visitor_opportunities p WHERE p.session_id=s.id)`

const visitorContextUnused = `NOT EXISTS (SELECT 1 FROM garden_visitor_state v WHERE v.context_id=c.id)
	AND NOT EXISTS (SELECT 1 FROM visitor_schedules v WHERE v.context_id=c.id)
	AND NOT EXISTS (SELECT 1 FROM visitor_opportunities p WHERE p.context_id=c.id)
	AND NOT EXISTS (SELECT 1 FROM visitor_settlements v WHERE v.context_id=c.id)`

// There must be durable schedule coverage before an old slot can disappear.
const visitorOpportunityCovered = `v.ever_issued AND (
	(p.slot>=0 AND p.slot<=v.last_slot) OR
	(p.slot<0 AND -(p.slot::numeric)<=s.sequence AND s.tutorial_used))`

// Protect legacy welcomes that need the original response. A Python receipt
// without a ledger proof can be upgraded only from its recovery-capable request.
const visitorOpportunityProof = `p.status IN ('expired','welcomed') AND (
	p.status='expired' OR (p.result IS NOT NULL AND e.id IS NOT NULL AND (
		e.receipt->'recoverable'='true'::jsonb OR
		(e.receipt IS NULL AND r.recovery_version=1))))`

const visitorOpportunitySources = `FROM visitor_opportunities p
	JOIN gardens g ON g.id=p.garden_id
	JOIN garden_visitor_state v ON v.garden_id=g.id
	LEFT JOIN visitor_schedules s ON s.garden_id=g.id
	LEFT JOIN visitor_reward_events e ON e.owner_id=g.owner_id AND e.kind='active_welcome' AND e.source_id=p.id
	LEFT JOIN api_requests r ON r.user_id=g.owner_id
		AND r.request_id=(p.result->>'requestId')::uuid AND r.operation='visitor_welcome' AND e.receipt IS NULL`

func compactVisitorEarnings(ctx context.Context, tx pgx.Tx, owner, garden string, now, cutoff time.Time, limit int) (int, error) {
	var valid bool
	var count int
	err := tx.QueryRow(ctx, `WITH due AS MATERIALIZED (
		SELECT e.id,e.created_at,e.kind,e.detail FROM visitor_reward_events e
		WHERE e.owner_id=$1 AND e.created_at<=$3 AND `+visitorEarningsDue+`
		ORDER BY e.created_at,e.id LIMIT $5
	), lots AS MATERIALIZED (
		SELECT d.id,lot."ruleVersion" AS rule,lot.visits,lot.tokens
		FROM due d CROSS JOIN LATERAL jsonb_to_recordset(COALESCE(d.detail->'lots','[]'))
			lot("ruleVersion" text,visits bigint,tokens bigint)
	), totals AS (
		SELECT d.id,d.detail,COALESCE(sum(l.visits),0) AS visits,COALESCE(sum(l.tokens),0) AS tokens,
			count(l.id)=count(l.rule) AND count(l.id)=count(l.visits) AND count(l.id)=count(l.tokens)
				AND COALESCE(bool_and(l.visits>=0 AND l.tokens>=0),true) AS complete
		FROM due d LEFT JOIN lots l USING(id) GROUP BY d.id,d.detail
	), proof AS (
		SELECT COALESCE(bool_and(complete AND (visits=(detail->>'visits')::numeric
			AND tokens=(detail->>'tokens')::numeric) IS TRUE),true) AS valid FROM totals
	), marked AS (
		UPDATE visitor_reward_events e SET summarized_at=$4
		FROM due d,proof WHERE e.id=d.id AND proof.valid RETURNING e.id
	), rolled AS (
		INSERT INTO visitor_day_summaries(garden_id,day,rule_version,kind,microseconds,generated,discarded,visits,tokens)
		SELECT $2,(d.created_at AT TIME ZONE 'UTC')::date,l.rule,d.kind,0,'{}','{}',sum(l.visits),sum(l.tokens)
		FROM marked m JOIN due d USING(id) JOIN lots l USING(id)
		GROUP BY (d.created_at AT TIME ZONE 'UTC')::date,l.rule,d.kind
		ON CONFLICT(garden_id,day,rule_version,kind) DO UPDATE
		SET visits=visitor_day_summaries.visits+excluded.visits,tokens=visitor_day_summaries.tokens+excluded.tokens
	) SELECT valid,(SELECT count(*) FROM marked) FROM proof`, owner, garden, cutoff, now, limit).Scan(&valid, &count)
	if err == nil && !valid {
		err = errHistoryReconciliation
	}
	return count, err
}

func compactVisitorOpportunities(ctx context.Context, tx pgx.Tx, garden string, cutoff time.Time, limit int) (int, error) {
	var valid bool
	var count int
	err := tx.QueryRow(ctx, `WITH due AS MATERIALIZED (
		SELECT p.id,p.status,p.result,e.id AS event_id,e.created_at,e.detail,e.receipt `+visitorOpportunitySources+`
		WHERE p.garden_id=$1 AND p.expires_at<=$2 AND `+visitorOpportunityCovered+`
			AND `+visitorOpportunityProof+` ORDER BY p.expires_at,p.id LIMIT $3
	), proof AS (
		SELECT COALESCE(bool_and(status='expired' OR (
			result->>'eventId'=event_id::text AND result->>'tokens'=COALESCE(receipt->>'tokens',detail->>'tokens')
			AND result->>'visits'=COALESCE(receipt->>'visits',detail->>'visits')
			AND (receipt IS NULL OR jsonb_typeof(receipt->'acceptedAt')='string' AND jsonb_typeof(receipt->'requestId')='string'
				AND receipt->>'eventId'=event_id::text)) IS TRUE),true) AS valid FROM due
	), backfilled AS (
		UPDATE visitor_reward_events e SET receipt=jsonb_build_object('requestId',d.result->'requestId','eventId',d.event_id,
			'visits',d.result->'visits','tokens',d.result->'tokens','acceptedAt',d.created_at,'recoverable',true)
		FROM due d,proof WHERE proof.valid AND d.status='welcomed' AND d.receipt IS NULL AND e.id=d.event_id
		RETURNING e.id
	), removed AS (
		DELETE FROM visitor_opportunities p USING due d,proof WHERE p.id=d.id AND proof.valid
			AND (d.status='expired' OR d.receipt IS NOT NULL OR d.event_id IN (SELECT id FROM backfilled))
		RETURNING p.id
	) SELECT valid,(SELECT count(*) FROM removed) FROM proof`, garden, cutoff, limit).Scan(&valid, &count)
	if err == nil && !valid {
		err = errHistoryReconciliation
	}
	return count, err
}

func compactVisitorHistory(ctx context.Context, tx pgx.Tx, owner, garden string, now time.Time) error {
	report := workerReportFrom(ctx)
	limit := workerSettings(ctx).BatchLimit
	count, err := compactVisitorIntervals(ctx, tx, garden, now)
	if report != nil {
		report.Settlements += int64(count)
	}
	if err != nil || count == limit {
		return err
	}
	remaining := limit - count
	cutoff := now.Add(-7 * 24 * time.Hour)
	count, err = compactVisitorEarnings(ctx, tx, owner, garden, now, cutoff, remaining)
	if report != nil {
		report.Earnings += int64(count)
	}
	if err != nil || count == remaining {
		return err
	}
	remaining -= count
	count, err = compactVisitorOpportunities(ctx, tx, garden, cutoff, remaining)
	if report != nil {
		report.Opportunities += int64(count)
	}
	if err != nil || count == remaining {
		return err
	}
	remaining -= count
	tag, err := tx.Exec(ctx, `WITH due AS (SELECT s.id FROM visitor_sessions s WHERE s.garden_id=$1
		AND s.ended_at<=$2 AND `+visitorSessionUnused+` ORDER BY s.ended_at,s.id LIMIT $3)
		DELETE FROM visitor_sessions s USING due WHERE s.id=due.id`, garden, cutoff, remaining)
	if report != nil {
		report.Dependencies += tag.RowsAffected()
	}
	if err != nil || int(tag.RowsAffected()) == remaining {
		return err
	}
	remaining -= int(tag.RowsAffected())
	tag, err = tx.Exec(ctx, `WITH due AS (SELECT c.id FROM visitor_contexts c WHERE c.garden_id=$1
		AND c.effective_at<=$2 AND `+visitorContextUnused+` ORDER BY c.effective_at,c.id LIMIT $3)
		DELETE FROM visitor_contexts c USING due WHERE c.id=due.id`, garden, cutoff, remaining)
	if report != nil {
		report.Dependencies += tag.RowsAffected()
	}
	return err
}
