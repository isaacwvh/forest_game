package server

import (
	"cmp"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

var (
	packUnavailable = &apiError{503, "pack_unavailable", "This pack definition is unavailable"}
	invalidPack     = &apiError{409, "invalid_pack", "Pack definition or dependencies are invalid"}
	packIdentifier  = regexp.MustCompile("^[a-z][a-z0-9_-]{0,99}$")
	packRarity      = regexp.MustCompile("^[a-z][a-z0-9_]{0,31}$")
)

type packKey struct {
	ID      string
	Version int
}

type packRef struct {
	ID      string
	Version int
}

type packProfiles struct {
	Growth, Behaviour, Attraction packRef
}

type packOutcome struct {
	SpeciesID       string
	VariantID       string
	Weight          int
	Profiles        packProfiles
	ClearanceRadius json.RawMessage
}

type packSpecies struct {
	SpeciesID string
	Variants  []packOutcome
}

type packPool struct {
	Rarity   string
	Weight   int
	Outcomes []packOutcome
	Species  []packSpecies
}

type packDefinition struct {
	SchemaVersion int
	DisplayName   string
	Description   string
	Rarities      []packPool
}

type packCacheEntry struct {
	definition packDefinition
	total      int
	value      json.RawMessage
	until      time.Time
}

type packCache struct {
	mu      sync.Mutex
	entries map[packKey]packCacheEntry
}

func (c *packCache) get(key packKey) (packCacheEntry, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry := c.entries[key]
	return entry, time.Now().Before(entry.until)
}

func (c *packCache) put(key packKey, entry packCacheEntry) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.entries == nil || len(c.entries) >= 128 {
		c.entries = make(map[packKey]packCacheEntry)
	}
	entry.until = time.Now().Add(5 * time.Minute)
	c.entries[key] = entry
}

func parsePackDefinition(raw json.RawMessage) (packDefinition, int, error) {
	var definition packDefinition
	if err := json.Unmarshal(raw, &definition); err != nil ||
		(definition.SchemaVersion != 1 && definition.SchemaVersion != 2) ||
		len(definition.Rarities) < 1 || len(definition.Rarities) > 20 ||
		len([]rune(definition.DisplayName)) < 1 || len([]rune(definition.DisplayName)) > 100 ||
		len([]rune(definition.Description)) > 2000 {
		return definition, 0, invalidPack
	}
	rarities := make(map[string]bool)
	species := make(map[string]bool)
	pairs := make(map[[2]string]bool)
	total := 0
	for _, pool := range definition.Rarities {
		if !packRarity.MatchString(pool.Rarity) || rarities[pool.Rarity] || !validWeight(pool.Weight) {
			return definition, 0, invalidPack
		}
		rarities[pool.Rarity] = true
		total += pool.Weight
		if definition.SchemaVersion == 1 {
			if pool.Outcomes == nil || pool.Species != nil || len(pool.Outcomes) > 1000 ||
				(pool.Weight > 0 && len(pool.Outcomes) == 0) {
				return definition, 0, invalidPack
			}
			for _, outcome := range pool.Outcomes {
				key := [2]string{outcome.SpeciesID, outcome.VariantID}
				if pairs[key] || !validPackOutcome(outcome.SpeciesID, outcome) {
					return definition, 0, invalidPack
				}
				pairs[key] = true
			}
			continue
		}
		if pool.Species == nil || pool.Outcomes != nil || len(pool.Species) > 1000 ||
			(pool.Weight > 0 && len(pool.Species) == 0) {
			return definition, 0, invalidPack
		}
		for _, group := range pool.Species {
			if species[group.SpeciesID] || len(group.Variants) < 1 || len(group.Variants) > 1000 {
				return definition, 0, invalidPack
			}
			species[group.SpeciesID] = true
			variantsTotal := 0
			for _, outcome := range group.Variants {
				key := [2]string{group.SpeciesID, outcome.VariantID}
				if pairs[key] || !validWeight(outcome.Weight) || !validPackOutcome(group.SpeciesID, outcome) {
					return definition, 0, invalidPack
				}
				pairs[key] = true
				variantsTotal += outcome.Weight
			}
			if variantsTotal == 0 {
				return definition, 0, invalidPack
			}
		}
	}
	if total == 0 {
		return definition, 0, invalidPack
	}
	return definition, total, nil
}

func validWeight(n int) bool {
	return n >= 0 && n <= 1_000_000
}

