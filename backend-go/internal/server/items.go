package server

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const itemLimit = 50

type ownedItem struct {
	ID           uuid.UUID        `json:"ownedItemId"`
	ItemID       string           `json:"itemId"`
	Version      int              `json:"definitionVersion"`
	Name         string           `json:"displayName"`
	Description  string           `json:"description"`
	Rarity       string           `json:"rarity"`
	AssetVersion string           `json:"assetVersion"`
	Model        string           `json:"modelKey"`
	Thumbnail    string           `json:"thumbnailKey"`
	Radius       json.Number      `json:"clearanceRadius"`
	Placement    json.RawMessage  `json:"placement"`
	Skills       []map[string]any `json:"gardenSkills"`
	Strategy     map[string]any   `json:"strategyRules"`
}

type itemCapacity struct {
	Owned  int `json:"ownedItems"`
	Placed int `json:"placedItems"`
	Stored int `json:"storedItems"`
	Limit  int `json:"itemLimit"`
}

func readItemCapacity(ctx context.Context, tx pgx.Tx, owner string) (itemCapacity, error) {
	var cap itemCapacity
	err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM owned_items WHERE owner_id=$1),
		(SELECT count(*) FROM item_placements WHERE owner_id=$1)`, owner).Scan(&cap.Owned, &cap.Placed)
	cap.Stored, cap.Limit = cap.Owned-cap.Placed, itemLimit
	return cap, err
}

func (s *Server) itemInventory(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	limit, after, err := parsePage(r, 100, 100)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if err := gardenShare(ctx, tx, p.ID); err != nil {
		return nil, err
	}
	return itemInventoryFor(ctx, tx, p.ID, limit, after, r.Header)
}

func itemInventoryFor(ctx context.Context, tx pgx.Tx, owner string, limit int, after *uuid.UUID, headers http.Header) (any, error) {
	var cap itemCapacity
	var expedition, rotation, validCursor bool
	err := tx.QueryRow(ctx, `SELECT count(*),count(p.item_id),
		COALESCE(bool_or(i.item_id IN ('astronomers-satchel','comet-basin','worldseed-orrery')),false),
		COALESCE(bool_or(i.item_id <> 'wooden-bench'),false),
		($2::uuid IS NULL OR COALESCE(bool_or(o.id=$2),false))
	FROM owned_items o JOIN item_identities i ON i.id=o.id
	LEFT JOIN item_placements p ON p.item_id=o.id WHERE o.owner_id=$1`, owner, after).
		Scan(&cap.Owned, &cap.Placed, &expedition, &rotation, &validCursor)
	if err != nil {
		return nil, err
	}
	if expedition && headers.Get("X-Forest-Expeditions") != "1" {
		return nil, &apiError{426, "expedition_update_required", "Update the app for expedition rewards"}
	}
	if rotation && headers.Get("X-Forest-Item-Rotations") != "1" {
		return nil, itemContentUpdate
	}
	if !validCursor {
		return nil, &apiError{400, "invalid_cursor", "Refresh the item inventory"}
	}
	cap.Stored, cap.Limit = cap.Owned-cap.Placed, itemLimit
	items := []ownedItem{}
	if cap.Owned > 0 {
		items, err = readItems(ctx, tx, `o.owner_id=$1 AND ($2::uuid IS NULL OR o.id>$2) ORDER BY o.id LIMIT $3`, owner, after, limit+1)
		if err != nil {
			return nil, err
		}
	}
	var next *uuid.UUID
	if len(items) > limit {
		items = items[:limit]
		next = &items[len(items)-1].ID
	}
	return map[string]any{"items": items, "capacity": cap, "nextCursor": next}, nil
}

// The predicates are fixed SQL from the inventory and purchase callers.
func readItems(ctx context.Context, tx pgx.Tx, predicate string, args ...any) ([]ownedItem, error) {
	rows, err := tx.Query(ctx, `SELECT o.id,d.id,d.version,d.display_name,d.description,d.rarity,d.asset_version,
		d.model_key,d.thumbnail_key,d.clearance_radius::text,CASE WHEN p.item_id IS NOT NULL THEN
		jsonb_build_object('gardenId',p.garden_id,'x',p.x,'y',p.y,'rotationDegrees',p.rotation_degrees) END,
		COALESCE(s.id,d.id),COALESCE(s.version,d.version),s.rules
	FROM owned_items o JOIN item_identities i ON i.id=o.id
	JOIN item_definitions d ON (d.id,d.version)=(i.item_id,i.item_version)
	LEFT JOIN item_placements p ON p.item_id=o.id
	LEFT JOIN item_skill_bindings b ON (b.item_id,b.item_version)=(d.id,d.version)
	LEFT JOIN item_skill_profiles s ON (s.id,s.version)=(b.profile_id,b.profile_version)
	WHERE `+predicate, args...)
	if err != nil {
		return nil, err
	}
	result, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (value ownedItem, err error) {
		var radius, profile string
		var version int
		var rules json.RawMessage
		err = row.Scan(&value.ID, &value.ItemID, &value.Version, &value.Name, &value.Description, &value.Rarity, &value.AssetVersion,
			&value.Model, &value.Thumbnail, &radius, &value.Placement, &profile, &version, &rules)
		if err != nil {
			return value, err
		}
		value.Radius = json.Number(radius)
		value.Skills, value.Strategy, err = itemSkillPresentation(profile, version, rules)
		return value, err
	})
	if result == nil {
		result = []ownedItem{}
	}
	return result, err
}

func itemSkillPresentation(profile string, version int, rules json.RawMessage) ([]map[string]any, map[string]any, error) {
	var source struct {
		Effects   []map[string]json.RawMessage `json:"effects"`
		Daily     json.RawMessage              `json:"dailyGrant"`
		Triggered json.RawMessage              `json:"triggeredGrants"`
	}
	if rules != nil {
		if err := json.Unmarshal(rules, &source); err != nil {
			return nil, nil, err
		}
	}
	effects := []map[string]json.RawMessage{}
	info := []map[string]any{}
	for _, raw := range source.Effects {
		info = append(info, map[string]any{"id": raw["id"], "name": raw["name"], "description": raw["description"]})
		defaults := map[string]json.RawMessage{
			"componentVersion": []byte("1"), "minimumStage": []byte(`"adult"`), "operation": []byte(`"percent"`),
			"stackingRule": []byte(`"strongest"`), "metric": []byte("null"), "recipients": []byte("null"), "condition": []byte("null"),
		}
		for key, value := range raw {
			defaults[key] = value
		}
		if string(defaults["stepBand"]) == "null" {
			delete(defaults, "stepBand")
		}
		if string(defaults["metric"]) != `"workouts"` {
			effects = append(effects, defaults)
			continue
		}
		for _, kind := range []string{"cycling", "hiking", "running", "strength_training", "swimming", "walking", "yoga"} {
			effect := make(map[string]json.RawMessage, len(defaults))
			for key, value := range defaults {
				effect[key] = value
			}
			effect["metric"] = []byte(`"workout_minutes.` + kind + `"`)
			effects = append(effects, effect)
		}
	}
	strategy := map[string]any{"profileId": profile, "profileVersion": version, "effects": effects, "dailyGrant": source.Daily}
	if source.Triggered != nil {
		strategy["triggeredGrants"] = source.Triggered
	}
	switch {
	case len(source.Triggered) > 0 && string(source.Triggered) != "null" && string(source.Triggered) != "[]":
		info = []map[string]any{{"id": profile, "name": "Alignment of Worlds", "description": "While placed, 2,000 / 4,000 / 6,000 eligible daily steps grant 3 / 4 / 5 flat water per planted plant. Copies share progress; storing pauses it."}}
	case len(source.Daily) > 0 && string(source.Daily) != "null":
		info = []map[string]any{{"id": profile, "name": "Morning Rain", "description": "+2.5 water per planted plant at account-local midnight. Rainharp and plant must be placed at reset. Duplicate harps apply once."}}
	}
	return info, strategy, nil
}
