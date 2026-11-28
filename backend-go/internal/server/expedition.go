package server

import (
	"context"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var (
	expeditionUnavailable  = &apiError{503, "garden_expedition_unavailable", "Garden expedition progress is unavailable"}
	expeditionNotFound     = &apiError{404, "expedition_not_found", "Expedition not found"}
	expeditionClientUpdate = &apiError{426, "expedition_update_required", "Update the app to use expeditions"}
)

type expeditionRun struct {
	id                        uuid.UUID
	start, end, evidenceUntil time.Time
}

func expeditionMonth(at time.Time) time.Time {
	t := at.UTC()
	return time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// Resolve the template under the lock shared with publication. The hot path
// only receives the run ID. A first request materializes the UTC month lazily.
func expeditionAt(ctx context.Context, tx pgx.Tx, owner string, at time.Time) (*uuid.UUID, error) {
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock_shared(591417021)"); err != nil {
		return nil, err
	}
	month := expeditionMonth(at)
	var current *uuid.UUID
	var template *string
	var starts *time.Time
	var valid bool
	err := tx.QueryRow(ctx, `WITH scheduled AS (
		SELECT template_version FROM expedition_schedule WHERE month<=$2::date ORDER BY month DESC LIMIT 1
	)
	SELECT r.id,CASE WHEN r.id IS NULL THEN s.template_version END,
		CASE WHEN r.id IS NULL THEN COALESCE(l.starts_at,$2::date::timestamp AT TIME ZONE 'UTC') END,
		(jsonb_typeof(t.definition->'quests')='array' AND jsonb_typeof(t.definition->'milestones')='array'
			AND jsonb_typeof(t.definition->'tags')='object') IS TRUE
	FROM scheduled s
	LEFT JOIN expedition_launches l ON l.month=$2::date
	LEFT JOIN expedition_runs r ON r.owner_id=$1 AND r.month=$2::date
	JOIN expedition_templates t ON t.version=COALESCE(r.template_version,s.template_version)
	WHERE $3>=COALESCE(r.starts_at,l.starts_at,$2::date::timestamp AT TIME ZONE 'UTC')`, owner, month, at).
		Scan(&current, &template, &starts, &valid)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !valid {
		return nil, expeditionUnavailable
	}
	if current != nil {
		return current, nil
	}
	id := uuid.NewSHA1(uuid.NameSpaceURL, []byte("forest/expedition/"+owner+"/"+month.Format(time.DateOnly)))
	end := month.AddDate(0, 1, 0)
	_, err = tx.Exec(ctx, `INSERT INTO expedition_runs(id,owner_id,month,template_version,starts_at,ends_at,evidence_until,progress_version,progress,contributions)
		VALUES($1,$2,$3,$4,$5,$6,$7,0,'{}','{}')`, id, owner, month, template, starts, end, end.AddDate(0, 0, 7))
	return &id, err
}

func readExpeditionRun(ctx context.Context, tx pgx.Tx, owner string, id uuid.UUID) (expeditionRun, error) {
	run := expeditionRun{id: id}
	err := tx.QueryRow(ctx, `SELECT starts_at,ends_at,evidence_until FROM expedition_runs WHERE owner_id=$1 AND id=$2`, owner, id).
		Scan(&run.start, &run.end, &run.evidenceUntil)
	if errors.Is(err, pgx.ErrNoRows) {
		err = expeditionNotFound
	}
	return run, err
}

func expeditionEligibility(created time.Time, baseline time.Time, runStart time.Time) time.Time {
	boundary := maxTime(runStart, maxTime(created, baseline))
	at := boundary.Truncate(time.Millisecond)
	if at.Before(boundary) {
		at = at.Add(time.Millisecond)
	}
	return at.UTC()
}
