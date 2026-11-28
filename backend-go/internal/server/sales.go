package server

import (
	"context"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"regexp"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type valuation struct {
	Amount  int64
	Version string
	Growth  string
	Wire    map[string]any
}

var saleAmountFormat = regexp.MustCompile(`^[0-9]{1,19}$`)

func itemQuote(ctx context.Context, tx pgx.Tx, owner string, item uuid.UUID, forSale bool) (valuation, error) {
	var offer valuation
	var version *string
	var value *int64
	var bp *int
	var itemID string
	var itemVersion int
	var placed bool
	err := tx.QueryRow(ctx, `SELECT i.item_id,i.item_version,COALESCE(v.valuation_version,d.valuation_version),
		COALESCE(v.token_value,d.token_value),COALESCE(v.resale_basis_points,d.resale_basis_points),
		EXISTS (SELECT 1 FROM item_placements WHERE item_id=o.id)
	FROM owned_items o JOIN item_identities i ON i.id=o.id
	LEFT JOIN item_valuations v ON v.owned_item_id=o.id
	LEFT JOIN item_value_definitions d ON (d.item_id,d.item_version)=(i.item_id,i.item_version)
	WHERE o.owner_id=$1 AND o.id=$2`, owner, item).Scan(&itemID, &itemVersion, &version, &value, &bp, &placed)
	if errors.Is(err, pgx.ErrNoRows) {
		return offer, &apiError{404, "item_not_found", "Item not found"}
	}
	if err != nil {
		return offer, err
	}
	if value == nil {
		legacy := approvedExpeditionItemValue(itemID, itemVersion)
		if legacy > 0 {
			rule, basis := "item-resale-v1", 2500
			version, value, bp = &rule, &legacy, &basis
		}
	}
	if version == nil || value == nil || bp == nil {
		return offer, &apiError{409, "item_sale_unavailable", "This item does not have a published resale value"}
	}
	if forSale && placed {
		return offer, &apiError{409, "item_is_placed", "Store this item before selling it"}
	}
	// PostgreSQL enforces a 2500-basis-point valuation on both source tables.
	offer.Amount, offer.Version = *value/4, *version
	offer.Wire = map[string]any{"ownedItemId": item, "valuationVersion": *version, "tokenValue": numberString(*value),
		"resaleBasisPoints": *bp, "tokens": numberString(offer.Amount)}
	return offer, nil
}

func plantQuote(ctx context.Context, tx pgx.Tx, owner string, plant uuid.UUID, forSale bool) (valuation, error) {
	var offer valuation
	var source, version string
	var rarity *string
	var bp *int64
	var growth, adult int64
	var placed bool
	err := tx.QueryRow(ctx, `SELECT i.acquisition_source,i.valuation_version,i.valuation_rarity,i.variant_basis_points,
		p.growth_micro_units,(g.thresholds->>'adult')::bigint,
		EXISTS (SELECT 1 FROM garden_placements WHERE plant_id=p.id)
	FROM owned_plants p JOIN plant_identities i ON i.id=p.id AND i.owner_id=p.owner_id
	JOIN growth_profiles g ON (g.id,g.version)=(p.growth_profile_id,p.growth_profile_version)
	WHERE p.owner_id=$1 AND p.id=$2`, owner, plant).Scan(&source, &version, &rarity, &bp, &growth, &adult, &placed)
	if errors.Is(err, pgx.ErrNoRows) {
		return offer, &apiError{404, "plant_not_found", "Owned plant not found"}
	}
	if err != nil {
		return offer, err
	}
	if forSale && placed {
		return offer, &apiError{409, "plant_is_planted", "Store this plant before selling it"}
	}
	if source == "starter" {
		return offer, &apiError{409, "starter_protected", "Your original starter stays with your garden"}
	}
	var base int64
	if rarity != nil {
		base = map[string]int64{"common": 240, "rare": 480, "epic": 720, "legendary": 960}[*rarity]
	}
	if base == 0 || version != "plant-resale-v1" || bp == nil {
		return offer, &apiError{409, "sale_unavailable", "This plant does not have an approved resale value"}
	}
	credit, err := plantSalePrice(base, *bp, growth, adult)
	if err != nil {
		return offer, err
	}
	offer.Amount, offer.Version, offer.Growth = credit, version, numberString(growth)
	offer.Wire = map[string]any{"plantId": plant, "valuationVersion": version, "rarity": *rarity, "rarityBase": numberString(base),
		"variantBasisPoints": *bp, "growthMicroUnits": offer.Growth, "adultWaterMicroUnits": numberString(adult), "tokens": numberString(credit)}
	return offer, nil
}

func plantSalePrice(base, basis, growth, adult int64) (int64, error) {
	if adult <= 0 {
		return 0, &apiError{503, "sale_unavailable", "This plant's growth profile is unavailable"}
	}
	sum := new(big.Int).Add(big.NewInt(adult), big.NewInt(min(max(growth, 0), adult)))
	numerator := sum.Mul(sum, big.NewInt(base*basis))
	denominator := new(big.Int).Mul(big.NewInt(40000), big.NewInt(adult))
	return numerator.Quo(numerator, denominator).Int64(), nil
}

type saleKind struct {
	operation, wireID, lookup, remove, insert string
	quote                                     func(context.Context, pgx.Tx, string, uuid.UUID, bool) (valuation, error)
}

var sellItemKind = saleKind{
	"item_sell", "ownedItemId", `SELECT payload_hash,receipt FROM item_sales WHERE owner_id=$1 AND request_id=$2`,
	`DELETE FROM owned_items WHERE owner_id=$1 AND id=$2`,
	`INSERT INTO item_sales (id,owner_id,owned_item_id,request_id,payload_hash,tokens,receipt,sold_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8)`, itemQuote,
}
var sellPlantKind = saleKind{
	"plant_sell", "plantId", `SELECT payload_hash,receipt FROM plant_sales WHERE owner_id=$1 AND request_id=$2`,
	`DELETE FROM owned_plants WHERE owner_id=$1 AND id=$2`,
	`INSERT INTO plant_sales (id,owner_id,plant_id,request_id,payload_hash,tokens,receipt,sold_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8)`, plantQuote,
}

func saleQuote(kind saleKind) operation {
	return func(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
		target, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			return nil, invalid
		}
		user, err := lookupProfile(r.Context(), tx, id, true)
		if err != nil {
			return nil, err
		}
		current, err := kind.quote(r.Context(), tx, user.ID, target, false)
		return current.Wire, err
	}
}

