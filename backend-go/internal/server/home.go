package server

import (
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (s *Server) homeAttention(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	ctx := r.Context()
	// The first attention read may enroll the account. Lock the owner before
	// the catalogue, as claim and activity transactions do.
	var owner uuid.UUID
	var active bool
	var fixture, legacy *bool
	err := tx.QueryRow(ctx, `WITH account AS MATERIALIZED (
		SELECT id,status='active' AS active FROM users WHERE auth_issuer=$1 AND auth_subject=$2 FOR UPDATE
	)
	SELECT a.id,a.active,c.is_fixture,c.legacy FROM account a LEFT JOIN LATERAL (
		SELECT is_fixture,version IN ('woodland-v1','launch-balance-v1','launch-visitors-v2') AS legacy
		FROM game_catalogue WHERE id=1 AND a.active FOR SHARE
	) c ON true`, id.Issuer, id.Subject).Scan(&owner, &active, &fixture, &legacy)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, accountRequired
	}
	if err != nil {
		return nil, err
	}
	if !active {
		return nil, accountDisabled
	}
	if fixture == nil || legacy == nil {
		return nil, catalogueUnavailable
	}
	if *fixture && s.Environment != "local" && s.Environment != "test" {
		return nil, fixtureCatalogueDisabled
	}
	var milestones, expeditions, packs int64
	var initialize bool
	var clock *time.Time
	if s.visitorClock != nil {
		at := s.visitorClock().UTC()
		clock = &at
	}
	err = tx.QueryRow(ctx, `
WITH owner AS (SELECT $1::uuid AS id),
	boundary AS (SELECT COALESCE($5::timestamptz,clock_timestamp()) AS at),
	active AS (SELECT version FROM milestone_policies,boundary WHERE active AND effective_at<=at),
	hosted AS (SELECT COALESCE(hosted_active::numeric+hosted_offline,0) AS n FROM visitor_wallets WHERE owner_id=$1),
	progress AS (SELECT * FROM player_progress WHERE owner_id=$1),
	legacy AS (
		SELECT 'first_movement' AS key WHERE EXISTS (SELECT 1 FROM progress
			WHERE activity_steps>0 OR EXISTS (SELECT 1 FROM jsonb_each_text(activity_metrics)
				WHERE value ~ '^[1-9][0-9]*(/[1-9][0-9]*)?$'))
		UNION ALL SELECT 'first_hosted' WHERE (SELECT n FROM hosted)>=1
		UNION ALL SELECT 'three_hosted' WHERE (SELECT n FROM hosted)>=3
		UNION ALL SELECT 'first_seedling' WHERE EXISTS (SELECT 1 FROM progress WHERE first_seedling_at IS NOT NULL)
		UNION ALL SELECT 'first_maturity' WHERE EXISTS (SELECT 1 FROM progress WHERE first_maturity_count>0)
	)
SELECT CASE WHEN EXISTS (SELECT 1 FROM active)
	THEN CASE WHEN $3::bool THEN (
		`+milestoneAttentionCount+`
	) ELSE 0 END
	WHEN $2::bool THEN (SELECT count(*) FROM legacy WHERE NOT EXISTS (
		SELECT 1 FROM milestone_claims c WHERE c.owner_id=owner.id AND c.milestone_id=legacy.key))
	ELSE 0 END,
	CASE WHEN $4::bool THEN (SELECT count(*) FROM expedition_entitlements e JOIN expedition_runs r ON r.id=e.run_id
		WHERE r.owner_id=owner.id AND r.starts_at<=boundary.at AND r.ends_at>boundary.at
		AND NOT EXISTS (SELECT 1 FROM expedition_claims c WHERE c.entitlement_id=e.id)) ELSE 0 END,
	(SELECT count(*) FROM owned_packs p WHERE p.owner_id=owner.id AND NOT EXISTS (
		SELECT 1 FROM pack_openings o WHERE o.pack_id=p.id)),
	$3::bool AND EXISTS (SELECT 1 FROM active) AND NOT EXISTS (SELECT 1 FROM milestone_state WHERE owner_id=owner.id)
FROM owner,boundary`, owner, *legacy,
		r.Header.Get("X-Forest-Milestones") == "1", r.Header.Get("X-Forest-Expeditions") == "1", clock).Scan(&milestones, &expeditions, &packs, &initialize)
	if err != nil {
		return nil, err
	}
	if initialize {
		at, err := s.gardenNow(ctx, tx)
		if err != nil {
			return nil, err
		}
		policy, err := readMilestonePolicy(ctx, tx)
		if err != nil {
			return nil, err
		}
		if policy.version != "" && !at.Before(policy.effective) {
			if !policy.valid {
				return nil, milestonesUnavailable
			}
			if err := refreshMilestoneEntitlements(ctx, tx, owner.String(), at); err != nil {
				return nil, err
			}
			err = tx.QueryRow(ctx, `SELECT (`+milestoneAttentionCount+`) FROM (SELECT $1::uuid AS id) owner,
				(SELECT $2::timestamptz AS at) boundary`, owner, at).Scan(&milestones)
			if err != nil {
				return nil, err
			}
		}
	}
	return map[string]any{"userId": owner, "milestoneCount": milestones, "expeditionCount": expeditions, "unopenedPackCount": packs}, nil
}

const milestoneAttentionCount = `SELECT count(*) FROM milestone_entitlements e
	WHERE e.owner_id=owner.id AND e.superseded_by IS NULL AND e.legacy_id IS NULL
	AND NOT EXISTS(SELECT 1 FROM milestone_claims c WHERE c.owner_id=e.owner_id AND c.milestone_id=e.milestone_id)
	AND (NOT (e.definition ? 'eventId') OR EXISTS(SELECT 1 FROM milestone_events m
		WHERE m.event_id=e.definition->>'eventId' AND m.claim_until>boundary.at))`
