package server

import (
	"bytes"
	"context"
	"encoding/json"
	"maps"
	"math/big"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var (
	gardenPresentationUnavailable = &apiError{503, "garden_presentation_unavailable", "Garden presentation requires reconciliation"}
	gardenEffectsUnavailable      = &apiError{503, "garden_effects_unavailable", "This garden's effects require reconciliation"}
	invalidGeometry               = &apiError{503, "invalid_geometry_configuration", "Invalid published geometry"}
	strategyFingerprint           = regexp.MustCompile("^[a-f0-9]{64}$")
)

type gardenTransform struct {
	x, y, rotation int64
}

type gardenAction struct {
	id          uuid.UUID
	kind        string
	position    gardenTransform
	hasRotation bool
}

type gardenRequest struct {
	key                    uuid.UUID
	catalogue              string
	layout                 int64
	fingerprint, signature string
	plants, items          []gardenAction
	digest                 string
}

func readGardenRequest(r *http.Request) (gardenRequest, error) {
	var req gardenRequest
	body, err := readBody(r, "requestId", "catalogVersion", "expectedLayoutVersion", "actions", "itemActions",
		"expectedStrategyFingerprint", "expectedStrategySignature")
	if err != nil {
		return req, err
	}
	if req.key, err = requestID(body); err != nil {
		return req, err
	}
	req.catalogue, err = stringField(body, "catalogVersion")
	if err != nil || len([]rune(req.catalogue)) < 1 || len([]rune(req.catalogue)) > 100 ||
		json.Unmarshal(body["expectedLayoutVersion"], &req.layout) != nil ||
		string(body["expectedLayoutVersion"]) == "null" || req.layout < 0 {
		return req, invalid
	}
	payload := map[string]any{"catalogVersion": req.catalogue, "expectedLayoutVersion": req.layout}
	for _, entry := range []struct {
		field string
		dst   *string
		check func(string) bool
	}{
		{"expectedStrategyFingerprint", &req.fingerprint, strategyFingerprint.MatchString},
		{"expectedStrategySignature", &req.signature, func(value string) bool { return len([]rune(value)) >= 1 && len([]rune(value)) <= 32768 }},
	} {
		if len(body[entry.field]) == 0 || string(body[entry.field]) == "null" {
			continue
		}
		value, err := stringField(body, entry.field)
		if err != nil || !entry.check(value) {
			return req, invalid
		}
		*entry.dst = value
		payload[entry.field] = value
	}
	var plants, items []map[string]any
	req.plants, plants, err = readGardenActions(body["actions"], false)
	if err != nil {
		return req, err
	}
	req.items, items, err = readGardenActions(body["itemActions"], true)
	if err != nil || len(plants)+len(items) < 1 || len(plants)+len(items) > 200 {
		return req, invalid
	}
	payload["actions"] = plants
	if len(items) > 0 {
		payload["itemActions"] = items
	}
	req.digest, err = requestDigest("garden_edits", payload)
	return req, err
}

func readGardenActions(raw json.RawMessage, item bool) ([]gardenAction, []map[string]any, error) {
	var rows []json.RawMessage
	if len(raw) != 0 && (json.Unmarshal(raw, &rows) != nil || rows == nil || len(rows) > 200) {
		return nil, nil, invalid
	}
	actions := make([]gardenAction, 0, len(rows))
	canonical := make([]map[string]any, 0, len(rows))
	ids := make(map[uuid.UUID]bool, len(rows))
	idField, place := "plantId", "plant"
	if item {
		idField, place = "itemId", "place"
	}
	for _, value := range rows {
		r := &http.Request{Body: readOnlyBody{bytes.NewReader(value)}}
		fields, err := readBody(r, "action", idField, "x", "y", "rotationDegrees")
		if err != nil {
			return nil, nil, invalid
		}
		idText, idErr := stringField(fields, idField)
		id, uuidErr := uuid.Parse(idText)
		kind, kindErr := stringField(fields, "action")
		if idErr != nil || uuidErr != nil || kindErr != nil || ids[id] {
			return nil, nil, invalid
		}
		ids[id] = true
		a := gardenAction{id: id, kind: kind, hasRotation: fields["rotationDegrees"] != nil}
		entry := map[string]any{"action": kind, idField: id.String()}
		xy := kind == place || kind == "move"
		if kind != place && kind != "move" && kind != "rotate" && kind != "store" ||
			xy != (fields["x"] != nil) || xy != (fields["y"] != nil) ||
			(kind != "move" && a.hasRotation != (kind == place || kind == "rotate")) {
			return nil, nil, invalid
		}
		if xy {
			if a.position.x, err = gardenUnits(string(fields["x"]), 1000, 999999999); err != nil {
				return nil, nil, invalid
			}
			if a.position.y, err = gardenUnits(string(fields["y"]), 1000, 999999999); err != nil {
				return nil, nil, invalid
			}
			entry["x"], entry["y"] = gardenDigestNumber(a.position.x, 3), gardenDigestNumber(a.position.y, 3)
		} else if item {
			entry["x"], entry["y"] = nil, nil
		}
		if a.hasRotation {
			if a.position.rotation, err = gardenUnits(string(fields["rotationDegrees"]), 100, 35999); err != nil {
				return nil, nil, invalid
			}
			entry["rotationDegrees"] = gardenDigestNumber(a.position.rotation, 2)
		} else if item || kind == "move" {
			entry["rotationDegrees"] = nil
		}
		actions = append(actions, a)
		canonical = append(canonical, entry)
	}
	return actions, canonical, nil
}

type readOnlyBody struct{ *bytes.Reader }

func (readOnlyBody) Close() error { return nil }

func gardenUnits(text string, multiplier, limit int64) (int64, error) {
	if len(text) == 0 || len(text) > 64 || text[0] != '-' && (text[0] < '0' || text[0] > '9') {
		return 0, invalidGeometry
	}
	if i := strings.IndexAny(text, "eE"); i >= 0 {
		exp, err := strconv.Atoi(text[i+1:])
		if err != nil || exp < -100 || exp > 100 {
			return 0, invalidGeometry
		}
	}
	n, ok := new(big.Rat).SetString(text)
	if !ok {
		return 0, invalidGeometry
	}
	n.Mul(n, big.NewRat(multiplier, 1))
	if n.Sign() < 0 || !n.IsInt() || !n.Num().IsInt64() || n.Num().Int64() > limit {
		return 0, invalidGeometry
	}
	return n.Num().Int64(), nil
}

func gardenFixed(value int64, places int) string {
	scale := int64(100)
	if places == 3 {
		scale = 1000
	}
	digits := strconv.FormatInt(scale+value%scale, 10)[1:]
	return strconv.FormatInt(value/scale, 10) + "." + digits
}

func gardenDigestNumber(value int64, places int) json.Number {
	text := strings.TrimRight(gardenFixed(value, places), "0")
	if strings.HasSuffix(text, ".") {
		text += "0"
	}
	return json.Number(text)
}

type gardenCopy struct {
	id       uuid.UUID
	item     bool
	name     string
	enabled  bool
	radius   int64
	fact     gardenPlantFact
	itemFact gardenItemFact
}

type gardenProposal struct {
	copies         map[uuid.UUID]gardenCopy
	initial, final map[uuid.UUID]gardenTransform
}

func loadGardenCopies(ctx context.Context, tx pgx.Tx, g gardenRecord, req gardenRequest) (gardenProposal, error) {
	p := gardenProposal{copies: make(map[uuid.UUID]gardenCopy), initial: make(map[uuid.UUID]gardenTransform)}
	plantIDs := make([]uuid.UUID, 0, len(req.plants))
	itemIDs := make([]uuid.UUID, 0, len(req.items))
	for _, action := range req.plants {
		plantIDs = append(plantIDs, action.id)
	}
	for _, action := range req.items {
		itemIDs = append(itemIDs, action.id)
	}
	rows, err := tx.Query(ctx, `SELECT p.id,false,p.species_id,s.enabled AND v.enabled,p.clearance_radius::text,
		l.x::text,l.y::text,l.rotation_degrees::text,
		COALESCE(jsonb_array_length(b.rules->'gardenEffects'),0)>0,false,false,
		p.growth_micro_units::text,stage.current,(a.stage_attraction->>stage.current)::bigint,a.id,a.version,
		p.variant_id,a.gameplay_tags,b.id,b.version,COALESCE((b.rules->>'schemaVersion')::int,1),0
	FROM owned_plants p JOIN plant_species s ON s.id=p.species_id
	JOIN plant_variants v ON (v.species_id,v.variant_id)=(p.species_id,p.variant_id)
	JOIN growth_profiles gp ON (gp.id,gp.version)=(p.growth_profile_id,p.growth_profile_version)
	JOIN growth_rule_profiles b ON (b.id,b.version)=(p.behaviour_profile_id,p.behaviour_profile_version)
	JOIN attraction_profiles a ON (a.id,a.version)=(p.attraction_profile_id,p.attraction_profile_version)
	LEFT JOIN garden_placements l ON l.plant_id=p.id AND l.garden_id=$1
	CROSS JOIN LATERAL (SELECT CASE WHEN p.growth_micro_units>=(gp.thresholds->>'adult')::bigint THEN 'adult'
		WHEN p.growth_micro_units>=(gp.thresholds->>'young')::bigint THEN 'young'
		WHEN p.growth_micro_units>=(gp.thresholds->>'seedling')::bigint THEN 'seedling' ELSE 'sprout' END) stage(current)
	WHERE p.owner_id=$2 AND (l.plant_id IS NOT NULL OR p.id=ANY($3::uuid[]))
	UNION ALL
	SELECT o.id,true,d.id,true,d.clearance_radius::text,l.x::text,l.y::text,l.rotation_degrees::text,
		COALESCE(jsonb_array_length(s.rules->'effects'),0)>0,
		COALESCE(s.rules->'dailyGrant','null') NOT IN ('null','{}'),
		COALESCE(jsonb_array_length(s.rules->'triggeredGrants'),0)>0,
		'', '', 0::bigint, '', 0, '', '[]'::jsonb,COALESCE(s.id,''),COALESCE(s.version,0),0,d.version
	FROM owned_items o JOIN item_identities i ON i.id=o.id JOIN item_definitions d ON (d.id,d.version)=(i.item_id,i.item_version)
	LEFT JOIN item_placements l ON l.item_id=o.id AND l.garden_id=$1
	LEFT JOIN item_skill_bindings b ON (b.item_id,b.item_version)=(d.id,d.version)
	LEFT JOIN item_skill_profiles s ON (s.id,s.version)=(b.profile_id,b.profile_version)
	WHERE o.owner_id=$2 AND (l.item_id IS NOT NULL OR o.id=ANY($4::uuid[]))
	ORDER BY 2,1`, g.id, g.owner, plantIDs, itemIDs)
	if err != nil {
		return p, err
	}
	defer rows.Close()
	for rows.Next() {
		var c gardenCopy
		var radius string
		var x, y, rotation *string
		if err := rows.Scan(&c.id, &c.item, &c.name, &c.enabled, &radius, &x, &y, &rotation, &c.fact.skill.hasEffects,
			&c.itemFact.dailyGrant, &c.itemFact.stepGrant, &c.fact.growth, &c.fact.stage, &c.fact.attraction, &c.fact.profile.ID, &c.fact.profile.Version,
			&c.fact.skill.variant, &c.fact.skill.tags, &c.fact.skill.behaviour.ID, &c.fact.skill.behaviour.Version,
			&c.fact.skill.schema, &c.itemFact.definition.Version); err != nil {
			return p, err
		}
		c.fact.id = c.id
		c.fact.skill.species = c.name
		if c.item {
			c.itemFact.id = c.id
			c.itemFact.definition.ID = c.name
			c.itemFact.profile = c.fact.skill.behaviour
			c.itemFact.hasEffects = c.fact.skill.hasEffects
		}
		if _, exists := p.copies[c.id]; exists {
			return p, gardenPresentationUnavailable
		}
		c.radius, err = gardenUnits(radius, 1000, 999999999)
		if err != nil || c.radius == 0 {
			return p, invalidGeometry
		}
		if x != nil {
			t := new(gardenTransform)
			if t.x, err = gardenUnits(*x, 1000, 999999999); err != nil {
				return p, err
			}
			if t.y, err = gardenUnits(*y, 1000, 999999999); err != nil {
				return p, err
			}
			if t.rotation, err = gardenUnits(*rotation, 100, 35999); err != nil {
				return p, err
			}
			p.initial[c.id] = *t
		}
		p.copies[c.id] = c
	}
	p.final = maps.Clone(p.initial)
	return p, rows.Err()
}

func (p gardenProposal) propose(r *http.Request, g gardenRecord, req gardenRequest, catalog string, limit int64) error {
	if req.catalogue != catalog {
		return gardenError(409, "stale_catalogue", "Refresh the catalogue before editing",
			map[string]any{"expectedCatalogVersion": req.catalogue, "currentCatalogVersion": catalog})
	}
	if req.layout != g.layout {
		return gardenError(409, "stale_layout", "Refresh the garden before editing",
			map[string]any{"expectedLayoutVersion": req.layout, "currentLayoutVersion": g.layout})
	}
	if len(req.items) > 0 && r.Header.Get("X-Forest-Items") != "1" {
		return &apiError{426, "items_client_update_required", "Update the app to edit garden items"}
	}
	for _, c := range p.copies {
		if !c.item {
			continue
		}
		if r.Header.Get("X-Forest-Items") != "1" {
			return &apiError{426, "items_client_update_required", "Update the app to edit garden items"}
		}
		if c.name != "wooden-bench" && r.Header.Get("X-Forest-Item-Rotations") != "1" {
			return itemContentUpdate
		}
	}
	for _, group := range []struct {
		actions []gardenAction
		item    bool
	}{{req.items, true}, {req.plants, false}} {
		for _, a := range group.actions {
			copy, found := p.copies[a.id]
			message, prefix := "Plant", "plant"
			var details map[string]any
			if group.item {
				message, prefix = "Item", "item"
			} else {
				details = map[string]any{"plantId": a.id}
			}
			if !found || copy.item != group.item {
				return gardenError(404, prefix+"_not_found", message+" not found", nil)
			}
			initial, placed := p.initial[a.id]
			switch a.kind {
			case "plant", "place":
				if placed {
					return gardenError(409, prefix+"_already_placed", message+" is already placed", details)
				}
				if !copy.enabled {
					return gardenError(409, "plant_unavailable", "Plant is not enabled for planting", details)
				}
				p.final[a.id] = a.position
			default:
				if !placed {
					return gardenError(409, prefix+"_not_placed", message+" is stored, not placed", details)
				}
				switch a.kind {
				case "store":
					delete(p.final, a.id)
				case "rotate":
					initial.rotation = a.position.rotation
					p.final[a.id] = initial
				case "move":
					position := a.position
					if !a.hasRotation {
						position.rotation = initial.rotation
					}
					p.final[a.id] = position
				}
			}
		}
	}
	var initial, final int64
	for id := range p.initial {
		if !p.copies[id].item {
			initial++
		}
	}
	for id := range p.final {
		if !p.copies[id].item {
			final++
		}
	}
	if final > max(limit, initial) {
		return &apiError{409, "garden_capacity_full", "Plant collection limit reached. Store a planted copy before planting another."}
	}
	return p.validateGeometry(g)
}

func (p gardenProposal) ordered(layout map[uuid.UUID]gardenTransform) []uuid.UUID {
	return slices.SortedFunc(maps.Keys(layout), func(a, b uuid.UUID) int {
		if p.copies[a].item != p.copies[b].item {
			if p.copies[a].item {
				return 1
			}
			return -1
		}
		return bytes.Compare(a[:], b[:])
	})
}

func (p gardenProposal) validateGeometry(g gardenRecord) error {
	width, err := gardenUnits(g.width, 1000, 999999999)
	if err != nil || width == 0 {
		return invalidGeometry
	}
	depth, err := gardenUnits(g.depth, 1000, 999999999)
	if err != nil || depth == 0 {
		return invalidGeometry
	}
	ids := p.ordered(p.final)
	for _, id := range ids {
		point, radius := p.final[id], p.copies[id].radius
		if point.x < radius || point.y < radius || point.x > width-radius || point.y > depth-radius {
			return gardenError(422, "out_of_bounds", "Plant clearance extends beyond the garden", map[string]any{"plantId": id})
		}
	}
	for i, id := range ids {
		point := p.final[id]
		for _, other := range ids[i+1:] {
			next := p.final[other]
			dx, dy := point.x-next.x, point.y-next.y
			sum := p.copies[id].radius + p.copies[other].radius
			if dx*dx+dy*dy < sum*sum {
				return gardenError(422, "clearance_overlap", "Plant clearance circles overlap", map[string]any{"plantIds": []uuid.UUID{id, other}})
			}
		}
	}
	return nil
}

func (p gardenProposal) facts(layout map[uuid.UUID]gardenTransform) gardenFacts {
	facts := gardenFacts{plants: make([]gardenPlantFact, 0, len(layout))}
	for _, id := range p.ordered(layout) {
		c := p.copies[id]
		if c.item {
			facts.items = append(facts.items, c.itemFact)
		} else {
			facts.plants = append(facts.plants, c.fact)
		}
	}
	return facts
}