func (s *Server) sellOwned(kind saleKind) operation {
	return func(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
		target, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			return nil, invalid
		}
		isPlant := kind.operation == "plant_sell"
		fields := []string{"requestId", "valuationVersion", "expectedTokens"}
		if isPlant {
			fields = append(fields, "expectedGrowthMicroUnits")
		}
		body, err := readBody(r, fields...)
		if err != nil {
			return nil, err
		}
		key, err := requestID(body)
		if err != nil {
			return nil, err
		}
		version, err := stringField(body, "valuationVersion")
		if err != nil || version == "" || len(version) > 100 {
			return nil, invalid
		}
		expected, err := stringField(body, "expectedTokens")
		if err != nil || !saleAmountFormat.MatchString(expected) {
			return nil, invalid
		}
		values := map[string]any{"valuationVersion": version, "expectedTokens": expected}
		var growth string
		if isPlant {
			growth, err = stringField(body, "expectedGrowthMicroUnits")
			if err != nil || !saleAmountFormat.MatchString(growth) {
				return nil, invalid
			}
			values["expectedGrowthMicroUnits"] = growth
		}
		digest, err := requestDigest(kind.operation+":"+target.String(), values)
		if err != nil {
			return nil, err
		}
		ctx := r.Context()
		user, err := lookupProfile(ctx, tx, id, true)
		if err != nil {
			return nil, err
		}
		if data, err := commerceReplay(ctx, tx, user.ID, key, kind.operation, digest, kind.lookup, r.Header.Get("X-Forest-Recovery") == "1"); err != nil || data != nil {
			return data, err
		}
		if _, err := lockCommerceGarden(ctx, tx, user.ID); err != nil {
			return nil, err
		}
		if !isPlant && r.Header.Get("X-Forest-Item-Commerce") != "1" {
			return nil, itemCommerceUpdate
		}
		current, err := kind.quote(ctx, tx, user.ID, target, true)
		if err != nil {
			return nil, err
		}
		if current.Version != version || numberString(current.Amount) != expected || isPlant && current.Growth != growth {
			return nil, &apiError{409, "stale_sale_quote", "The sale price changed. Review a fresh quote"}
		}
		var now time.Time
		if err := tx.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&now); err != nil {
			return nil, err
		}
		if err := throttle(ctx, tx, user.ID, now); err != nil {
			return nil, err
		}
		wallet, err := changeCommerceWallet(ctx, tx, user.ID, current.Amount)
		if err != nil {
			return nil, err
		}
		var batch pgx.Batch
		batch.Queue(kind.remove, user.ID, target)
		batch.Queue("UPDATE gardens SET state_version=state_version+1 WHERE owner_id=$1", user.ID)
		if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
			return nil, err
		}
		sale := uuid.New()
		result := map[string]any{"requestId": key, "saleId": sale, kind.wireID: target,
			"tokensEarned": expected, "soldAt": now.UTC(), "valuation": current.Wire}
		wallet.addTo(result)
		if isPlant {
			result["capacity"], err = s.plantCapacity(ctx, tx, user.ID)
		} else {
			result["itemCapacity"], err = readItemCapacity(ctx, tx, user.ID)
		}
		if err != nil {
			return nil, err
		}
		data, err := json.Marshal(result)
		if err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, kind.insert, sale, user.ID, target, key, digest, current.Amount, data, now); err != nil {
			return nil, err
		}
		return result, saveRecoveryReceipt(r, tx, user.ID, key, kind.operation, digest, result, "saleId")
	}
}
