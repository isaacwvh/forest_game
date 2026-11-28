package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
)

type PackPublication struct {
	ID           string          `json:"packId"`
	Version      int             `json:"version"`
	Fixture      bool            `json:"isFixture"`
	Definition   json.RawMessage `json:"definition"`
	OfferID      string          `json:"offerId"`
	OfferVersion int             `json:"offerVersion"`
	TokenCost    int64           `json:"tokenCost"`
	Currency     string          `json:"currency"`
}

func publishExchangePack(ctx context.Context, tx pgx.Tx, p PackPublication) (map[string]any, error) {
	if !packIdentifier.MatchString(p.ID) || !packIdentifier.MatchString(p.OfferID) ||
		p.Version < 1 || p.Version > 2_147_483_647 || p.OfferVersion < 1 || p.OfferVersion > 2_147_483_647 ||
		p.TokenCost < 1 || p.Currency != "tokens" && p.Currency != "gems" {
		return nil, invalidPack
	}
	definition, _, err := parsePackDefinition(p.Definition)
	if err != nil {
		return nil, err
	}
	var packMatches, offerMatches bool
	err = tx.QueryRow(ctx, `SELECT definition=$3 AND is_fixture=$4 FROM pack_definitions WHERE id=$1 AND version=$2`,
		p.ID, p.Version, p.Definition, p.Fixture).Scan(&packMatches)
	if err == nil && !packMatches {
		return nil, errors.New("published pack versions are immutable")
	}
	packExists := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	err = tx.QueryRow(ctx, `SELECT pack_id=$3 AND pack_version=$4 AND token_cost=$5 AND currency=$6
		FROM exchange_offers WHERE id=$1 AND version=$2`, p.OfferID, p.OfferVersion, p.ID, p.Version, p.TokenCost, p.Currency).Scan(&offerMatches)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	result := map[string]any{"packId": p.ID, "packVersion": p.Version, "offerId": p.OfferID, "offerVersion": p.OfferVersion}
	if err == nil {
		if !offerMatches {
			return nil, errors.New("published offer versions are immutable")
		}
		result["alreadyPublished"] = true
		return result, nil
	}
	var latest int
	if err := tx.QueryRow(ctx, "SELECT COALESCE(max(version),0) FROM exchange_offers WHERE id=$1", p.OfferID).Scan(&latest); err != nil {
		return nil, err
	}
	if p.OfferVersion <= latest {
		return nil, errors.New("use a newer offer version")
	}
	if !packExists {
		if _, err := tx.Exec(ctx, "INSERT INTO pack_definitions(id,version,is_fixture,definition) VALUES($1,$2,$3,$4)",
			p.ID, p.Version, p.Fixture, p.Definition); err != nil {
			return nil, err
		}
	}
	for _, pool := range definition.Rarities {
		if definition.SchemaVersion == 1 {
			for _, outcome := range pool.Outcomes {
				if err := publishPackMember(ctx, tx, p, definition.SchemaVersion, pool.Rarity, outcome.SpeciesID, outcome, packExists); err != nil {
					return nil, err
				}
			}
		} else {
			for _, species := range pool.Species {
				for _, variant := range species.Variants {
					if err := publishPackMember(ctx, tx, p, definition.SchemaVersion, pool.Rarity, species.SpeciesID, variant, packExists); err != nil {
						return nil, err
					}
				}
			}
		}
	}
	if _, err := tx.Exec(ctx, "UPDATE exchange_offers SET active=false WHERE id=$1 AND active", p.OfferID); err != nil {
		return nil, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO exchange_offers(id,version,pack_id,pack_version,token_cost,active,currency)
		VALUES ($1,$2,$3,$4,$5,true,$6)`, p.OfferID, p.OfferVersion, p.ID, p.Version, p.TokenCost, p.Currency)
	result["alreadyPublished"] = false
	return result, err
}

func publishPackMember(ctx context.Context, tx pgx.Tx, p PackPublication, schema int, rarity, species string, o packOutcome, packExists bool) error {
	var valid bool
	err := tx.QueryRow(ctx, `SELECT EXISTS(
		SELECT 1 FROM plant_species s JOIN plant_variants v ON v.species_id=s.id
		WHERE s.id=$1 AND v.variant_id=$2 AND s.enabled AND v.enabled AND (NOT s.is_fixture OR $3)
			AND CASE WHEN $4=2 THEN s.rarity ELSE v.rarity END=$5
			AND EXISTS(SELECT 1 FROM growth_profiles WHERE id=$6 AND version=$7)
			AND EXISTS(SELECT 1 FROM growth_rule_profiles WHERE id=$8 AND version=$9)
			AND EXISTS(SELECT 1 FROM attraction_profiles WHERE id=$10 AND version=$11)
			AND v.asset_catalog_version<>'' AND starts_with(v.asset_catalog_key,'assets/'||s.id||'/v1/')
			AND v.asset_catalog_key LIKE '%.json' AND strpos(v.asset_catalog_key,chr(92))=0
			AND NOT ('..'=ANY(string_to_array(v.asset_catalog_key,'/')))
			AND (SELECT count(*) FROM plant_stages a WHERE a.species_id=s.id AND a.variant_id=v.variant_id
				AND a.stage IN ('sprout','seedling','young','adult')
				AND starts_with(a.model_key,'assets/'||s.id||'/v1/') AND a.model_key LIKE '%.usdz'
				AND starts_with(a.thumbnail_key,'assets/'||s.id||'/v1/') AND a.thumbnail_key LIKE '%.png'
				AND strpos(a.model_key,chr(92))=0 AND strpos(a.thumbnail_key,chr(92))=0
				AND NOT ('..'=ANY(string_to_array(a.model_key,'/')))
				AND NOT ('..'=ANY(string_to_array(a.thumbnail_key,'/'))))=4
	)`, species, o.VariantID, p.Fixture, schema, rarity, o.Profiles.Growth.ID, o.Profiles.Growth.Version,
		o.Profiles.Behaviour.ID, o.Profiles.Behaviour.Version, o.Profiles.Attraction.ID, o.Profiles.Attraction.Version).Scan(&valid)
	if err != nil {
		return err
	}
	if !valid {
		return fmt.Errorf("invalid catalogue or pinned profiles for %s/%s: %w", species, o.VariantID, invalidPack)
	}
	if packExists {
		return nil
	}
	_, err = tx.Exec(ctx, `INSERT INTO pack_members(pack_id,pack_version,species_id,variant_id,
		growth_profile_id,growth_profile_version,behaviour_profile_id,behaviour_profile_version,attraction_profile_id,attraction_profile_version)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, p.ID, p.Version, species, o.VariantID,
		o.Profiles.Growth.ID, o.Profiles.Growth.Version, o.Profiles.Behaviour.ID, o.Profiles.Behaviour.Version,
		o.Profiles.Attraction.ID, o.Profiles.Attraction.Version)
	return err
}
