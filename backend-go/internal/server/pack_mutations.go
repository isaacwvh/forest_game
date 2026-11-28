package server

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const packReceiptSQL = `
SELECT payload_hash,receipt FROM collection_events WHERE owner_id=$1 AND request_id=$2
UNION ALL
SELECT a.payload_hash,e.receipt
FROM api_requests a JOIN pack_openings o
	ON o.owner_id=a.user_id AND o.id=(a.completion#>>'{outcome,openingId}')::uuid
JOIN collection_events e ON e.id=o.event_id AND e.owner_id=a.user_id
WHERE a.user_id=$1 AND a.request_id=$2 AND a.operation='pack_open' AND a.response IS NULL
LIMIT 1`

var (
	packNotFound         = &apiError{404, "pack_not_found", "Pack not found"}
	packCapacityFull     = &apiError{409, "pack_capacity_full", "Pack storage full. Open a pack before buying more."}
	plantCapacityFull    = &apiError{409, "plant_capacity_full", "Plant collection full. Sell a stored plant to open this pack."}
	exchangeInsufficient = &apiError{409, "insufficient_tokens", "You need more visitor tokens for this exchange"}
)

type packMutation struct {
	owner             string
	request, event    uuid.UUID
	operation, digest string
	at                time.Time
	baseState         int64
}

func (m packMutation) saveEvent(ctx context.Context, tx pgx.Tx, receipt map[string]any, tokenDelta, gemDelta int64) error {
	_, err := tx.Exec(ctx, `INSERT INTO collection_events
		(id,owner_id,request_id,operation,payload_hash,token_delta,gem_delta,receipt,created_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8::jsonb,$9)`, m.event, m.owner, m.request, m.operation,
		m.digest, tokenDelta, gemDelta, receipt, m.at)
	return err
}

func preparePackMutation(r *http.Request, tx pgx.Tx, id Identity, request uuid.UUID, operation, digest string) (packMutation, json.RawMessage, error) {
	ctx := r.Context()
	var m packMutation
	user, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return m, nil, err
	}
	m = packMutation{owner: user.ID, request: request, operation: operation, digest: digest}
	saved, err := commerceReplay(ctx, tx, m.owner, m.request, operation, digest, packReceiptSQL, r.Header.Get("X-Forest-Recovery") == "1")
	if err != nil || saved != nil {
		return m, saved, err
	}
	m.baseState, err = lockCommerceGarden(ctx, tx, m.owner)
	if err != nil {
		return m, nil, err
	}
	return m, nil, nil
}

func (s *Server) enterPackMutation(ctx context.Context, tx pgx.Tx, m *packMutation) error {
	if _, err := s.catalogueState(ctx, tx); err != nil {
		return err
	}
	if err := tx.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&m.at); err != nil {
		return err
	}
	m.event = uuid.New()
	return throttle(ctx, tx, m.owner, m.at)
}

