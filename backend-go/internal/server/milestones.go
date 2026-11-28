package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

var (
	milestonesUnavailable = &apiError{503, "milestones_unavailable", "Milestone tracks are unavailable"}
	milestoneNotFound     = &apiError{404, "milestone_not_found", "This milestone is not available"}
)

type milestonePolicy struct {
	version   string
	effective time.Time
	valid     bool
}

func readMilestonePolicy(ctx context.Context, tx pgx.Tx) (milestonePolicy, error) {
	var p milestonePolicy
	err := tx.QueryRow(ctx, `SELECT version,effective_at,
		(jsonb_typeof(definition->'quests')='array' AND jsonb_typeof(definition->'species')='object') IS TRUE
		FROM milestone_policies WHERE active`).Scan(&p.version, &p.effective, &p.valid)
	if errors.Is(err, pgx.ErrNoRows) {
		return p, nil
	}
	return p, err
}

// These metrics come from permanent ledgers. Short-window event and workout
// facts live in milestone_state and are overlaid by the lifetime facts here.
const milestoneLifetimeValues = `COALESCE(state.progress,'{}'::jsonb)||jsonb_build_object(
	'opening',1,'steps',COALESCE(p.activity_steps,0),
	'seedling',CASE WHEN p.first_seedling_at IS NULL THEN 0 ELSE 1 END,
	'maturity',COALESCE(p.first_maturity_count,0),
	'butterflies',COALESCE(w.hosted_active,0)::numeric+COALESCE(w.hosted_offline,0))||rarities.facts`

const legacyMilestoneQuests = `VALUES ('first_movement','steps_1000'),('first_hosted','butterfly_1'),
	('three_hosted','butterfly_3'),('first_seedling','growth_first_seedling'),('first_maturity','growth_mature_1')`

// Shared writes for all lifetime milestone observers. Evidence and discovery
// remain in PostgreSQL. Issued entitlement definitions never change.
func refreshMilestoneEntitlements(ctx context.Context, tx pgx.Tx, owner string, at time.Time) error {
	_, err := tx.Exec(ctx, `WITH policy AS MATERIALIZED (
		SELECT version,effective_at,definition FROM milestone_policies WHERE active AND effective_at<=$2
	), state AS MATERIALIZED (
		SELECT progress FROM milestone_state WHERE owner_id=$1
	), enrolled AS (
		INSERT INTO milestone_state(owner_id,policy_version,enrolled_at,progress)
		SELECT $1,version,effective_at,'{}' FROM policy ON CONFLICT DO NOTHING RETURNING 1
	), new_species AS (
		INSERT INTO milestone_species(owner_id,species_id,rarity)
		SELECT DISTINCT $1,d.species_id,policy.definition->'species'->>d.species_id
		FROM policy JOIN catalog_stage_discoveries d ON d.owner_id=$1
		WHERE policy.definition->'species' ? d.species_id ON CONFLICT DO NOTHING RETURNING rarity
	), all_species AS (
		SELECT rarity FROM milestone_species WHERE owner_id=$1 UNION ALL SELECT rarity FROM new_species
	), rarities AS (
		SELECT COALESCE(jsonb_object_agg('discovery_'||rarity,total),'{}'::jsonb) AS facts
		FROM (SELECT rarity,count(*) AS total FROM all_species GROUP BY rarity) counted
	), qualifying AS (
		SELECT policy.version,policy.definition,`+milestoneLifetimeValues+` AS facts
		FROM policy LEFT JOIN state ON true
		LEFT JOIN player_progress p ON p.owner_id=$1 LEFT JOIN visitor_wallets w ON w.owner_id=$1 CROSS JOIN rarities
	), legacy AS MATERIALIZED (
		SELECT milestone_id,claimed_at FROM milestone_claims WHERE owner_id=$1 AND EXISTS(SELECT 1 FROM enrolled)
	), legacy_map AS (
		SELECT m.key,l.milestone_id AS old FROM legacy l JOIN (`+legacyMilestoneQuests+`) m(id,key) ON m.id=l.milestone_id
		UNION ALL (SELECT 'steps_new_beginnings',milestone_id FROM legacy ORDER BY claimed_at,milestone_id LIMIT 1)
	)
	INSERT INTO milestone_entitlements(owner_id,milestone_id,policy_version,earned_at,definition,superseded_by,legacy_id)
	SELECT $1,q->>'milestoneId',v.version,$2,q,
		CASE WHEN m.old IS NULL AND q->>'milestoneId'='special_run_5km'
			AND v.facts->>'first_run_5'=v.facts->>'first_run_10' AND COALESCE(v.facts->>'first_run_10','')<>''
			THEN 'special_run_10km' END,
		m.old
	FROM qualifying v CROSS JOIN LATERAL jsonb_array_elements(v.definition->'quests') q
	LEFT JOIN legacy_map m ON m.key=q->>'milestoneId'
	WHERE m.old IS NOT NULL OR `+milestoneThresholdSQL+`
	ON CONFLICT (owner_id,milestone_id) DO NOTHING`, owner, at)
	return err
}

