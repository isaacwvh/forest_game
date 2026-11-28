package server

import (
	"context"
	"encoding/json"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const stepGrantFamily = "alignment_of_worlds"

var stepGrantTiers = [...]struct{ steps, water int64 }{
	{2000, 3_000_000}, {4000, 4_000_000}, {6000, 5_000_000},
}

type stepGrant struct {
	date               time.Time
	tier, water, steps int64
}

func readStepGrantSources(items []gardenItemFact) []gardenItemFact {
	var sources []gardenItemFact
	for _, item := range items {
		if item.stepGrant {
			sources = append(sources, item)
		}
	}
	return sources
}

// The account lock serializes uploads and item placement changes for this owner.
func planStepGrants(ctx context.Context, tx pgx.Tx, g gardenRecord, days []syncDay) ([]stepGrant, error) {
	var pending []stepGrant
	for _, day := range days {
		if day.NewlyEligible <= 0 {
			continue
		}
		var steps int64
		var granted []int64
		err := tx.QueryRow(ctx, `WITH advanced AS (
			INSERT INTO item_step_state(owner_id,game_date,family,steps)
			VALUES($1,$2,$3,least(6000,$4::bigint))
			ON CONFLICT(owner_id,game_date,family) DO UPDATE
			SET steps=least(6000,least(6000,item_step_state.steps)+excluded.steps)
			RETURNING steps
		) SELECT steps,ARRAY(SELECT tier FROM item_step_grants
			WHERE owner_id=$1 AND game_date=$2 AND family=$3) FROM advanced`,
			g.owner, day.date, stepGrantFamily, day.NewlyEligible).Scan(&steps, &granted)
		if err != nil {
			return nil, err
		}
		for _, tier := range stepGrantTiers {
			if steps >= tier.steps && !slices.Contains(granted, tier.steps) {
				pending = append(pending, stepGrant{date: day.date, tier: tier.steps, water: tier.water, steps: steps})
			}
		}
	}
	return pending, nil
}

type flatWaterAward struct {
	PlantID   uuid.UUID `json:"plantId"`
	Before    int64     `json:"beforeGrowth,string"`
	After     int64     `json:"afterGrowth,string"`
	Awarded   int64     `json:"awardedMicroUnits,string"`
	Requested int64     `json:"requestedMicroUnits,string"`
}

func (g *growthResult) applyFlatWater(plant *activityPlant, water int64, at time.Time) (flatWaterAward, error) {
	before := plant.growth
	adult := plant.thresholds["adult"]
	if before > adult || adult > plant.maximum {
		return flatWaterAward{}, invalidGrowth
	}
	awarded := min(water, adult-before)
	plant.growth += awarded
	plant.changed = plant.changed || awarded > 0
	g.seedling = g.seedling || before < plant.thresholds["seedling"] && plant.growth >= plant.thresholds["seedling"]
	if before < adult && plant.growth == adult && plant.maturedAt == nil {
		plant.maturedAt = &at
		plant.fraction = map[string]json.RawMessage{}
		g.matured++
	}
	return flatWaterAward{plant.id, before, plant.growth, awarded, water}, nil
}

func (s *Server) settleStepGrants(ctx context.Context, tx pgx.Tx, g gardenRecord, growth *growthResult,
	pending []stepGrant, sources, items []gardenItemFact, at time.Time, runtime *visitorRuntime, config gardenStrategy, expedition *uuid.UUID) error {
	provenanceSources := make([]map[string]any, 0, len(sources))
	for _, source := range sources {
		provenanceSources = append(provenanceSources, map[string]any{
			"ownedItemId": source.id, "profileId": source.profile.ID, "profileVersion": source.profile.Version,
		})
	}
	facts := make([]gardenPlantFact, 0, len(growth.plants))
	for _, grant := range pending {
		var stages map[uuid.UUID]string
		if expedition != nil {
			stages = expeditionPlantStages(growth.plants)
		}
		awards := make([]flatWaterAward, 0, len(growth.plants))
		updates := make([]activityPlant, 0, len(growth.plants))
		facts = facts[:0]
		for i := range growth.plants {
			plant := &growth.plants[i]
			award, err := growth.applyFlatWater(plant, grant.water, at)
			if err != nil {
				return err
			}
			awards = append(awards, award)
			if award.Awarded > 0 {
				updates = append(updates, *plant)
			}
			facts = append(facts, plant.gardenFact(plant.growth))
		}
		provenance := map[string]any{"version": 1, "sources": provenanceSources, "steps": grant.steps, "awards": awards}
		if _, err := tx.Exec(ctx, `INSERT INTO item_step_grants(owner_id,game_date,family,tier,boundary,provenance)
			VALUES($1,$2,$3,$4,$5,$6::jsonb)`, g.owner, grant.date, stepGrantFamily, grant.tier, at, provenance); err != nil {
			return err
		}
		if err := persistGrowthPlants(ctx, tx, g.owner, updates, at); err != nil {
			return err
		}
		if err := observeExpeditionGarden(ctx, tx, expedition, g.id, at, stages); err != nil {
			return err
		}
		if len(growth.plants) > 0 {
			if err := discoverActivityStages(ctx, tx, g, at, false); err != nil {
				return err
			}
		}
		view, err := evaluateGarden(config, gardenFacts{plants: facts, items: items})
		if err != nil {
			return err
		}
		if err := s.replaceGardenContext(ctx, tx, runtime, config, view); err != nil {
			return err
		}
	}
	return nil
}

func recentStepWater(ctx context.Context, tx pgx.Tx, g gardenRecord) ([]json.RawMessage, error) {
	if !g.stepGrantHistory {
		return []json.RawMessage{}, nil
	}
	// Aggregate only the displayed tiers in PostgreSQL. Provenance stays in the database.
	rows, err := tx.Query(ctx, `SELECT json_build_object('gameDate',game_date::text,'tier',tier,
		'water',trim_scale(COALESCE((SELECT sum((a->>'awardedMicroUnits')::numeric)
			FROM jsonb_array_elements(provenance->'awards') a),0)/1000000)::text,
		'plantCount',jsonb_array_length(provenance->'awards'))
		FROM (SELECT game_date,tier,provenance FROM item_step_grants
			WHERE owner_id=$1 ORDER BY game_date DESC,tier DESC LIMIT 9) recent
		ORDER BY game_date DESC,tier DESC`, g.owner)
	if err != nil {
		return nil, err
	}
	return pgx.AppendRows([]json.RawMessage{}, rows, pgx.RowTo[json.RawMessage])
}
