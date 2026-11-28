package server

import (
	"context"
	"encoding/json"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"
)

type milestoneEventDay struct {
	Steps   int64  `json:"steps"`
	Minutes string `json:"minutes"`
}

type milestoneEvent struct {
	ID    string `json:"id"`
	start time.Time
	Facts milestoneFacts `json:"facts"`
}

// All event progress updates and the entitlements they earn share the parent
// gameplay transaction. The caller holds the account lock.
const storeMilestoneEventFacts = `
	bumped AS (
		INSERT INTO milestone_event_state(owner_id,event_id,progress)
		SELECT $1,v.event_id,v.facts FROM updated v
		ON CONFLICT (owner_id,event_id) DO UPDATE SET progress=excluded.progress
		RETURNING event_id,progress AS facts
	)
	INSERT INTO milestone_entitlements(owner_id,milestone_id,policy_version,earned_at,definition)
	SELECT $1,q->>'milestoneId',p.version,$2,q
	FROM bumped v JOIN milestone_events e ON e.event_id=v.event_id
	CROSS JOIN milestone_policies p
	CROSS JOIN LATERAL jsonb_array_elements(e.definition->'quests') q
	WHERE p.active AND p.effective_at<=$2 AND ` + milestoneThresholdSQL + ` ON CONFLICT DO NOTHING`

func observeMilestoneActivityEvents(ctx context.Context, tx pgx.Tx, owner string, at time.Time,
	zone *time.Location, days []syncDay, grew bool) error {
	rows, err := tx.Query(ctx, `SELECT e.event_id,e.starts_at,COALESCE(s.progress,'{}'::jsonb)
		FROM milestone_events e LEFT JOIN milestone_event_state s ON s.owner_id=$1 AND s.event_id=e.event_id
		WHERE e.starts_at<=$2 AND e.ends_at>$2`, owner, at)
	if err != nil {
		return err
	}
	events, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (milestoneEvent, error) {
		var e milestoneEvent
		err := r.Scan(&e.ID, &e.start, &e.Facts)
		return e, err
	})
	if err != nil || len(events) == 0 {
		return err
	}
	for _, event := range events {
		dates := make(map[string]milestoneEventDay)
		if raw := event.Facts["days"]; raw != nil {
			if err := json.Unmarshal(raw, &dates); err != nil || dates == nil {
				return milestonesUnavailable
			}
		}
		start := calendarDate(event.start, zone)
		for _, day := range days {
			if day.date.Before(start) {
				continue
			}
			key := day.date.Format(time.DateOnly)
			d := dates[key]
			if _, err := milestoneAddDay(&d.Steps, &d.Minutes, day.NewlyEligible, syncMilestoneMinutes(day)); err != nil {
				return err
			}
			dates[key] = d
		}
		var active int64
		for _, d := range dates {
			minutes, err := milestoneFraction(d.Minutes)
			if err != nil {
				return err
			}
			if d.Steps >= 1000 || minutes.Cmp(big.NewRat(10, 1)) >= 0 {
				active++
			}
		}
		event.Facts.set("days", dates)
		event.Facts.set("activity_days", active)
		if grew {
			event.Facts.set("growth", 1)
		}
	}
	_, err = tx.Exec(ctx, `WITH updated AS (
		SELECT d.id AS event_id,d.facts FROM jsonb_to_recordset($3::jsonb) d(id text,facts jsonb)
	),`+storeMilestoneEventFacts, owner, at, events)
	return err
}

func observeMilestoneVisitors(ctx context.Context, tx pgx.Tx, owner string, at time.Time, visits int64, events bool) error {
	if err := refreshMilestoneEntitlements(ctx, tx, owner, at); err != nil || !events {
		return err
	}
	_, err := tx.Exec(ctx, `WITH updated AS (
		SELECT e.event_id,COALESCE(s.progress,'{}'::jsonb)||jsonb_build_object('butterflies',COALESCE((s.progress->>'butterflies')::bigint,0)+$3::bigint) AS facts
		FROM milestone_events e
		LEFT JOIN milestone_event_state s ON s.owner_id=$1 AND s.event_id=e.event_id
		WHERE e.starts_at<=$2 AND e.ends_at>$2
	),`+storeMilestoneEventFacts, owner, at, visits)
	return err
}
