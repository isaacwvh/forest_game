package server

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const dailyWaterFamily = "morning_rain"
const dailyWaterAmount = 2_500_000

// The caller holds the owner and garden locks. Layout changes have to advance
// the checkpoint before changing membership, including when no harp is placed.
const placedDailyWater = `EXISTS (
	SELECT 1 FROM item_placements l JOIN item_identities i ON i.id=l.item_id
	JOIN item_skill_bindings b ON (b.item_id,b.item_version)=(i.item_id,i.item_version)
	JOIN item_skill_profiles s ON (s.id,s.version)=(b.profile_id,b.profile_version)
	WHERE l.garden_id=g.id AND i.owner_id=g.owner_id AND s.rules ? 'dailyGrant'
)`

func (s *Server) settleGardenDaily(ctx context.Context, tx pgx.Tx, g *gardenRecord, at time.Time, timezone string) error {
	if g.dailySource {
		var previous time.Time
		err := tx.QueryRow(ctx, `SELECT greatest(min(published_at),
			(SELECT settled_at FROM daily_item_state WHERE garden_id=$1))
			FROM shop_releases WHERE published_at<=$2 HAVING count(*)>0`, g.id, at).Scan(&previous)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		zone, err := time.LoadLocation(timezone)
		if err != nil {
			return gardenPresentationUnavailable
		}
		from, through := calendarDate(previous, zone).AddDate(0, 0, 1), calendarDate(at, zone)
		if !from.After(through) {
			if err := s.catchUpDailyWater(ctx, tx, g, from, through, at, zone); err != nil {
				return err
			}
		}
	}

	_, err := tx.Exec(ctx, `INSERT INTO daily_item_state (garden_id,settled_at)
		SELECT $1,$2 WHERE EXISTS(SELECT 1 FROM shop_releases WHERE published_at<=$2)
		ON CONFLICT(garden_id) DO UPDATE SET settled_at=excluded.settled_at
		WHERE daily_item_state.settled_at<excluded.settled_at`, g.id, at)
	return err
}

func (s *Server) catchUpDailyWater(ctx context.Context, tx pgx.Tx, g *gardenRecord,
	from, through, at time.Time, zone *time.Location) error {
	plants, err := readActivityPlants(ctx, tx, *g)
	if err != nil {
		return err
	}
	items, err := readPlacedSkillItems(ctx, tx, *g)
	if err != nil {
		return err
	}
	sources := make([]map[string]any, 0)
	for _, item := range items {
		if item.dailyGrant {
			sources = append(sources, map[string]any{"ownedItemId": item.id, "itemId": item.definition.ID,
				"definitionVersion": item.definition.Version, "profileId": item.profile.ID, "profileVersion": item.profile.Version})
		}
	}
	facts := gardenFacts{plants: make([]gardenPlantFact, len(plants)), items: items}
	for i, plant := range plants {
		facts.plants[i] = plant.gardenFact(plant.growth)
	}
	if err := s.loadGardenSkills(ctx, tx, facts); err != nil {
		return err
	}
	for i := range plants {
		plants[i].skill = facts.plants[i].skill
	}
	for day := from; !day.After(through); day = day.AddDate(0, 0, 1) {
		growing := make([]uuid.UUID, 0, len(plants))
		for i, p := range plants {
			p.changed = false
			plants[i] = p
			if p.growth < p.thresholds["adult"] {
				growing = append(growing, p.id)
			}
		}
		if len(growing) == 0 {
			break
		}
		boundary := dailyWaterBoundary(day, zone)
		if boundary.After(at) || len(sources) == 0 {
			return gardenPresentationUnavailable
		}
		expedition, err := expeditionAt(ctx, tx, g.owner, boundary)
		if err != nil {
			return err
		}
		var existing []uuid.UUID
		if err := tx.QueryRow(ctx, `SELECT ARRAY(SELECT id FROM unnest($4::uuid[]) p(id)
			JOIN daily_item_grants g ON g.plant_id=p.id
			WHERE g.owner_id=$1 AND g.game_date=$2 AND g.family=$3)`, g.owner, day, dailyWaterFamily, growing).
			Scan(&existing); err != nil {
			return err
		}
		if len(existing) == len(growing) {
			continue
		}
		var stages map[uuid.UUID]string
		if expedition != nil {
			if err := observeExpeditionGarden(ctx, tx, expedition, g.id, boundary, nil); err != nil {
				return err
			}
			stages = expeditionPlantStages(plants)
		}
		skip := make(map[uuid.UUID]bool, len(existing))
		for _, id := range existing {
			skip[id] = true
		}
		runtime, err := s.settleVisitorState(ctx, tx, g.id, g.owner, boundary, false)
		if err != nil {
			return err
		}
		if runtime.at.After(boundary) {
			return visitorContextUnavailable
		}
		grants := make([]map[string]any, 0, len(growing)-len(existing))
		var growth growthResult
		for i := range plants {
			plant := &plants[i]
			if plant.growth >= plant.thresholds["adult"] || skip[plant.id] {
				continue
			}
			award, err := growth.applyFlatWater(plant, dailyWaterAmount, boundary)
			if err != nil {
				return err
			}
			if plant.growth == plant.thresholds["adult"] {
				plant.fraction = map[string]json.RawMessage{}
			}
			provenance := map[string]any{"version": "daily-item-water-v1", "requestedMicroUnits": numberString(dailyWaterAmount),
				"beforeGrowth": numberString(award.Before), "afterGrowth": numberString(award.After), "gameTimezone": zone.String(),
				"sources": sources, "growthProfileId": plant.profiles.Growth.ID, "growthProfileVersion": plant.profiles.Growth.Version}
			grants = append(grants, map[string]any{"plant_id": plant.id, "awarded": award.Awarded, "provenance": provenance})
			facts.plants[i] = plant.gardenFact(plant.growth)
		}
		if err := persistDailyWater(ctx, tx, g, day, boundary, plants, growth, grants); err != nil {
			return err
		}
		if err := observeExpeditionGarden(ctx, tx, expedition, g.id, boundary, stages); err != nil {
			return err
		}
		config, err := readGardenStrategy(ctx, tx, g.owner, boundary)
		if err != nil {
			return err
		}
		view, err := evaluateGarden(config, facts)
		if err != nil {
			return err
		}
		if err := s.replaceGardenContext(ctx, tx, runtime, config, view); err != nil {
			return err
		}
	}
	return nil
}