func (s *Server) exchangePack(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	body, err := readBody(r, "requestId", "offerId", "offerVersion", "quantity")
	if err != nil {
		return nil, err
	}
	key, err := requestID(body)
	if err != nil {
		return nil, err
	}
	offer, err := stringField(body, "offerId")
	var version int
	quantity := 1
	if err != nil || !packIdentifier.MatchString(offer) || json.Unmarshal(body["offerVersion"], &version) != nil ||
		version < 1 || version > math.MaxInt32 {
		return nil, invalid
	}
	if raw, ok := body["quantity"]; ok && (string(raw) == "null" || json.Unmarshal(raw, &quantity) != nil || quantity < 1 || quantity > 20) {
		return nil, invalid
	}
	const operation = "token_exchange"
	digest, err := requestDigest(operation, map[string]any{"offerId": offer, "offerVersion": version, "quantity": quantity})
	if err != nil {
		return nil, err
	}
	m, saved, err := preparePackMutation(r, tx, id, key, operation, digest)
	if err != nil || saved != nil {
		return saved, err
	}
	ctx := r.Context()
	if err := s.enterPackMutation(ctx, tx, &m); err != nil {
		return nil, err
	}
	limits, err := s.plantCapacity(ctx, tx, m.owner)
	if err != nil {
		return nil, err
	}
	if limits["unopenedPacks"]+int64(quantity) > limits["packLimit"] {
		return nil, packCapacityFull
	}
	var pack packKey
	var cost int64
	var currency string
	err = tx.QueryRow(ctx, `SELECT pack_id,pack_version,token_cost,currency FROM exchange_offers
		WHERE id=$1 AND version=$2 AND active`, offer, version).Scan(&pack.ID, &pack.Version, &cost, &currency)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, staleOffer
	}
	if err != nil {
		return nil, err
	}
	if _, _, err := s.packForMutation(r, tx, pack); err != nil {
		return nil, err
	}
	if cost > math.MaxInt64/int64(quantity) {
		return nil, amountOverflow
	}
	var tokenCost, gemCost int64
	if currency == "gems" {
		gemCost = cost * int64(quantity)
	} else {
		tokenCost = cost * int64(quantity)
	}
	wallet, err := updateCommerceWallet(ctx, tx, m.owner, -tokenCost, -gemCost, exchangeInsufficient)
	if err != nil {
		return nil, err
	}
	packs := make([]ownedPack, quantity)
	ids := make([]uuid.UUID, quantity)
	for i := range packs {
		ids[i] = uuid.New()
		packs[i] = ownedPack{ID: ids[i], PackID: pack.ID, Version: pack.Version, Acquired: m.at}
	}
	limits["unopenedPacks"] += int64(quantity)
	receipt := map[string]any{"requestId": key, "exchangeId": m.event, "offerId": offer, "offerVersion": version,
		"quantity": quantity, "tokensSpent": numberString(tokenCost), "gemsSpent": numberString(gemCost),
		"currency": currency, "packs": packs, "capacity": limits}
	wallet.addTo(receipt)
	if err := m.saveEvent(ctx, tx, receipt, -tokenCost, -gemCost); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO owned_packs (id,owner_id,pack_id,pack_version,exchange_id,acquired_at)
		SELECT p.id,$1,$2,$3,$4,$5 FROM unnest($6::uuid[]) AS p(id)`, m.owner, pack.ID, pack.Version, m.event, m.at, ids); err != nil {
		return nil, err
	}
	return receipt, saveRecoveryReceipt(r, tx, m.owner, key, operation, digest, receipt, "exchangeId")
}

func (s *Server) openPack(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	packID, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		return nil, invalid
	}
	body, err := readBody(r, "requestId")
	if err != nil {
		return nil, err
	}
	key, err := requestID(body)
	if err != nil {
		return nil, err
	}
	const operation = "pack_open"
	digest, err := requestDigest(operation+":"+packID.String(), map[string]any{})
	if err != nil {
		return nil, err
	}
	m, saved, err := preparePackMutation(r, tx, id, key, operation, digest)
	if err != nil || saved != nil {
		return saved, err
	}
	ctx := r.Context()
	if err := s.enterPackMutation(ctx, tx, &m); err != nil {
		return nil, err
	}
	var pack packKey
	err = tx.QueryRow(ctx, "SELECT pack_id,pack_version FROM owned_packs WHERE owner_id=$1 AND id=$2 FOR UPDATE", m.owner, packID).
		Scan(&pack.ID, &pack.Version)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, packNotFound
	}
	if err != nil {
		return nil, err
	}
	var existing json.RawMessage
	err = tx.QueryRow(ctx, `SELECT e.receipt FROM pack_openings o JOIN collection_events e ON e.id=o.event_id AND e.owner_id=o.owner_id
		WHERE o.owner_id=$1 AND o.pack_id=$2`, m.owner, packID).Scan(&existing)
	if err == nil {
		return existing, saveRecoveryReceipt(r, tx, m.owner, key, operation, digest, existing, "openingId")
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	limits, err := s.plantCapacity(ctx, tx, m.owner)
	if err != nil {
		return nil, err
	}
	if limits["ownedPlants"] >= limits["plantLimit"] {
		return nil, plantCapacityFull
	}
	definition, total, err := s.packForMutation(r, tx, pack)
	if err != nil {
		return nil, err
	}
	rarity, outcome, err := choosePack(definition, total, securePackRoll)
	if err != nil {
		return nil, err
	}
	plant, opening := uuid.New(), uuid.New()
	expedition, err := expeditionAt(ctx, tx, m.owner, m.at)
	if errors.Is(err, expeditionUnavailable) {
		return nil, &apiError{503, "pack_progress_unavailable", "Pack opening progress is unavailable"}
	}
	if err != nil {
		return nil, err
	}
	presentation, err := awardPackPlant(ctx, tx, m, packID, plant, outcome)
	if err != nil {
		return nil, err
	}
	wallet, err := changeCommerceWallet(ctx, tx, m.owner, 0)
	if err != nil {
		return nil, err
	}
	limits["unopenedPacks"]--
	limits["ownedPlants"]++
	limits["storedPlants"]++
	receipt := map[string]any{"requestId": key, "openingId": opening, "ownedPackId": packID, "packId": pack.ID,
		"packVersion": pack.Version, "rarity": rarity, "openedAt": m.at, "inventoryBaseStateVersion": m.baseState,
		"gardenStateVersion": m.baseState + 1, "plant": presentation, "capacity": limits}
	wallet.addTo(receipt)
	if err := m.saveEvent(ctx, tx, receipt, 0, 0); err != nil {
		return nil, err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pack_openings (id,owner_id,pack_id,event_id,plant_id,rarity,opened_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7)`, opening, m.owner, packID, m.event, plant, rarity, m.at); err != nil {
		return nil, err
	}
	if expedition != nil {
		if err := setExpeditionProgress(ctx, tx, *expedition, nil, m.at, []expeditionUpdate{expeditionContribution("packs_opened_3", opening)}); err != nil {
			return nil, err
		}
	}
	return receipt, saveRecoveryReceipt(r, tx, m.owner, key, operation, digest, receipt, "openingId")
}