func validPackOutcome(species string, o packOutcome) bool {
	if !packIdentifier.MatchString(species) || !packIdentifier.MatchString(o.VariantID) {
		return false
	}
	for _, p := range []packRef{o.Profiles.Growth, o.Profiles.Behaviour, o.Profiles.Attraction} {
		if p.ID == "" || len(p.ID) > 100 || p.Version < 1 || p.Version > 2_147_483_647 {
			return false
		}
	}
	if len(o.ClearanceRadius) != 0 && string(o.ClearanceRadius) != "null" {
		var radius float64
		if json.Unmarshal(o.ClearanceRadius, &radius) != nil || radius <= 0 || radius > 999999.999 {
			return false
		}
	}
	return true
}

func (s *Server) loadPackDefinition(ctx context.Context, tx pgx.Tx, key packKey) (json.RawMessage, bool, error) {
	var raw json.RawMessage
	var fixture bool
	err := tx.QueryRow(ctx, "SELECT definition,is_fixture FROM pack_definitions WHERE (id,version)=($1,$2)", key.ID, key.Version).Scan(&raw, &fixture)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && fixture && s.Environment != "local" && s.Environment != "test" {
		return nil, false, packUnavailable
	}
	return raw, fixture, err
}

func (s *Server) packPresentation(ctx context.Context, tx pgx.Tx, key packKey, cache bool) (json.RawMessage, error) {
	entry, err := s.readPack(ctx, tx, key, cache)
	return entry.value, err
}

func (s *Server) readPack(ctx context.Context, tx pgx.Tx, key packKey, cache bool) (packCacheEntry, error) {
	if cache {
		if entry, ok := s.packs.get(key); ok {
			return entry, nil
		}
	}
	raw, fixture, err := s.loadPackDefinition(ctx, tx, key)
	if err != nil {
		return packCacheEntry{}, err
	}
	definition, total, err := parsePackDefinition(raw)
	if err != nil {
		return packCacheEntry{}, err
	}
	var document map[string]json.RawMessage
	if err := json.Unmarshal(raw, &document); err != nil {
		return packCacheEntry{}, err
	}
	document["packId"], _ = json.Marshal(key.ID)
	document["version"] = json.RawMessage(strconv.Itoa(key.Version))
	document["isFixture"] = json.RawMessage(strconv.FormatBool(fixture))
	document["totalWeight"] = json.RawMessage(strconv.Itoa(total))
	presentation, err := json.Marshal(document)
	entry := packCacheEntry{definition: definition, total: total, value: presentation}
	if err == nil && cache {
		s.packs.put(key, entry)
	}
	return entry, err
}

func (s *Server) packDefinition(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	version, err := strconv.ParseInt(r.PathValue("version"), 10, 32)
	if err != nil {
		return nil, invalid
	}
	if _, err := lookupProfile(r.Context(), tx, id, false); err != nil {
		return nil, err
	}
	return s.packPresentation(r.Context(), tx, packKey{r.PathValue("packID"), int(version)}, false)
}

func securePackRoll(n int) (int, error) {
	value, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0, err
	}
	return int(value.Int64()), nil
}

func choosePack(def packDefinition, total int, roll func(int) (int, error)) (string, packOutcome, error) {
	pools := slices.Clone(def.Rarities)
	slices.SortFunc(pools, func(a, b packPool) int { return cmp.Compare(a.Rarity, b.Rarity) })
	draw, err := roll(total)
	if err != nil {
		return "", packOutcome{}, err
	}
	for _, pool := range pools {
		if draw >= pool.Weight {
			draw -= pool.Weight
			continue
		}
		if def.SchemaVersion == 1 {
			outcomes := slices.Clone(pool.Outcomes)
			slices.SortFunc(outcomes, func(a, b packOutcome) int {
				if a.SpeciesID != b.SpeciesID {
					return cmp.Compare(a.SpeciesID, b.SpeciesID)
				}
				return cmp.Compare(a.VariantID, b.VariantID)
			})
			index, err := roll(len(outcomes))
			if err != nil {
				return "", packOutcome{}, err
			}
			return pool.Rarity, outcomes[index], nil
		}
		species := slices.Clone(pool.Species)
		slices.SortFunc(species, func(a, b packSpecies) int { return cmp.Compare(a.SpeciesID, b.SpeciesID) })
		index, err := roll(len(species))
		if err != nil {
			return "", packOutcome{}, err
		}
		group := species[index]
		variants := slices.Clone(group.Variants)
		slices.SortFunc(variants, func(a, b packOutcome) int { return cmp.Compare(a.VariantID, b.VariantID) })
		variantTotal := 0
		for _, v := range variants {
			variantTotal += v.Weight
		}
		variantDraw, err := roll(variantTotal)
		if err != nil {
			return "", packOutcome{}, err
		}
		for _, variant := range variants {
			if variantDraw < variant.Weight {
				variant.SpeciesID = group.SpeciesID
				return pool.Rarity, variant, nil
			}
			variantDraw -= variant.Weight
		}
		return "", packOutcome{}, invalidPack
	}
	return "", packOutcome{}, invalidPack
}
