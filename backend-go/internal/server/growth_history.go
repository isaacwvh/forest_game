package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Match the activity recovery whitelist, including explicit JSON null values.
const activityHistoryCompletion = `CASE WHEN jsonb_typeof(r.response)='object' THEN
	jsonb_build_object('version',1,'outcome',
		(SELECT COALESCE(jsonb_object_agg(key,value),'{}'::jsonb) FROM jsonb_each(r.response)
		 WHERE key IN ('requestId','eventId','visits','tokens','acceptedAt','recapId','acknowledgedAt',
			'milestoneId','milestoneEventId','tokensEarned','gemsEarned','packs','policyVersion','supersededMilestoneIds','claimedAt'))
		|| CASE WHEN r.response ? 'garden' THEN jsonb_build_object('gardenId',r.response#>'{garden,gardenId}') ELSE '{}'::jsonb END)
	END`

const recoverableActivityHistory = `((` + requestHasHistoryProof + `) OR
	(r.completion IS NULL AND octet_length((` + activityHistoryCompletion + `)::text)<=8192))`

const openGrowthRecap = `EXISTS (SELECT 1 FROM reward_recaps a WHERE a.event_id=e.id AND a.acknowledged_at IS NULL)`

type growthHistorySource struct {
	Plant   uuid.UUID       `json:"plant_id"`
	Credit  uuid.UUID       `json:"credit_id"`
	Day     string          `json:"day"`
	Rule    string          `json:"rule"`
	Awarded int64           `json:"awarded"`
	Bonus   int64           `json:"bonus"`
	Key     string          `json:"profile_key"`
	Profile json.RawMessage `json:"profile"`
}

type growthHistoryCandidate struct {
	growthHistorySource
	Backfill *uuid.UUID `json:"backfill"`
}

