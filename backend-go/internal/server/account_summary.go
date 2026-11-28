package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func offlineCapacity(level int64) int64 {
	return 600 + 75*min(level-1, 4) + 60*min(max(level-5, 0), 15)
}

type plantTier struct{ level, limit int64 }

var plantTiers = [...]plantTier{{1, 50}, {5, 60}, {10, 75}, {15, 90}, {20, 100}}

func plantLimitForLevel(level int64) (int64, *plantTier) {
	for i, tier := range plantTiers[1:] {
		if level < tier.level {
			return plantTiers[i].limit, &tier
		}
	}
	return plantTiers[len(plantTiers)-1].limit, nil
}

func (s *Server) accountSummary(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	f, err := readEconomy(ctx, tx, p.ID)
	if err != nil {
		return nil, err
	}
	progress := progressionFor(f.steps, f.matured, f.version, f.lastSync)
	var now time.Time
	var version int64
	var levelPolicy, empty bool
	var pinnedCapacity *int64
	var notice json.RawMessage
	err = tx.QueryRow(ctx, `WITH boundary AS (SELECT clock_timestamp() AS at)
SELECT at, g.state_version,
	EXISTS (SELECT 1 FROM level_benefits_policy WHERE version='level-benefits-v1' AND effective_at<=at),
	NOT EXISTS (SELECT 1 FROM garden_placements WHERE garden_id=g.id)
	  AND NOT EXISTS (SELECT 1 FROM item_placements WHERE garden_id=g.id),
	(SELECT (c.snapshot->>'capacity')::bigint
	 FROM garden_visitor_state v JOIN visitor_contexts c ON c.id=v.context_id WHERE v.garden_id=g.id
	   AND c.effective_at>=g.updated_at AND (c.snapshot #>> '{levelBenefits,level}')::bigint=$2
	   AND COALESCE((c.snapshot->>'dailySkillExpiresAt')::timestamptz, 'infinity')>at
	   AND NOT EXISTS (SELECT 1 FROM visitor_rules WHERE effective_at>c.effective_at AND effective_at<=at)),
	(SELECT payload FROM level_up_notices WHERE owner_id=$1 AND consumed_at IS NULL ORDER BY to_level LIMIT 1)
FROM gardens g,boundary WHERE g.owner_id=$1`, p.ID, progress.Level).Scan(&now, &version, &levelPolicy, &empty, &pinnedCapacity, &notice)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{503, "garden_unavailable", "Account garden is unavailable"}
	}
	if err != nil {
		return nil, err
	}
	var benefits map[string]any
	if levelPolicy {
		limit, next := plantLimitForLevel(progress.Level)
		base := offlineCapacity(progress.Level)
		effective := base
		if pinnedCapacity != nil {
			effective = *pinnedCapacity
		} else if !empty {
			garden, err := readGardenRecord(ctx, tx, p.ID)
			if err != nil {
				return nil, err
			}
			layout, err := loadGardenCopies(ctx, tx, garden, gardenRequest{})
			if err != nil {
				return nil, err
			}
			facts := layout.facts(layout.initial)
			config, err := readGardenStrategy(ctx, tx, p.ID, now)
			if err != nil {
				return nil, err
			}
			view, err := s.evaluateGarden(ctx, tx, config, facts)
			if err != nil {
				return nil, err
			}
			effective = view.capacity
		}
		benefits = map[string]any{"policyVersion": "level-benefits-v1", "progressionVersion": progress.Version,
			"gardenStateVersion": version, "level": progress.Level, "baseOfflineCapacity": base,
			"effectiveOfflineCapacity": effective, "maximumOfflineCapacity": 3 * base, "plantLimit": limit,
			"plantedLimit": limit, "nextBaseIncrease": offlineCapacity(progress.Level+1) - base,
			"nextPlantLevel": nil, "nextPlantLimit": nil}
		if next != nil {
			benefits["nextPlantLevel"], benefits["nextPlantLimit"] = next.level, next.limit
		}
	}
	return map[string]any{"serverTime": now.UTC(), "profile": p, "progression": progress, "wallet": f.wallet,
		"benefits": benefits, "levelUpNotice": notice}, nil
}

func (s *Server) presentLevel(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	notice, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return nil, invalid
	}
	fields, err := readBody(r, "requestId", "installationId")
	if err != nil {
		return nil, err
	}
	key, err := requestID(fields)
	if err != nil {
		return nil, err
	}
	raw, err := stringField(fields, "installationId")
	if err != nil {
		return nil, err
	}
	installation, err := uuid.Parse(raw)
	if err != nil {
		return nil, invalid
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	var payload json.RawMessage
	var consumed *time.Time
	var priorKey, priorInstallation *string
	var level int64
	err = tx.QueryRow(ctx, `SELECT payload,consumed_at,claim_id::text,installation_id::text,to_level
		FROM level_up_notices WHERE id=$1 AND owner_id=$2`, notice, p.ID).
		Scan(&payload, &consumed, &priorKey, &priorInstallation, &level)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{404, "level_notice_not_found", "Level-up notice is unavailable"}
	}
	if err != nil {
		return nil, err
	}
	if consumed != nil {
		present := priorKey != nil && priorInstallation != nil && *priorKey == key.String() && *priorInstallation == installation.String()
		return map[string]any{"notice": payload, "mayPresent": present}, nil
	}
	var reused bool
	var next string
	err = tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM level_up_notices WHERE owner_id=$1 AND claim_id=$2),
		(SELECT id::text FROM level_up_notices WHERE owner_id=$1 AND consumed_at IS NULL ORDER BY to_level LIMIT 1)`, p.ID, key).Scan(&reused, &next)
	if err != nil {
		return nil, err
	}
	if reused {
		return nil, &apiError{409, "idempotency_conflict", "Presentation request was already used"}
	}
	if next != notice.String() {
		return nil, &apiError{409, "stale_level_notice", "Refresh account progress before presenting"}
	}
	var batch pgx.Batch
	batch.Queue("UPDATE level_up_notices SET consumed_at=clock_timestamp(),claim_id=$2,installation_id=$3 WHERE id=$1", notice, key, installation)
	batch.Queue("UPDATE account_level_state SET presented_level=GREATEST(presented_level,$2) WHERE owner_id=$1", p.ID, level)
	if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
		return nil, err
	}
	return map[string]any{"notice": payload, "mayPresent": true}, nil
}
