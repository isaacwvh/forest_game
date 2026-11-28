package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sync"

	"github.com/jackc/pgx/v5"
)

type catalogueState struct {
	Version string
	Fixture bool
	Metres  json.Number
}

type catalogueCache struct {
	mu    sync.Mutex
	state catalogueState
	value json.RawMessage
}

func (s *Server) catalogueState(ctx context.Context, tx pgx.Tx) (catalogueState, error) {
	var state catalogueState
	var metres string
	err := tx.QueryRow(ctx, "SELECT version, is_fixture, unit_metres::text FROM game_catalogue WHERE id=1 FOR SHARE").
		Scan(&state.Version, &state.Fixture, &metres)
	if errors.Is(err, pgx.ErrNoRows) {
		return state, catalogueUnavailable
	}
	if err == nil && state.Fixture && s.Environment != "local" && s.Environment != "test" {
		return state, &apiError{503, "fixture_catalogue_disabled", "Development catalogue is disabled"}
	}
	state.Metres = json.Number(metres)
	return state, err
}

func (s *Server) catalogue(r *http.Request, tx pgx.Tx, _ Identity) (any, error) {
	return s.catalogueDocument(r.Context(), tx)
}

func (s *Server) catalogueDocument(ctx context.Context, tx pgx.Tx) (json.RawMessage, error) {
	state, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	s.catalogues.mu.Lock()
	defer s.catalogues.mu.Unlock()
	if s.catalogues.state == state && s.catalogues.value != nil {
		return s.catalogues.value, nil
	}
	var document json.RawMessage
	err = tx.QueryRow(ctx, catalogueSQL, state.Version, state.Fixture, state.Metres.String()).Scan(&document)
	if err != nil {
		return nil, fmt.Errorf("catalogue document: %w", err)
	}
	document, err = catalogueSkillWire(document)
	if err != nil {
		return nil, fmt.Errorf("catalogue skill presentation: %w", err)
	}
	s.catalogues.state, s.catalogues.value = state, document
	return document, nil
}

func catalogueSkillWire(raw json.RawMessage) (json.RawMessage, error) {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		return nil, err
	}
	var profiles map[string]json.RawMessage
	if err := json.Unmarshal(doc["profiles"], &profiles); err != nil {
		return nil, err
	}
	var behaviours []map[string]json.RawMessage
	if err := json.Unmarshal(profiles["behaviour"], &behaviours); err != nil {
		return nil, err
	}
	for _, profile := range behaviours {
		skills, err := plantSkillWire(profile["gardenEffects"])
		if err != nil {
			return nil, err
		}
		profile["gardenEffects"] = skills
	}
	encoded, err := json.Marshal(behaviours)
	if err != nil {
		return nil, err
	}
	profiles["behaviour"] = encoded
	encoded, err = json.Marshal(profiles)
	if err != nil {
		return nil, err
	}
	doc["profiles"] = encoded
	return json.Marshal(doc)
}

const catalogueSQL = `
WITH species AS (
	SELECT * FROM plant_species WHERE enabled
), variants AS (
	SELECT v.* FROM plant_variants v JOIN species s ON s.id=v.species_id WHERE v.enabled
), growth_refs AS (
	SELECT growth_profile_id AS id,growth_profile_version AS version FROM species
	UNION SELECT growth_profile_id,growth_profile_version FROM variants WHERE growth_profile_id IS NOT NULL
), behaviour_refs AS (
	SELECT behaviour_profile_id AS id,behaviour_profile_version AS version FROM species
	UNION SELECT behaviour_profile_id,behaviour_profile_version FROM variants WHERE behaviour_profile_id IS NOT NULL
), attraction_refs AS (
	SELECT attraction_profile_id AS id,attraction_profile_version AS version FROM species
	UNION SELECT attraction_profile_id,attraction_profile_version FROM variants WHERE attraction_profile_id IS NOT NULL
)
SELECT jsonb_build_object(
	'catalogVersion',$1::text, 'isFixture',$2::bool, 'coordinateUnit','garden_unit',
	'gardenUnitMetres',$3::numeric, 'coordinateDecimalPlaces',3, 'rotationDecimalPlaces',2,
	'species',COALESCE((SELECT jsonb_agg(jsonb_build_object(
		'speciesId',s.id, 'displayName',s.display_name, 'rarity',s.rarity,'description',s.description,
		'clearanceRadius',s.clearance_radius,'isFixture',s.is_fixture,
		'defaultProfiles',jsonb_build_object(
			'growth',jsonb_build_object('id',s.growth_profile_id,'version',s.growth_profile_version),
			'behaviour',jsonb_build_object('id',s.behaviour_profile_id,'version',s.behaviour_profile_version),
			'attraction',jsonb_build_object('id',s.attraction_profile_id,'version',s.attraction_profile_version)),
		'variants',COALESCE((SELECT jsonb_agg(jsonb_build_object(
			'variantId',v.variant_id,'displayName',v.display_name,'description',v.description,'rarity',v.rarity,
			'assetCatalogKey',v.asset_catalog_key,'assetCatalogVersion',v.asset_catalog_version,
			'profileOverrides',jsonb_build_object(
				'growth',CASE WHEN v.growth_profile_id IS NOT NULL THEN jsonb_build_object('id',v.growth_profile_id,'version',v.growth_profile_version) END,
				'behaviour',CASE WHEN v.behaviour_profile_id IS NOT NULL THEN jsonb_build_object('id',v.behaviour_profile_id,'version',v.behaviour_profile_version) END,
				'attraction',CASE WHEN v.attraction_profile_id IS NOT NULL THEN jsonb_build_object('id',v.attraction_profile_id,'version',v.attraction_profile_version) END),
			'stages',COALESCE((SELECT jsonb_object_agg(t.stage,jsonb_build_object('modelKey',t.model_key,'thumbnailKey',t.thumbnail_key))
				FROM plant_stages t WHERE (t.species_id,t.variant_id)=(v.species_id,v.variant_id)), '{}'))
			ORDER BY v.variant_id COLLATE "C") FROM variants v WHERE v.species_id=s.id),'[]'))
		ORDER BY s.id COLLATE "C") FROM species s),'[]'),
	'profiles',jsonb_build_object(
		'growth',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',g.id,'version',g.version,
			'maximumGrowthMicroUnits',g.maximum_growth_micro_units::text,
			'thresholdsMicroUnits',(SELECT jsonb_object_agg(key,value) FROM jsonb_each_text(g.thresholds)))
			ORDER BY g.id COLLATE "C",g.version) FROM growth_profiles g JOIN growth_refs USING(id,version)),'[]'),
		'behaviour',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',b.id,'version',b.version) || b.rules
			ORDER BY b.id COLLATE "C",b.version) FROM growth_rule_profiles b JOIN behaviour_refs USING(id,version)),'[]'),
		'attraction',COALESCE((SELECT jsonb_agg(jsonb_build_object('id',a.id,'version',a.version,
			'stageAttractionMicroUnits',(SELECT jsonb_object_agg(key,value) FROM jsonb_each_text(a.stage_attraction)),
			'gameplayTags',a.gameplay_tags) ORDER BY a.id COLLATE "C",a.version)
			FROM attraction_profiles a JOIN attraction_refs USING(id,version)),'[]')))
`
