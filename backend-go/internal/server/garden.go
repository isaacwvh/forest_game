package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type gardenRecord struct {
	id, owner, visibility, width, depth string
	layout, state                       int64
	dailyGrantHistory, stepGrantHistory bool
	dailySource                         bool
}

func readGardenRecord(ctx context.Context, tx pgx.Tx, owner string) (gardenRecord, error) {
	g := gardenRecord{owner: owner}
	err := tx.QueryRow(ctx, `SELECT id::text,visibility,width::text,depth::text,layout_version,state_version,
		EXISTS (SELECT 1 FROM daily_item_grants WHERE owner_id=$1), EXISTS (SELECT 1 FROM item_step_grants WHERE owner_id=$1),
		`+placedDailyWater+` FROM gardens g WHERE owner_id=$1 FOR UPDATE`, owner).
		Scan(&g.id, &g.visibility, &g.width, &g.depth, &g.layout, &g.state, &g.dailyGrantHistory, &g.stepGrantHistory, &g.dailySource)
	if errors.Is(err, pgx.ErrNoRows) {
		return g, &apiError{503, "garden_unavailable", "Account garden is unavailable"}
	}
	return g, err
}

func (s *Server) gardenNow(ctx context.Context, tx pgx.Tx) (time.Time, error) {
	if s.visitorClock != nil {
		return s.visitorClock().UTC(), nil
	}
	var at time.Time
	err := tx.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&at)
	return at.UTC(), err
}

func (s *Server) garden(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	return s.readGarden(r, tx, id, false)
}

func (s *Server) gardenSnapshot(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	return s.readGarden(r, tx, id, true)
}

func (s *Server) readGarden(r *http.Request, tx pgx.Tx, id Identity, snapshot bool) (any, error) {
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	g, err := readGardenRecord(ctx, tx, p.ID)
	if err != nil {
		return nil, err
	}
	catalog, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	if err := checkGardenExpedition(ctx, tx, at); err != nil {
		return nil, err
	}
	if err := s.settleGardenDaily(ctx, tx, &g, at, p.Timezone); err != nil {
		return nil, err
	}
	config, err := readGardenStrategy(ctx, tx, p.ID, at)
	if err != nil {
		return nil, err
	}
	proposal, err := loadGardenCopies(ctx, tx, g, gardenRequest{})
	if err != nil {
		return nil, err
	}
	facts := proposal.facts(proposal.initial)
	view, err := s.evaluateGarden(ctx, tx, config, facts)
	if err != nil {
		return nil, err
	}
	garden, _, err := presentGarden(r, tx, g, catalog, config, view, nil)
	if err != nil {
		return nil, err
	}
	if !snapshot {
		return garden, nil
	}
	inventory, err := s.inventoryFor(ctx, tx, p.ID, 30, nil)
	if err != nil {
		return nil, err
	}
	items, err := itemInventoryFor(ctx, tx, p.ID, 100, nil, r.Header)
	if err != nil {
		return nil, err
	}
	var document json.RawMessage
	if r.URL.Query().Get("catalogVersion") != catalog.Version {
		document, err = s.catalogueDocument(ctx, tx)
		if err != nil {
			return nil, err
		}
	}
	return map[string]any{"profile": p, "garden": garden, "inventory": inventory, "itemInventory": items,
		"catalogue": document, "supportsStrategyDigest": true}, nil
}