func compactGrowthHistory(ctx context.Context, tx pgx.Tx, owner string, now time.Time) error {
	cutoff := now.Add(-30 * 24 * time.Hour)
	rows, err := tx.Query(ctx, `WITH candidates AS MATERIALIZED (
		SELECT p.plant_id,c.id,c.game_date,c.request_id,c.rule_version,r.completion IS NULL AS backfill,
			p.after_growth-p.before_growth AS awarded,COALESCE(g.payload,'{}'::jsonb)||p.context AS facts
		FROM activity_credits c JOIN plant_growth_credits p ON p.activity_credit_id=c.id
		JOIN api_requests r ON (r.user_id,r.request_id)=(c.owner_id,c.request_id) AND r.operation='activity_sync'
		LEFT JOIN growth_provenance g ON g.id=p.provenance_id
		WHERE c.owner_id=$1 AND c.accepted_at<=$2 AND `+recoverableActivityHistory+`
		ORDER BY c.accepted_at,p.plant_id,c.id LIMIT $3
	), projected AS (
		SELECT *,jsonb_build_object('profiles',facts->'profiles','skills',COALESCE(facts->'skills','{}')) AS profile
		FROM candidates
	) SELECT profile, bool_and((facts ? 'profiles' AND (facts->>'awardedMicroUnits')::bigint=awarded) IS TRUE),
		jsonb_agg(jsonb_build_object('plant_id',plant_id,'credit_id',id,'day',game_date,
			'rule',rule_version,'awarded',awarded,'bonus',COALESCE((facts->>'skillBonusGrowthMicroUnits')::bigint,0),
			'backfill',CASE WHEN backfill THEN request_id END))
	FROM projected GROUP BY profile`, owner, cutoff, workerSettings(ctx).BatchLimit)
	if err != nil {
		return err
	}
	var sources []growthHistorySource
	var backfill []uuid.UUID
	for rows.Next() {
		var profile json.RawMessage
		var reconciled bool
		var candidates []growthHistoryCandidate
		err := rows.Scan(&profile, &reconciled, &candidates)
		if err != nil {
			rows.Close()
			return err
		}
		if !reconciled {
			rows.Close()
			return errHistoryReconciliation
		}
		key, err := growthHistoryProfileKey(profile)
		if err != nil {
			rows.Close()
			return err
		}
		for _, candidate := range candidates {
			row := candidate.growthHistorySource
			row.Key, row.Profile = key, profile
			if candidate.Backfill != nil {
				backfill = append(backfill, *candidate.Backfill)
			}
			sources = append(sources, row)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}

	report := workerReportFrom(ctx)
	var batch pgx.Batch
	if len(backfill) > 0 {
		batch.Queue(`UPDATE api_requests r SET completion=`+activityHistoryCompletion+`
			WHERE r.user_id=$1 AND r.request_id=ANY($2::uuid[]) AND r.completion IS NULL`, owner, backfill).
			Exec(func(tag pgconn.CommandTag) error {
				if report != nil {
					report.Responses.Backfilled += tag.RowsAffected()
				}
				return nil
			})
	}
	if len(sources) > 0 {
		// Only successfully removed source rows can contribute to the rollup.
		batch.Queue(`WITH incoming AS MATERIALIZED (
			SELECT * FROM jsonb_to_recordset($1::jsonb)
			 AS v(plant_id uuid,credit_id uuid,day date,rule text,awarded bigint,bonus bigint,profile_key text,profile jsonb)
		), rolled AS (
			DELETE FROM plant_growth_credits p USING incoming i
			WHERE (p.plant_id,p.activity_credit_id)=(i.plant_id,i.credit_id) RETURNING p.plant_id,p.activity_credit_id
		)
		INSERT INTO growth_day_summaries(plant_id,day,rule_version,profile_key,profiles,awarded,skill_bonus,credit_count)
		SELECT i.plant_id,i.day,i.rule,i.profile_key,i.profile,sum(i.awarded),sum(i.bonus),count(*)
		FROM incoming i JOIN rolled r ON (r.plant_id,r.activity_credit_id)=(i.plant_id,i.credit_id)
		GROUP BY i.plant_id,i.day,i.rule,i.profile_key,i.profile
		ON CONFLICT(plant_id,day,rule_version,profile_key) DO UPDATE
		SET awarded=growth_day_summaries.awarded+excluded.awarded,
			skill_bonus=growth_day_summaries.skill_bonus+excluded.skill_bonus,
			credit_count=growth_day_summaries.credit_count+excluded.credit_count`, sources).
			Exec(func(_ pgconn.CommandTag) error {
				if report != nil {
					report.GrowthCredits += int64(len(sources))
				}
				return nil
			})
	}
	batch.Queue("SET LOCAL forest.history_compaction = 'on'")
	batch.Queue(`WITH recent AS (
		SELECT id FROM reward_recaps WHERE owner_id=$1 AND acknowledged_at<=$2 AND NOT (payload ? 'compacted')
		ORDER BY acknowledged_at,id LIMIT $3
	) UPDATE reward_recaps a SET payload=jsonb_build_object('compacted',1,'eventId',a.event_id::text)
	FROM recent WHERE recent.id=a.id`, owner, now.Add(-7*24*time.Hour), workerSettings(ctx).BatchLimit).
		Exec(func(tag pgconn.CommandTag) error {
			if report != nil {
				report.Recaps += tag.RowsAffected()
			}
			return nil
		})
	batch.Queue(`WITH old AS (
		SELECT e.id FROM reward_events e WHERE owner_id=$1 AND accepted_at<=$2
			AND NOT (payload ? 'compacted') AND NOT (`+openGrowthRecap+`)
		ORDER BY accepted_at,id LIMIT $3
	) UPDATE reward_events e SET payload=jsonb_build_object('compacted',1,'kind','activity_growth',
		'creditIds',COALESCE(e.payload->'creditIds','[]'::jsonb))
	FROM old WHERE old.id=e.id`, owner, cutoff, workerSettings(ctx).BatchLimit).
		Exec(func(tag pgconn.CommandTag) error {
			if report != nil {
				report.GrowthEvents += tag.RowsAffected()
			}
			return nil
		})
	return tx.SendBatch(ctx, &batch).Close()
}

func growthHistoryProfileKey(profile json.RawMessage) (string, error) {
	var value map[string]any
	d := json.NewDecoder(bytes.NewReader(profile))
	d.UseNumber()
	if err := d.Decode(&value); err != nil {
		return "", err
	}
	data, err := canonicalJSON(value)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:]), nil
}

const unusedGrowthProvenance = `NOT EXISTS (SELECT 1 FROM plant_growth_credits p WHERE p.provenance_id=g.id)`

func retireGrowthProvenance(ctx context.Context, tx pgx.Tx) error {
	rows, err := tx.Query(ctx, `SELECT g.id FROM growth_provenance g WHERE `+unusedGrowthProvenance+`
		ORDER BY g.id LIMIT $1 FOR UPDATE SKIP LOCKED`, workerSettings(ctx).BatchLimit)
	if err != nil {
		return err
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil || len(ids) == 0 {
		return err
	}
	// Recheck with a fresh snapshot after locking. A concurrent growth writer
	// can have linked one of the rows while the candidate statement was running.
	tag, err := tx.Exec(ctx, `DELETE FROM growth_provenance g WHERE id=ANY($1::text[]) AND `+unusedGrowthProvenance, ids)
	if report := workerReportFrom(ctx); report != nil {
		report.Provenance += tag.RowsAffected()
	}
	return err
}
