package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (s *Server) currentExpedition(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	if r.Header.Get("X-Forest-Expeditions") != "1" {
		return nil, expeditionClientUpdate
	}
	retry := false
	switch strings.ToLower(r.URL.Query().Get("retryOlder")) {
	case "", "0", "false", "off", "no", "n", "f":
	case "1", "true", "on", "yes", "y", "t":
		retry = true
	default:
		return nil, invalid
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	g, err := readGardenRecord(ctx, tx, owner.ID)
	if err != nil {
		return nil, err
	}
	now, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	if err := s.settleGardenDaily(ctx, tx, &g, now, owner.Timezone); err != nil {
		return nil, err
	}
	run, err := expeditionAt(ctx, tx, owner.ID, now)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"serverNow": now, "current": nil, "previous": []json.RawMessage{}}
	if run == nil {
		return result, nil
	}
	if err := observeExpeditionGarden(ctx, tx, run, g.id, now, nil); err != nil {
		return nil, err
	}
	ids := []uuid.UUID{*run}
	if month := expeditionMonth(now); now.Before(month.AddDate(0, 0, 7)) {
		prior, err := expeditionAt(ctx, tx, owner.ID, month.Add(-time.Microsecond))
		if err != nil {
			return nil, err
		}
		if prior != nil {
			ids = append(ids, *prior)
		}
	}
	docs, err := expeditionDocuments(ctx, tx, owner.ID, ids, now, retry)
	if err != nil {
		return nil, err
	}
	if len(docs) == 0 {
		return nil, expeditionUnavailable
	}
	result["current"] = docs[0]
	result["previous"] = docs[1:]
	return result, nil
}

func (s *Server) expeditionArchive(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	if r.Header.Get("X-Forest-Expeditions") != "1" {
		return nil, expeditionClientUpdate
	}
	ctx := r.Context()
	q := r.URL.Query()
	limit := 12
	if q.Has("limit") {
		n, err := strconv.Atoi(q.Get("limit"))
		if err != nil || n < 1 || n > 50 {
			return nil, invalid
		}
		limit = n
	}
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	var cutoff *time.Time
	if q.Has("before") {
		id, err := uuid.Parse(q.Get("before"))
		if err != nil {
			return nil, invalid
		}
		err = tx.QueryRow(ctx, "SELECT month FROM expedition_runs WHERE owner_id=$1 AND id=$2", owner.ID, id).Scan(&cutoff)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, expeditionNotFound
		}
		if err != nil {
			return nil, err
		}
	}
	rows, err := tx.Query(ctx, `SELECT id FROM expedition_runs WHERE owner_id=$1 AND ($2::date IS NULL OR month<$2)
		ORDER BY month DESC LIMIT $3`, owner.ID, cutoff, limit+1)
	if err != nil {
		return nil, err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return nil, err
	}
	var next *uuid.UUID
	if len(ids) > limit {
		ids = ids[:limit]
		next = &ids[limit-1]
	}
	docs := []json.RawMessage{}
	if len(ids) > 0 {
		now, err := s.gardenNow(ctx, tx)
		if err != nil {
			return nil, err
		}
		docs, err = expeditionDocuments(ctx, tx, owner.ID, ids, now, false)
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{"runs": docs, "nextCursor": next}, nil
}

