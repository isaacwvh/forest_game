package server

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

const historyLimit = 500
const historyLock int64 = 711004006

// Work discovery is one indexed, bounded read. Idle passes return no row, so
// enabling another history family does not add an empty database response.
func runHistory(ctx context.Context, tx pgx.Tx) (string, error) {
	return maintainHistory(ctx, tx, nil)
}

func maintainHistory(ctx context.Context, tx pgx.Tx, at *time.Time) (string, error) {
	config := workerSettings(ctx)
	if config.Responses {
		if err := compactRequestHistory(ctx, tx, at); err != nil {
			return "", err
		}
	}
	if !config.Visitors && !config.Growth {
		return "ok", nil
	}
	var owner *string
	var visitor, growth bool
	var now time.Time
	err := tx.QueryRow(ctx, `WITH work AS MATERIALIZED (
		(SELECT g.owner_id,s.end_at AS cutoff,true AS visitor FROM visitor_settlements s
			JOIN gardens g ON g.id=s.garden_id JOIN garden_visitor_state v ON v.garden_id=g.id
			WHERE $3 AND s.end_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days' AND s.end_at<=v.settled_at
				AND s.end_at-s.start_at<=interval '366 days' ORDER BY s.end_at LIMIT $1)
		UNION ALL
		(SELECT e.owner_id,e.created_at,true FROM visitor_reward_events e
			WHERE $3 AND e.created_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days' AND `+visitorEarningsDue+`
			ORDER BY e.created_at LIMIT $1)
		UNION ALL
		(SELECT g.owner_id,p.expires_at,true `+visitorOpportunitySources+`
			WHERE $3 AND p.expires_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days'
				AND `+visitorOpportunityCovered+` AND `+visitorOpportunityProof+`
			ORDER BY p.expires_at LIMIT $1)
		UNION ALL
		(SELECT s.owner_id,s.ended_at,true FROM visitor_sessions s WHERE $3 AND s.ended_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days'
			AND `+visitorSessionUnused+` ORDER BY s.ended_at LIMIT $1)
		UNION ALL
		(SELECT g.owner_id,c.effective_at,true FROM visitor_contexts c JOIN gardens g ON g.id=c.garden_id
			WHERE $3 AND c.effective_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days' AND `+visitorContextUnused+`
			ORDER BY c.effective_at LIMIT $1)
		UNION ALL
		(SELECT c.owner_id,c.accepted_at,false FROM activity_credits c
			JOIN api_requests r ON (r.user_id,r.request_id)=(c.owner_id,c.request_id) AND r.operation='activity_sync'
			WHERE $4 AND c.accepted_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '30 days' AND `+recoverableActivityHistory+`
				AND EXISTS(SELECT 1 FROM plant_growth_credits p WHERE p.activity_credit_id=c.id)
			ORDER BY c.accepted_at LIMIT $1)
		UNION ALL
		(SELECT owner_id,acknowledged_at,false FROM reward_recaps WHERE $4 AND acknowledged_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '7 days'
			AND NOT (payload ? 'compacted') ORDER BY acknowledged_at LIMIT $1)
		UNION ALL
		(SELECT e.owner_id,e.accepted_at,false FROM reward_events e WHERE $4 AND e.accepted_at<=COALESCE($2::timestamptz,statement_timestamp())-interval '30 days'
			AND NOT (payload ? 'compacted') AND NOT (`+openGrowthRecap+`) ORDER BY e.accepted_at LIMIT $1)
	), grouped AS MATERIALIZED (
		SELECT owner_id,min(cutoff) AS oldest,bool_or(visitor) AS visitor,bool_or(NOT visitor) AS growth
		FROM work GROUP BY owner_id
	), picked AS MATERIALIZED (
		SELECT u.id,w.visitor,w.growth FROM grouped w JOIN users u ON u.id=w.owner_id
		ORDER BY w.oldest,u.id LIMIT 1 FOR UPDATE OF u SKIP LOCKED
	) SELECT id::text,visitor,growth,COALESCE($2::timestamptz,statement_timestamp()) FROM picked
	UNION ALL SELECT NULL,false,false,COALESCE($2::timestamptz,statement_timestamp()) WHERE NOT EXISTS(SELECT 1 FROM picked)
		AND $4 AND EXISTS(SELECT 1 FROM growth_provenance g WHERE `+unusedGrowthProvenance+`)`, config.BatchLimit, at, config.Visitors, config.Growth).
		Scan(&owner, &visitor, &growth, &now)
	if errors.Is(err, pgx.ErrNoRows) {
		return "ok", nil
	}
	if err != nil {
		return "", err
	}
	var locked bool
	if err := tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock($1)", historyLock).Scan(&locked); err != nil {
		return "", err
	}
	if !locked {
		return "skipped", nil
	}
	if owner != nil {
		var garden string
		err := tx.QueryRow(ctx, "SELECT id::text FROM gardens WHERE owner_id=$1 FOR UPDATE SKIP LOCKED", *owner).Scan(&garden)
		if errors.Is(err, pgx.ErrNoRows) {
			return "ok", nil
		}
		if err != nil {
			return "", err
		}
		if visitor {
			if err := reconcileVisitorHistory(ctx, tx, *owner, garden); err != nil {
				return "", err
			}
			if err := compactVisitorHistory(ctx, tx, *owner, garden, now); err != nil {
				return "", err
			}
		}
		if growth {
			if err := compactGrowthHistory(ctx, tx, *owner, now); err != nil {
				return "", err
			}
		}
	}
	if config.Growth {
		return "ok", retireGrowthProvenance(ctx, tx)
	}
	return "ok", nil
}
