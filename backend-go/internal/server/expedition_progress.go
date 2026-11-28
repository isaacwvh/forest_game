package server

import (
	"context"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type expeditionUpdate struct {
	Key         string    `json:"key"`
	Current     *int64    `json:"current,omitempty"`
	Identities  []string  `json:"identities,omitempty"`
	NeedsPair   bool      `json:"needs_pair"`
	Entitlement uuid.UUID `json:"entitlement"`
}

func expeditionCount(key string, current int64) expeditionUpdate {
	return expeditionUpdate{Key: key, Current: &current}
}

func expeditionContribution(key string, id uuid.UUID) expeditionUpdate {
	return expeditionUpdate{Key: key, Identities: []string{id.String()}}
}

// Use the pinned quest definition and keep contributions and rewards in the
// same database transaction. Only newly observed identities advance progress.
func setExpeditionProgress(ctx context.Context, tx pgx.Tx, run uuid.UUID, garden *string, at time.Time, updates []expeditionUpdate) error {
	for i := range updates {
		updates[i].Entitlement = uuid.NewSHA1(run, []byte("quest:"+updates[i].Key))
	}
	four, nine := uuid.NewSHA1(run, []byte("milestone:4")), uuid.NewSHA1(run, []byte("milestone:9"))
	_, err := tx.Exec(ctx, `WITH snap AS MATERIALIZED (
		SELECT r.progress,r.contributions,t.definition FROM expedition_runs r
		JOIN expedition_templates t ON t.version=r.template_version WHERE r.id=$1
	), relevant AS (
		SELECT i.*,q->'reward' AS reward,(q->>'target')::bigint AS target,
			COALESCE(s.progress->i.key->>'current','0')::bigint AS old,
			COALESCE(s.contributions->i.key,'[]'::jsonb) AS seen,s.definition->'tags' AS tags
		FROM snap s CROSS JOIN LATERAL jsonb_array_elements(s.definition->'quests') q
		JOIN jsonb_to_recordset($3::jsonb) i(key text,current bigint,identities jsonb,needs_pair bool,entitlement uuid)
			ON i.key=q->>'id'
		WHERE s.progress->i.key->>'completedAt' IS NULL
	), eligible AS (
		SELECT r.* FROM relevant r
		WHERE NOT r.needs_pair OR EXISTS (
			SELECT 1 FROM garden_placements l JOIN owned_plants p ON p.id=l.plant_id
			JOIN garden_placements h ON h.garden_id=l.garden_id AND h.plant_id<>l.plant_id
			JOIN owned_plants q ON q.id=h.plant_id
			WHERE l.garden_id=$4::uuid AND r.tags->p.species_id ? 'tree' AND r.tags->q.species_id ? 'herb'
		)
	), accepted AS (
		SELECT e.*,COALESCE(n.fresh,'[]'::jsonb) AS fresh
		FROM eligible e LEFT JOIN LATERAL (
			SELECT jsonb_agg(a.identity ORDER BY a.ord) AS fresh FROM (
				SELECT identity,min(ord) AS ord
				FROM jsonb_array_elements_text(e.identities) WITH ORDINALITY i(identity,ord)
				WHERE NOT (e.seen ? identity) GROUP BY identity ORDER BY min(ord)
				LIMIT greatest(0,e.target-jsonb_array_length(e.seen))
			) a
		) n ON e.identities IS NOT NULL
	), proposed AS (
		SELECT a.*,CASE WHEN a.identities IS NULL THEN least(a.target,greatest(0,a.current))
			ELSE jsonb_array_length(a.seen)+jsonb_array_length(a.fresh) END AS next,
			CASE WHEN a.identities IS NULL THEN 1 ELSE jsonb_array_length(a.fresh) END AS versions
		FROM accepted a
	), changes AS MATERIALIZED (
		SELECT * FROM proposed WHERE next<>old AND versions>0
	), agg AS (
		SELECT jsonb_object_agg(key,jsonb_build_object('current',next,
				'completedAt',CASE WHEN next=target THEN $2::timestamptz END)) AS progress,
			COALESCE(jsonb_object_agg(key,seen||fresh) FILTER(WHERE identities IS NOT NULL),'{}'::jsonb) AS contributions,
			COALESCE(sum(versions),0)::bigint AS versions FROM changes
	), saved AS (
		UPDATE expedition_runs r SET progress=r.progress||a.progress,contributions=r.contributions||a.contributions,
			progress_version=r.progress_version+a.versions FROM agg a WHERE r.id=$1 AND a.versions>0
		RETURNING r.progress
	), earned AS (
		SELECT entitlement,'quest:'||key AS key,reward FROM changes WHERE next=target
		UNION ALL
		SELECT CASE WHEN m->>'count'='4' THEN $5::uuid ELSE $6::uuid END,
			'milestone:'||(m->>'count'),m->'reward'
		FROM saved s CROSS JOIN snap t CROSS JOIN LATERAL jsonb_array_elements(t.definition->'milestones') m
		WHERE (m->>'count')::int<=(SELECT count(*) FROM jsonb_each(s.progress) p WHERE p.value->>'completedAt' IS NOT NULL)
	)
	INSERT INTO expedition_entitlements(id,run_id,reward_key,earned_at,reward)
	SELECT entitlement,$1,key,$2,reward FROM earned ON CONFLICT DO NOTHING`,
		run, at, updates, garden, four, nine)
	return err
}

func observeExpeditionGarden(ctx context.Context, tx pgx.Tx, run *uuid.UUID, garden string, at time.Time, before map[uuid.UUID]string) error {
	if run == nil {
		return nil
	}
	var items, stages int64
	var advanced []string
	err := tx.QueryRow(ctx, `WITH planted AS (
		SELECT p.id,CASE WHEN p.growth_micro_units>=(g.thresholds->>'adult')::bigint THEN 4
			WHEN p.growth_micro_units>=(g.thresholds->>'young')::bigint THEN 3
			WHEN p.growth_micro_units>=(g.thresholds->>'seedling')::bigint THEN 2 ELSE 1 END AS stage
		FROM garden_placements l JOIN owned_plants p ON p.id=l.plant_id
		JOIN growth_profiles g ON (g.id,g.version)=(p.growth_profile_id,p.growth_profile_version)
		WHERE l.garden_id=$1
	) SELECT (SELECT count(*) FROM item_placements WHERE garden_id=$1),
		(SELECT count(DISTINCT stage) FROM planted),
		ARRAY(SELECT p.id::text FROM planted p
			WHERE p.stage>array_position(ARRAY['sprout','seedling','young','adult'],$2::jsonb->>p.id::text) ORDER BY p.id)`, garden, before).
		Scan(&items, &stages, &advanced)
	if err != nil {
		return err
	}
	updates := []expeditionUpdate{expeditionCount("items_together_4", items), expeditionCount("all_stages_together", stages)}
	if len(advanced) > 0 {
		updates = append(updates, expeditionUpdate{Key: "copies_advanced_4", Identities: advanced})
	}
	return setExpeditionProgress(ctx, tx, *run, nil, at, updates)
}

func observeExpeditionWelcome(ctx context.Context, tx pgx.Tx, owner, garden string, at time.Time, opportunity uuid.UUID) error {
	run, err := expeditionAt(ctx, tx, owner, at)
	if err != nil || run == nil {
		return err
	}
	welcome := expeditionContribution("active_butterflies_100", opportunity)
	pair := expeditionContribution("tree_herb_butterflies_50", opportunity)
	pair.NeedsPair = true
	return setExpeditionProgress(ctx, tx, *run, &garden, at, []expeditionUpdate{welcome, pair})
}

func expeditionPlantStages(plants []activityPlant) map[uuid.UUID]string {
	before := make(map[uuid.UUID]string, len(plants))
	for _, p := range plants {
		before[p.id] = p.stage(p.growth)
	}
	return before
}