func (s *Server) expeditionDetail(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	if r.Header.Get("X-Forest-Expeditions") != "1" {
		return nil, expeditionClientUpdate
	}
	id, err := uuid.Parse(r.PathValue("run"))
	if err != nil {
		return nil, invalid
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	now, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	docs, err := expeditionDocuments(ctx, tx, owner.ID, []uuid.UUID{id}, now, false)
	if err != nil {
		return nil, err
	}
	if len(docs) == 0 {
		return nil, expeditionNotFound
	}
	return docs[0], nil
}

// A page is one bounded read. Raw evidence rows, templates and contribution
// IDs remain in PostgreSQL. Coverage only projects unresolved date intervals.
func expeditionDocuments(ctx context.Context, tx pgx.Tx, owner string, ids []uuid.UUID, now time.Time, retry bool) ([]json.RawMessage, error) {
	rows, err := tx.Query(ctx, `SELECT jsonb_build_object(
		'runId',r.id,'month',r.month,'templateVersion',r.template_version,'name',t.definition->>'name','timezone','UTC',
		'serverNow',$3::timestamptz,'startsAt',r.starts_at,'endsAt',r.ends_at,'evidenceUntil',r.evidence_until,
		'progressVersion',r.progress_version,'completedCount',quests.completed,'artworkKey',t.definition->>'artworkKey',
		'quests',quests.rows,'rewards',rewards.rows,'coverage',coverage.rows)
	FROM unnest($2::uuid[]) WITH ORDINALITY requested(id,pos)
	JOIN expedition_runs r ON r.id=requested.id AND r.owner_id=$1
	JOIN expedition_templates t ON t.version=r.template_version
	JOIN users u ON u.id=r.owner_id
	LEFT JOIN activity_devices d ON d.owner_id=u.id AND d.revoked_at IS NULL
	CROSS JOIN LATERAL (
		SELECT COALESCE(jsonb_agg(doc ORDER BY e.earned_at,e.reward_key),'[]'::jsonb) AS rows,
			COALESCE(jsonb_object_agg(e.reward_key,doc),'{}'::jsonb) AS by_key
		FROM expedition_entitlements e LEFT JOIN expedition_claims c ON c.entitlement_id=e.id
		CROSS JOIN LATERAL (SELECT jsonb_build_object('id',e.id,'rewardKey',e.reward_key,'reward',e.reward,
			'claimed',c.entitlement_id IS NOT NULL) AS doc) dto WHERE e.run_id=r.id
	) rewards
	CROSS JOIN LATERAL (
		SELECT COALESCE(jsonb_agg(q||COALESCE(r.progress->(q->>'id'),'{"current":0,"completedAt":null}'::jsonb)
			||jsonb_build_object('entitlement',rewards.by_key->('quest:'||(q->>'id'))) ORDER BY ord),'[]'::jsonb) AS rows,
			count(*) FILTER(WHERE r.progress->(q->>'id')->>'completedAt' IS NOT NULL) AS completed
		FROM jsonb_array_elements(t.definition->'quests') WITH ORDINALITY q(q,ord)
	) quests
	CROSS JOIN LATERAL (
		SELECT COALESCE(jsonb_agg(jsonb_build_object('gameDate',date,'startsAt',bounds.a,'through',bounds.b,
			'stepsNeeded',need.steps,'workoutsNeeded',need.workouts) ORDER BY date),'[]'::jsonb) AS rows
		FROM (SELECT greatest(r.starts_at,u.created_at,d.baseline_at) AS instant
			WHERE d.baseline_at IS NOT NULL AND $3<r.evidence_until) start
		CROSS JOIN LATERAL (SELECT date_trunc('milliseconds',instant)+CASE WHEN instant>date_trunc('milliseconds',instant)
			THEN interval '1 millisecond' ELSE interval '0' END AS at) eligible
		CROSS JOIN LATERAL (SELECT (eligible.at AT TIME ZONE 'UTC')::date AS first,
			(least(r.ends_at,$3) AT TIME ZONE 'UTC')::date AS last,
			($3 AT TIME ZONE 'UTC')::date-6 AS recent) dates
		CROSS JOIN LATERAL generate_series(0,dates.last-dates.first) g(n)
		CROSS JOIN LATERAL (SELECT dates.first+g.n AS date) day
		CROSS JOIN LATERAL (SELECT greatest(day.date::timestamp AT TIME ZONE 'UTC',eligible.at) AS a,
			least((day.date+1)::timestamp AT TIME ZONE 'UTC',r.ends_at,$3) AS b) bounds
		LEFT JOIN expedition_days e ON e.run_id=r.id AND e.device_id=d.id AND e.game_date=day.date
		CROSS JOIN LATERAL (
			SELECT (r.progress->'steps_days_3'->>'completedAt' IS NULL OR r.progress->'monthly_steps_30000'->>'completedAt' IS NULL)
				AND ($4::bool OR day.date>=dates.recent OR e.steps_through IS NULL OR e.steps_through<bounds.b) AS steps,
				r.progress->'run_walk_sessions_3'->>'completedAt' IS NULL
				AND ($4::bool OR day.date>=dates.recent OR e.workouts_through IS NULL OR e.workouts_through<bounds.b) AS workouts
		) need
		WHERE bounds.a<bounds.b AND (need.steps OR need.workouts)
	) coverage
	ORDER BY requested.pos`, owner, ids, now, retry)
	if err != nil {
		return nil, err
	}
	return pgx.AppendRows([]json.RawMessage{}, rows, pgx.RowTo[json.RawMessage])
}