func (s *Server) packForMutation(r *http.Request, tx pgx.Tx, key packKey) (packDefinition, int, error) {
	ctx := r.Context()
	entry, err := s.readPack(ctx, tx, key, true)
	if err != nil {
		return packDefinition{}, 0, err
	}
	var valid bool
	if err := tx.QueryRow(ctx, packDependenciesSQL, key.ID, key.Version).Scan(&valid); err != nil {
		return packDefinition{}, 0, err
	}
	if !valid {
		return packDefinition{}, 0, invalidPack
	}
	if key.Version >= 20 && (key.ID == "woodland" || key.ID == "select-woodland" || key.ID == "premium-woodland") &&
		r.Header.Get("X-Forest-Woodland") != "1" {
		return packDefinition{}, 0, &apiError{426, "woodland_client_update_required", "Update the app to use Woodland packs"}
	}
	return entry.definition, entry.total, nil
}

// Join dependencies inside PostgreSQL and return a single validation result.
const packDependenciesSQL = `
WITH pools AS (
	SELECT p FROM pack_definitions d CROSS JOIN jsonb_array_elements(d.definition->'rarities') p
	WHERE (d.id,d.version)=($1,$2)
), members AS (
	SELECT o->>'speciesId' AS species,o->>'variantId' AS variant,o->'profiles' AS profiles
	FROM pools CROSS JOIN jsonb_array_elements(p->'outcomes') o
	UNION ALL
	SELECT s->>'speciesId',v->>'variantId',v->'profiles'
	FROM pools CROSS JOIN jsonb_array_elements(p->'species') s CROSS JOIN jsonb_array_elements(s->'variants') v
)
SELECT NOT EXISTS (
	SELECT 1 FROM members m
	LEFT JOIN plant_variants v ON (v.species_id,v.variant_id)=(m.species,m.variant)
	LEFT JOIN growth_profiles g ON (g.id,g.version)=(m.profiles#>>'{growth,id}',(m.profiles#>>'{growth,version}')::int)
	LEFT JOIN growth_rule_profiles b ON (b.id,b.version)=(m.profiles#>>'{behaviour,id}',(m.profiles#>>'{behaviour,version}')::int)
	LEFT JOIN attraction_profiles a ON (a.id,a.version)=(m.profiles#>>'{attraction,id}',(m.profiles#>>'{attraction,version}')::int)
	WHERE v.species_id IS NULL OR g.id IS NULL OR b.id IS NULL OR a.id IS NULL OR length(v.asset_catalog_version)=0
		OR NOT starts_with(v.asset_catalog_key,'assets/'||m.species||'/v1/') OR right(v.asset_catalog_key,5)<>'.json'
		OR strpos(v.asset_catalog_key,chr(92))>0 OR '..'=ANY(string_to_array(v.asset_catalog_key,'/'))
		OR (SELECT count(*) FROM plant_stages s WHERE (s.species_id,s.variant_id)=(m.species,m.variant)
			AND s.stage IN ('sprout','seedling','young','adult')
			AND starts_with(s.model_key,'assets/'||m.species||'/v1/') AND right(s.model_key,5)='.usdz'
			AND strpos(s.model_key,chr(92))=0 AND NOT '..'=ANY(string_to_array(s.model_key,'/'))
			AND starts_with(s.thumbnail_key,'assets/'||m.species||'/v1/') AND right(s.thumbnail_key,4)='.png'
			AND strpos(s.thumbnail_key,chr(92))=0 AND NOT '..'=ANY(string_to_array(s.thumbnail_key,'/')) )<>4
)`

