package server

import (
	"cmp"
	"context"
	"encoding/json"
	"maps"
	"slices"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

type skillProfileKey struct {
	ID      string `json:"id"`
	Version int    `json:"version"`
	Item    bool   `json:"item"`
}

type skillProfileEntry struct {
	effects      []skillEffect
	presentation json.RawMessage
	expires      time.Time
}

type skillProfileCache struct {
	mu      sync.Mutex
	entries map[skillProfileKey]skillProfileEntry
}

func (s *Server) loadGardenSkills(ctx context.Context, tx pgx.Tx, facts gardenFacts) error {
	requested := make(map[skillProfileKey]skillProfileEntry)
	for _, p := range facts.plants {
		if p.skill.hasEffects {
			requested[skillProfileKey{p.skill.behaviour.ID, p.skill.behaviour.Version, false}] = skillProfileEntry{}
		}
	}
	for _, i := range facts.items {
		if i.hasEffects {
			requested[skillProfileKey{i.profile.ID, i.profile.Version, true}] = skillProfileEntry{}
		}
	}
	if len(requested) == 0 {
		return nil
	}
	if err := s.skillProfiles.fill(ctx, tx, requested); err != nil {
		return err
	}
	for i, p := range facts.plants {
		if p.skill.hasEffects {
			definition := requested[skillProfileKey{p.skill.behaviour.ID, p.skill.behaviour.Version, false}]
			facts.plants[i].skill.effects, facts.plants[i].skill.presentation = definition.effects, definition.presentation
		}
	}
	for i, p := range facts.items {
		if p.hasEffects {
			facts.items[i].effects = requested[skillProfileKey{p.profile.ID, p.profile.Version, true}].effects
		}
	}
	return nil
}

func (c *skillProfileCache) fill(ctx context.Context, tx pgx.Tx, requested map[skillProfileKey]skillProfileEntry) error {
	now := time.Now()
	c.mu.Lock()
	missing := make([]skillProfileKey, 0, len(requested))
	for k := range requested {
		if cached, ok := c.entries[k]; ok && now.Before(cached.expires) {
			requested[k] = cached
		} else {
			missing = append(missing, k)
		}
	}
	c.mu.Unlock()
	if len(missing) == 0 {
		return nil
	}
	slices.SortFunc(missing, func(a, b skillProfileKey) int {
		if order := cmp.Compare(a.ID, b.ID); order != 0 {
			return order
		}
		return cmp.Compare(a.Version, b.Version)
	})
	rows, err := tx.Query(ctx, `WITH refs AS (SELECT * FROM jsonb_to_recordset($1::jsonb) r(id text,version int,item bool))
	  SELECT r.id,r.version,r.item,p.rules->'gardenEffects' FROM refs r
	  JOIN growth_rule_profiles p ON (p.id,p.version)=(r.id,r.version) WHERE NOT r.item
	  UNION ALL
	  SELECT r.id,r.version,r.item,p.rules->'effects' FROM refs r
	  JOIN item_skill_profiles p ON (p.id,p.version)=(r.id,r.version) WHERE r.item`, missing)
	if err != nil {
		return err
	}
	defer rows.Close()
	fetched := make(map[skillProfileKey]skillProfileEntry, len(missing))
	for rows.Next() {
		var key skillProfileKey
		var raw json.RawMessage
		if err := rows.Scan(&key.ID, &key.Version, &key.Item, &raw); err != nil {
			return err
		}
		effects, err := parseSkillEffects(raw, key.Item)
		if err != nil {
			return err
		}
		entry := skillProfileEntry{effects, raw, now.Add(5 * time.Minute)}
		requested[key] = entry
		fetched[key] = entry
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if len(fetched) != len(missing) {
		return invalidSkills
	}
	// Published revisions are immutable while referenced by a plant or item.
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.entries)+len(fetched) > 128 || c.entries == nil {
		c.entries = make(map[skillProfileKey]skillProfileEntry)
	}
	if len(fetched) <= 128 {
		maps.Copy(c.entries, fetched)
	}
	return nil
}

func readPlacedSkillItems(ctx context.Context, tx pgx.Tx, garden gardenRecord) ([]gardenItemFact, error) {
	rows, err := tx.Query(ctx, `SELECT i.id,i.item_id,i.item_version,s.id,s.version,
		COALESCE(jsonb_array_length(s.rules->'effects'),0)>0,
		COALESCE(s.rules->'dailyGrant','null') NOT IN ('null','{}'),
		COALESCE(jsonb_array_length(s.rules->'triggeredGrants'),0)>0
		FROM item_placements p JOIN item_identities i ON i.id=p.item_id
		JOIN item_skill_bindings b ON (b.item_id,b.item_version)=(i.item_id,i.item_version)
		JOIN item_skill_profiles s ON (s.id,s.version)=(b.profile_id,b.profile_version)
		WHERE p.garden_id=$1 AND i.owner_id=$2 ORDER BY i.id`, garden.id, garden.owner)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (gardenItemFact, error) {
		var i gardenItemFact
		err := row.Scan(&i.id, &i.definition.ID, &i.definition.Version, &i.profile.ID, &i.profile.Version, &i.hasEffects, &i.dailyGrant, &i.stepGrant)
		return i, err
	})
}
