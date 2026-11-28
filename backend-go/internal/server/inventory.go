package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func parsePage(r *http.Request, defaultLimit, max int) (int, *uuid.UUID, error) {
	values := r.URL.Query()
	limit := defaultLimit
	if raw := values.Get("limit"); values.Has("limit") {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 || n > max {
			return 0, nil, invalid
		}
		limit = n
	}
	if raw := values.Get("after"); values.Has("after") {
		after, err := uuid.Parse(raw)
		if err != nil {
			return 0, nil, invalid
		}
		return limit, &after, nil
	}
	return limit, nil, nil
}

func gardenShare(ctx context.Context, tx pgx.Tx, owner string) error {
	var garden string
	err := tx.QueryRow(ctx, "SELECT id::text FROM gardens WHERE owner_id=$1 FOR SHARE", owner).Scan(&garden)
	if errors.Is(err, pgx.ErrNoRows) {
		return &apiError{503, "garden_unavailable", "Account garden is unavailable"}
	}
	return err
}

func (s *Server) inventory(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	limit, after, err := parsePage(r, 30, 100)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, false)
	if err != nil {
		return nil, err
	}
	if err := gardenShare(ctx, tx, p.ID); err != nil {
		return nil, err
	}
	return s.inventoryFor(ctx, tx, p.ID, limit, after)
}

func (s *Server) inventoryFor(ctx context.Context, tx pgx.Tx, owner string, limit int, after *uuid.UUID) (any, error) {
	rows, err := tx.Query(ctx, plantQuery(`p.owner_id=$1 AND ($2::uuid IS NULL OR p.id>$2)
		AND NOT EXISTS (SELECT 1 FROM garden_placements l WHERE l.plant_id=p.id) ORDER BY p.id LIMIT $3`), owner, after, limit+1)
	if err != nil {
		return nil, err
	}
	plants, err := pgx.CollectRows(rows, pgx.RowTo[json.RawMessage])
	if err != nil {
		return nil, err
	}
	if plants == nil {
		plants = []json.RawMessage{}
	}
	var cursor *string
	if len(plants) > limit {
		plants = plants[:limit]
		var last struct {
			ID string `json:"plantId"`
		}
		if err := json.Unmarshal(plants[limit-1], &last); err != nil {
			return nil, err
		}
		cursor = &last.ID
	}
	capacity, err := s.plantCapacity(ctx, tx, owner)
	if err != nil {
		return nil, err
	}
	return map[string]any{"plants": plants, "capacity": capacity, "nextCursor": cursor}, nil
}

func (s *Server) plant(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	plant, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return nil, invalid
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, false)
	if err != nil {
		return nil, err
	}
	var value json.RawMessage
	err = tx.QueryRow(ctx, plantQuery("p.owner_id=$1 AND p.id=$2"), p.ID, plant).Scan(&value)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{404, "plant_not_found", "Plant not found"}
	}
	return value, err
}

func (s *Server) capacity(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	p, err := lookupProfile(r.Context(), tx, id, true)
	if err != nil {
		return nil, err
	}
	return s.plantCapacity(r.Context(), tx, p.ID)
}

func (s *Server) plantCapacity(ctx context.Context, tx pgx.Tx, owner string) (map[string]int64, error) {
	var owned, planted, packs, steps int64
	var raised bool
	err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM owned_plants WHERE owner_id=$1),
		(SELECT count(*) FROM garden_placements WHERE owner_id=$1),
		(SELECT count(*) FROM owned_packs p WHERE p.owner_id=$1 AND NOT EXISTS
			(SELECT 1 FROM pack_openings o WHERE o.pack_id=p.id)),
		COALESCE((SELECT activity_steps FROM player_progress WHERE owner_id=$1),0),
		EXISTS (SELECT 1 FROM level_benefits_policy WHERE version='level-benefits-v1')`, owner).
		Scan(&owned, &planted, &packs, &steps, &raised)
	if err != nil {
		return nil, err
	}
	const defaultLimit = 50
	limit := int64(defaultLimit)
	if raised {
		level := levelForSteps(steps)
		for _, tier := range []struct{ level, limit int64 }{{5, 60}, {10, 75}, {15, 90}, {20, 100}} {
			if level >= tier.level {
				limit = tier.limit
			}
		}
	}
	return map[string]int64{"ownedPlants": owned, "plantedPlants": planted, "storedPlants": owned - planted,
		"plantLimit": limit, "plantedLimit": limit, "unopenedPacks": packs, "packLimit": 50}, nil
}

// condition is assembled only from static SQL at call sites. User input is bound as parameters.
func plantQuery(condition string) string {
	return plantQueryWithSkillProjection(condition, plantSkillProjection)
}

const plantSkillProjection = "COALESCE(b.rules->'gardenEffects','[]')"

func plantQueryWithSkillProjection(condition, skillProjection string) string {
	return `WITH requested AS (SELECT p.* FROM owned_plants p WHERE ` + condition + `)
SELECT jsonb_build_object('plantId',p.id,'speciesId',p.species_id,'variantId',p.variant_id,
	'pinnedProfiles',jsonb_build_object(
		'growth',jsonb_build_object('id',p.growth_profile_id,'version',p.growth_profile_version),
		'behaviour',jsonb_build_object('id',p.behaviour_profile_id,'version',p.behaviour_profile_version),
		'attraction',jsonb_build_object('id',p.attraction_profile_id,'version',p.attraction_profile_version)),
	'clearanceRadius',p.clearance_radius,'growthMicroUnits',p.growth_micro_units::text,
	'growthStage',stage.current,'growthProgress',jsonb_build_object(
		'stageStartMicroUnits',g.thresholds->>stage.current,
		'nextStageMicroUnits',g.thresholds->>CASE stage.current
			WHEN 'sprout' THEN 'seedling' WHEN 'seedling' THEN 'young' WHEN 'young' THEN 'adult' END,
		'maximumGrowthMicroUnits',g.maximum_growth_micro_units::text),
	'baseAttractionMicroUnits',a.stage_attraction->>stage.current,
	'contributesAttraction',l.plant_id IS NOT NULL,'gardenSkills',` + skillProjection + `,
	'metricMultipliers',COALESCE(b.rules->'metricMultipliers','{}'),'gameplayTags',a.gameplay_tags,
	'modelKey',asset.model_key,'thumbnailKey',asset.thumbnail_key,'placement',
		CASE WHEN l.plant_id IS NOT NULL THEN jsonb_build_object(
			'gardenId',l.garden_id,'x',l.x,'y',l.y,'rotationDegrees',l.rotation_degrees) END)
FROM requested p
JOIN growth_profiles g ON (g.id,g.version)=(p.growth_profile_id,p.growth_profile_version)
JOIN growth_rule_profiles b ON (b.id,b.version)=(p.behaviour_profile_id,p.behaviour_profile_version)
JOIN attraction_profiles a ON (a.id,a.version)=(p.attraction_profile_id,p.attraction_profile_version)
CROSS JOIN LATERAL (SELECT CASE
	WHEN p.growth_micro_units >= (g.thresholds->>'adult')::bigint THEN 'adult'
	WHEN p.growth_micro_units >= (g.thresholds->>'young')::bigint THEN 'young'
	WHEN p.growth_micro_units >= (g.thresholds->>'seedling')::bigint THEN 'seedling'
	ELSE 'sprout' END AS current) stage
JOIN plant_stages asset ON (asset.species_id,asset.variant_id,asset.stage)=(p.species_id,p.variant_id,stage.current)
LEFT JOIN garden_placements l ON l.plant_id=p.id
ORDER BY p.id`
}