// All published thresholds are whole quantities. Cross multiplication
// preserves exact workout fractions even at a threshold boundary.
const milestoneThresholdSQL = `COALESCE(split_part(v.facts->>(q->>'metric'),'/',1)::numeric,0)
	>= (q->>'threshold')::numeric*COALESCE(NULLIF(split_part(v.facts->>(q->>'metric'),'/',2),'')::numeric,1)`

func (s *Server) collectionMilestones(r *http.Request, tx pgx.Tx, owner, catalogue string) ([]map[string]any, error) {
	ctx := r.Context()
	policy, err := readMilestonePolicy(ctx, tx)
	if err != nil {
		return nil, err
	}
	if policy.version == "" {
		return legacyMilestones(ctx, tx, owner, catalogue)
	}
	if r.Header.Get("X-Forest-Milestones") != "1" {
		return []map[string]any{}, nil
	}
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	if at.Before(policy.effective) {
		return []map[string]any{}, nil
	}
	if !policy.valid {
		return nil, milestonesUnavailable
	}
	if err := refreshMilestoneEntitlements(ctx, tx, owner, at); err != nil {
		return nil, err
	}
	return advancedMilestones(ctx, tx, owner, policy.version, at, nil)
}

func advancedMilestones(ctx context.Context, tx pgx.Tx, owner, policy string, at time.Time, only *string) ([]map[string]any, error) {
	rows, err := tx.Query(ctx, `WITH lifetime AS MATERIALIZED (
		SELECT `+milestoneLifetimeValues+` AS facts
		FROM (SELECT $1::uuid AS owner_id) o
		LEFT JOIN milestone_state state USING(owner_id)
		LEFT JOIN player_progress p USING(owner_id) LEFT JOIN visitor_wallets w USING(owner_id)
		CROSS JOIN LATERAL (
			SELECT COALESCE(jsonb_object_agg('discovery_'||rarity,total),'{}'::jsonb) AS facts
			FROM (SELECT rarity,count(*) AS total FROM milestone_species WHERE owner_id=$1 GROUP BY rarity) counted
		) rarities
	), definitions AS (
		SELECT q.definition,q.position,0 AS section,'' AS event_key,facts,NULL::timestamptz AS ends_at,NULL::timestamptz AS claim_until
		FROM milestone_policies p CROSS JOIN LATERAL jsonb_array_elements(p.definition->'quests') WITH ORDINALITY q(definition,position)
		CROSS JOIN lifetime WHERE p.version=$2
		UNION ALL
		SELECT q.definition||jsonb_build_object('eventName',m.name,'startsAt',m.starts_at,'endsAt',m.ends_at,'claimUntil',m.claim_until),
			q.position,1,m.event_id,COALESCE(s.progress,'{}'::jsonb),m.ends_at,m.claim_until
		FROM milestone_events m LEFT JOIN milestone_event_state s ON s.event_id=m.event_id AND s.owner_id=$1
		CROSS JOIN LATERAL jsonb_array_elements(m.definition->'quests') WITH ORDINALITY q(definition,position)
		WHERE s.owner_id IS NOT NULL OR (m.starts_at<=$3 AND m.ends_at>$3)
	) SELECT d.definition||COALESCE(e.definition,'{}')||jsonb_build_object(
		'description',d.definition->>'title','policyVersion',$2::text,
		'progress',COALESCE(d.facts->>(d.definition->>'metric'),'0'),
		'eligible', e.milestone_id IS NOT NULL AND c.milestone_id IS NULL AND e.legacy_id IS NULL
			AND e.superseded_by IS NULL AND (d.claim_until IS NULL OR d.claim_until>$3),
		'claimed',c.milestone_id IS NOT NULL OR e.legacy_id IS NOT NULL,
		'supersededBy',e.superseded_by,'legacyMilestoneId',e.legacy_id,'earnedAt',e.earned_at,
		'unavailableReason',CASE WHEN d.claim_until<=$3 AND c.milestone_id IS NULL AND e.legacy_id IS NULL
			THEN 'Event claim period ended. Your earned reward is retained.' END)
	FROM definitions d
	LEFT JOIN milestone_entitlements e ON e.owner_id=$1 AND e.milestone_id=d.definition->>'milestoneId'
	LEFT JOIN milestone_claims c ON c.owner_id=$1 AND c.milestone_id=d.definition->>'milestoneId'
	WHERE ($4::text IS NULL OR d.definition->>'milestoneId'=$4)
		AND (d.ends_at IS NULL OR d.ends_at>$3 OR e.milestone_id IS NOT NULL)
	ORDER BY d.section,d.event_key,d.position`, owner, policy, at, only)
	if err != nil {
		return nil, err
	}
	return pgx.AppendRows([]map[string]any{}, rows, pgx.RowTo[map[string]any])
}