func awardPackPlant(ctx context.Context, tx pgx.Tx, m packMutation, pack, plant uuid.UUID, o packOutcome) (json.RawMessage, error) {
	var milestone, valid bool
	err := tx.QueryRow(ctx, `WITH policy AS (SELECT (jsonb_typeof(definition->'quests')='array' AND jsonb_typeof(definition->'species')='object') IS TRUE AS valid
		FROM milestone_policies WHERE active AND effective_at<=$1
	) SELECT
		EXISTS(SELECT 1 FROM policy),COALESCE((SELECT valid FROM policy),true)`, m.at).
		Scan(&milestone, &valid)
	if err != nil {
		return nil, err
	}
	if !valid {
		return nil, &apiError{503, "pack_progress_unavailable", "Pack opening progress is unavailable"}
	}
	p := o.Profiles
	if _, err := tx.Exec(ctx, `INSERT INTO owned_plants (id,owner_id,species_id,variant_id,
		growth_profile_id,growth_profile_version,behaviour_profile_id,behaviour_profile_version,
		attraction_profile_id,attraction_profile_version,acquisition_source,acquisition_reference,clearance_radius)
		SELECT $1,$2,s.id,$4,$5,$6,$7,$8,$9,$10,'pack_open',$11,
			COALESCE($12::numeric,(s.properties->>'legacyClearanceRadius')::numeric,s.clearance_radius)
		FROM plant_species s WHERE s.id=$3`, plant, m.owner, o.SpeciesID, o.VariantID,
		p.Growth.ID, p.Growth.Version, p.Behaviour.ID, p.Behaviour.Version, p.Attraction.ID, p.Attraction.Version,
		pack.String(), radiusParameter(o.ClearanceRadius)); err != nil {
		return nil, err
	}
	var discovered, versioned bool
	err = tx.QueryRow(ctx, `WITH fresh AS (
		INSERT INTO catalog_stage_discoveries (owner_id,species_id,variant_id,stage,recorded_at)
		VALUES ($1,$2,$3,'sprout',$4) ON CONFLICT DO NOTHING RETURNING 1
	), advanced AS (
		UPDATE catalog_discovery_state SET version=version+1
		WHERE owner_id=$1 AND version<9223372036854775807 AND EXISTS (SELECT 1 FROM fresh) RETURNING 1
	) SELECT EXISTS (SELECT 1 FROM fresh),EXISTS (SELECT 1 FROM advanced)`, m.owner, o.SpeciesID, o.VariantID, m.at).
		Scan(&discovered, &versioned)
	if err != nil {
		return nil, err
	}
	if discovered && !versioned {
		var state bool
		if err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM catalog_discovery_state WHERE owner_id=$1)", m.owner).Scan(&state); err != nil {
			return nil, err
		}
		if !state {
			return nil, &apiError{503, "discovery_not_ready", "Catalog discovery requires a database upgrade"}
		}
		return nil, &apiError{503, "counter_exhausted", "Discovery version requires maintenance"}
	}
	if discovered && milestone {
		if err := refreshMilestoneEntitlements(ctx, tx, m.owner, m.at); err != nil {
			return nil, err
		}
	}
	if _, err := tx.Exec(ctx, "UPDATE gardens SET state_version=state_version+1 WHERE owner_id=$1", m.owner); err != nil {
		return nil, err
	}
	var presentation json.RawMessage
	err = tx.QueryRow(ctx, plantQuery("p.owner_id=$1 AND p.id=$2"), m.owner, plant).Scan(&presentation)
	return presentation, err
}

func radiusParameter(radius json.RawMessage) any {
	if len(radius) == 0 || string(radius) == "null" {
		return nil
	}
	return json.Number(radius)
}