func presentGarden(r *http.Request, tx pgx.Tx, g gardenRecord, catalog catalogueState, config gardenStrategy, view gardenEvaluation, actions []gardenAction) (map[string]any, []json.RawMessage, error) {
	ctx := r.Context()
	plants := make([]json.RawMessage, 0, len(view.facts))
	updated := make([]json.RawMessage, 0, len(actions))
	if len(view.facts) > 0 || len(actions) > 0 {
		ids := make([]uuid.UUID, 0, len(actions))
		for _, a := range actions {
			ids = append(ids, a.id)
		}
		skills := make(map[uuid.UUID]json.RawMessage)
		cached := make([]uuid.UUID, 0)
		for _, fact := range view.facts {
			if len(fact.skill.presentation) > 0 {
				skills[fact.id] = fact.skill.presentation
				cached = append(cached, fact.id)
			}
		}
		rows, err := tx.Query(ctx, plantQueryWithSkillProjection(`p.owner_id=$1 AND (p.id=ANY($3::uuid[]) OR
			EXISTS(SELECT 1 FROM garden_placements l WHERE l.plant_id=p.id AND l.garden_id=$2))`,
			"CASE WHEN p.id=ANY($4::uuid[]) THEN NULL ELSE "+plantSkillProjection+" END"), g.owner, g.id, ids, cached)
		if err != nil {
			return nil, nil, err
		}
		docs, err := pgx.CollectRows(rows, pgx.RowTo[json.RawMessage])
		if err != nil {
			return nil, nil, err
		}
		byID := make(map[uuid.UUID]json.RawMessage, len(docs))
		for _, doc := range docs {
			var fields struct {
				ID     uuid.UUID `json:"plantId"`
				Placed bool      `json:"contributesAttraction"`
			}
			if err := json.Unmarshal(doc, &fields); err != nil {
				return nil, nil, err
			}
			if raw := skills[fields.ID]; raw != nil {
				var plant map[string]json.RawMessage
				if err := json.Unmarshal(doc, &plant); err != nil {
					return nil, nil, err
				}
				plant["gardenSkills"] = raw
				doc, err = json.Marshal(plant)
				if err != nil {
					return nil, nil, err
				}
			}
			byID[fields.ID] = doc
			if fields.Placed {
				plants = append(plants, doc)
			}
		}
		if len(plants) != len(view.facts) {
			return nil, nil, gardenPresentationUnavailable
		}
		for _, id := range ids {
			if byID[id] == nil {
				return nil, nil, gardenPresentationUnavailable
			}
			updated = append(updated, byID[id])
		}
	}
	items, err := readItems(ctx, tx, "o.owner_id=$1 AND p.garden_id=$2 ORDER BY o.id", g.owner, g.id)
	if err != nil {
		return nil, nil, err
	}
	for _, item := range items {
		if (item.ItemID == "astronomers-satchel" || item.ItemID == "comet-basin" || item.ItemID == "worldseed-orrery") &&
			r.Header.Get("X-Forest-Expeditions") != "1" {
			return nil, nil, &apiError{426, "expedition_update_required", "Update the app for expedition rewards"}
		}
		if item.ItemID != "wooden-bench" && r.Header.Get("X-Forest-Item-Rotations") != "1" {
			return nil, nil, itemContentUpdate
		}
	}
	stepWater, err := recentStepWater(ctx, tx, g)
	if err != nil {
		return nil, nil, err
	}
	dailyWater, err := recentDailyWater(ctx, tx, g, config.day)
	if err != nil {
		return nil, nil, err
	}
	return map[string]any{"gardenId": g.id, "visibility": g.visibility, "width": json.Number(g.width), "depth": json.Number(g.depth),
		"coordinateUnit": "garden_unit", "gardenUnitMetres": catalog.Metres, "catalogVersion": catalog.Version,
		"layoutVersion": g.layout, "stateVersion": g.state, "plants": plants, "items": items,
		"totalAttractionMicroUnits": numberString(view.attraction), "skillSummary": view.summary, "strategyContext": config.document(),
		"dailyWater": dailyWater, "stepTierWater": stepWater}, updated, nil
}

func (s *Server) discovery(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	catalog, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	var version int64
	var entries json.RawMessage
	err = tx.QueryRow(ctx, `SELECT cs.version,
		COALESCE((SELECT jsonb_agg(jsonb_build_object('speciesId',e.species_id,'variantId',e.variant_id,'stages',e.stages)
		ORDER BY e.species_id COLLATE "C",e.variant_id COLLATE "C") FROM (
			SELECT species_id,variant_id,array_agg(stage ORDER BY CASE stage
			   WHEN 'sprout' THEN 1 WHEN 'seedling' THEN 2 WHEN 'young' THEN 3 ELSE 4 END) AS stages
			FROM catalog_stage_discoveries WHERE owner_id=$1 AND ($2::bool OR stage!='sprout')
			GROUP BY species_id,variant_id
		) e),'[]') FROM catalog_discovery_state cs WHERE cs.owner_id=$1`,
		p.ID, r.Header.Get("X-Forest-Discovery") == "2").Scan(&version, &entries)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{503, "discovery_not_ready", "Catalog discovery requires a database upgrade"}
	}
	if err != nil {
		return nil, err
	}
	return map[string]any{"userId": p.ID, "catalogVersion": catalog.Version, "discoveryVersion": version, "entries": entries}, nil
}