// Match the account-local midnight used by the reference. At a midnight
// transition the old offset selects the first occurrence, or crosses the gap.
func dailyWaterBoundary(day time.Time, zone *time.Location) time.Time {
	midnight := activityDayStart(day, zone)
	_, priorOffset := midnight.Add(-24 * time.Hour).In(zone).Zone()
	prior := day.Add(-time.Duration(priorOffset) * time.Second).In(zone)
	isMidnight := func(t time.Time) bool {
		return calendarDate(t, zone).Equal(day) && t.Hour() == 0 && t.Minute() == 0 && t.Second() == 0
	}
	if isMidnight(prior) || !isMidnight(midnight) {
		return prior.UTC()
	}
	return midnight.UTC()
}

func persistDailyWater(ctx context.Context, tx pgx.Tx, g *gardenRecord, day, at time.Time, plants []activityPlant,
	growth growthResult, grants []map[string]any) error {
	if g.state == math.MaxInt64 {
		return activityCounterExhausted
	}
	_, err := tx.Exec(ctx, `INSERT INTO daily_item_grants(owner_id,plant_id,game_date,family,awarded,boundary,provenance)
		SELECT $1,plant_id,$2,$3,awarded,$4,provenance
		FROM jsonb_to_recordset($5::jsonb) AS v(plant_id uuid,awarded bigint,provenance jsonb)`,
		g.owner, day, dailyWaterFamily, at, grants)
	if err != nil {
		return err
	}
	if growth.matured > 0 || growth.seedling {
		var seedling *time.Time
		if growth.seedling {
			seedling = &at
		}
		tag, err := tx.Exec(ctx, `UPDATE player_progress SET first_maturity_count=first_maturity_count+$2,
			first_seedling_at=COALESCE(first_seedling_at,$3) WHERE owner_id=$1
			AND first_maturity_count<=9223372036854775807-$2`, g.owner, growth.matured, seedling)
		if err != nil {
			return err
		}
		if tag.RowsAffected() != 1 {
			return activityCounterExhausted
		}
	}
	if err := persistGrowthPlants(ctx, tx, g.owner, plants, at); err != nil {
		return err
	}
	g.state++
	g.dailyGrantHistory = true
	if _, err := tx.Exec(ctx, "UPDATE gardens SET state_version=$2,updated_at=$3 WHERE id=$1", g.id, g.state, at); err != nil {
		return err
	}
	return discoverActivityStages(ctx, tx, *g, at, growth.seedling || growth.matured > 0)
}

func recentDailyWater(ctx context.Context, tx pgx.Tx, g gardenRecord, gameDate string) ([]json.RawMessage, error) {
	if !g.dailyGrantHistory {
		return []json.RawMessage{}, nil
	}
	rows, err := tx.Query(ctx, `SELECT json_build_object('gameDate',game_date::text,
		'water',trim_scale(sum(awarded)/1000000)::text,'plantCount',count(*))
		FROM daily_item_grants WHERE owner_id=$1 AND game_date>=$2::text::date-30
		GROUP BY game_date ORDER BY game_date DESC LIMIT 7`, g.owner, gameDate)
	if err != nil {
		return nil, err
	}
	return pgx.AppendRows([]json.RawMessage{}, rows, pgx.RowTo[json.RawMessage])
}
