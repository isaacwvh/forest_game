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

var (
	itemContentUpdate  = &apiError{426, "item_content_update_required", "Update the app for the new garden items"}
	itemCommerceUpdate = &apiError{426, "item_commerce_client_update_required", "Update the app to buy or sell items"}
	staleOffer         = &apiError{409, "stale_offer", "Refresh Shop to see the current offer"}
	amountOverflow     = &apiError{409, "amount_overflow", "The requested amount exceeds the supported limit"}
)

type commerceWallet struct {
	Tokens  int64
	Gems    int64
	Version int64
}

func (w commerceWallet) addTo(receipt map[string]any) {
	receipt["tokenBalance"], receipt["gemBalance"], receipt["economyVersion"] = numberString(w.Tokens), numberString(w.Gems), w.Version
}

func lockCommerceGarden(ctx context.Context, tx pgx.Tx, owner string) (int64, error) {
	var version int64
	err := tx.QueryRow(ctx, "SELECT state_version FROM gardens WHERE owner_id=$1 FOR UPDATE", owner).Scan(&version)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, &apiError{503, "garden_unavailable", "Account garden is unavailable"}
	}
	if err != nil {
		return 0, err
	}
	if version == math.MaxInt64 {
		return 0, amountOverflow
	}
	return version, nil
}

func readCommerceWallet(ctx context.Context, tx pgx.Tx, owner string) (commerceWallet, error) {
	var wallet commerceWallet
	err := tx.QueryRow(ctx, "SELECT tokens,gems,economy_version FROM visitor_wallets WHERE owner_id=$1", owner).
		Scan(&wallet.Tokens, &wallet.Gems, &wallet.Version)
	if errors.Is(err, pgx.ErrNoRows) {
		_, err = tx.Exec(ctx, "INSERT INTO visitor_wallets (owner_id,tokens,hosted_active,hosted_offline) VALUES ($1,0,0,0)", owner)
	}
	return wallet, err
}

func changeCommerceWallet(ctx context.Context, tx pgx.Tx, owner string, delta int64) (commerceWallet, error) {
	return updateCommerceWallet(ctx, tx, owner, delta, 0,
		&apiError{409, "insufficient_tokens", "You need more tokens for this item"})
}

func updateCommerceWallet(ctx context.Context, tx pgx.Tx, owner string, tokens, gems int64, insufficientTokens *apiError) (commerceWallet, error) {
	wallet, err := readCommerceWallet(ctx, tx, owner)
	if err != nil {
		return wallet, err
	}
	if tokens < 0 && wallet.Tokens < -tokens {
		return wallet, insufficientTokens
	}
	if gems < 0 && wallet.Gems < -gems {
		return wallet, &apiError{409, "insufficient_gems", "You need more gems for this pack"}
	}
	if (tokens > 0 && wallet.Tokens > math.MaxInt64-tokens) ||
		(gems > 0 && wallet.Gems > math.MaxInt64-gems) || wallet.Version == math.MaxInt64 {
		return wallet, amountOverflow
	}
	wallet.Tokens += tokens
	wallet.Gems += gems
	wallet.Version++
	_, err = tx.Exec(ctx, "UPDATE visitor_wallets SET tokens=$2,gems=$3,economy_version=$4 WHERE owner_id=$1", owner, wallet.Tokens, wallet.Gems, wallet.Version)
	return wallet, err
}

// Check both the request journal and the permanent economic receipt. Stored
// completion metadata must never be returned as though it were a full receipt.
func commerceReplay(ctx context.Context, tx pgx.Tx, owner string, key uuid.UUID, kind, digest, durableSQL string, recovery bool) (json.RawMessage, error) {
	var op, old string
	var response json.RawMessage
	err := tx.QueryRow(ctx, `SELECT operation,payload_hash,response FROM api_requests
		WHERE user_id=$1 AND request_id=$2`, owner, key).Scan(&op, &old, &response)
	journal := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	clash := &apiError{409, "idempotency_conflict", "Request ID was used for different input"}
	if journal {
		if op != kind || old != digest {
			return nil, clash
		}
		if response != nil {
			return response, nil
		}
		if !recovery && kind != "item_purchase" {
			return nil, &apiError{426, "recovery_client_update_required", "Update the app to recover this request"}
		}
	}
	err = tx.QueryRow(ctx, durableSQL, owner, key).Scan(&old, &response)
	if errors.Is(err, pgx.ErrNoRows) {
		if journal {
			return nil, &apiError{503, "recovery_unavailable", "The original receipt is unavailable"}
		}
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if old != digest {
		return nil, clash
	}
	return response, nil
}

type purchaseOffer struct {
	Item         string
	Version      int
	Cost         int64
	Active       bool
	Starts, Ends *time.Time
	Limit        *int
	Used         int
	Rotating     bool
}

func (s *Server) purchaseItem(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	body, err := readBody(r, "requestId", "offerId", "offerVersion", "quantity")
	if err != nil {
		return nil, err
	}
	key, err := requestID(body)
	if err != nil {
		return nil, err
	}
	offerID, err := stringField(body, "offerId")
	var version, quantity int
	if err != nil || len(offerID) < 1 || len(offerID) > 100 ||
		json.Unmarshal(body["offerVersion"], &version) != nil || version < 1 || version > math.MaxInt32 ||
		json.Unmarshal(body["quantity"], &quantity) != nil || quantity < 1 || quantity > 20 {
		return nil, invalid
	}
	const operation = "item_purchase"
	digest, err := requestDigest(operation, map[string]any{"offerId": offerID, "offerVersion": version, "quantity": quantity})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	user, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if saved, err := commerceReplay(ctx, tx, user.ID, key, operation, digest, `SELECT payload_hash,receipt
		FROM collection_events WHERE owner_id=$1 AND request_id=$2`, r.Header.Get("X-Forest-Recovery") == "1"); err != nil || saved != nil {
		return saved, err
	}
	base, err := lockCommerceGarden(ctx, tx, user.ID)
	if err != nil {
		return nil, err
	}
	if _, err := s.catalogueState(ctx, tx); err != nil {
		return nil, err
	}
	if r.Header.Get("X-Forest-Item-Commerce") != "1" {
		return nil, itemCommerceUpdate
	}

	var now time.Time
	var offer purchaseOffer
	err = tx.QueryRow(ctx, `WITH boundary AS (SELECT clock_timestamp() AS at)
	SELECT at,o.item_id,o.item_version,o.token_cost,o.active,w.starts_at,w.ends_at,w.purchase_limit,COALESCE(a.purchased,0),
		EXISTS (SELECT 1 FROM shop_releases WHERE effective_week<=date_trunc('week',at AT TIME ZONE 'UTC')::date)
	FROM item_shop_offers o CROSS JOIN boundary
	LEFT JOIN shop_offer_windows w ON (w.offer_id,w.offer_version)=(o.id,o.version)
	LEFT JOIN shop_allowances a ON a.owner_id=$1 AND (a.offer_id,a.offer_version)=(o.id,o.version)
	WHERE o.id=$2 AND o.version=$3`, user.ID, offerID, version).
		Scan(&now, &offer.Item, &offer.Version, &offer.Cost, &offer.Active, &offer.Starts, &offer.Ends, &offer.Limit, &offer.Used, &offer.Rotating)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, staleOffer
	}
	if err != nil {
		return nil, err
	}
	if !offer.Active || offer.Starts == nil && offer.Rotating {
		return nil, staleOffer
	}
	if offer.Starts != nil {
		if r.Header.Get("X-Forest-Item-Rotations") != "1" {
			return nil, itemContentUpdate
		}
		if now.Before(*offer.Starts) || offer.Ends == nil || !now.Before(*offer.Ends) {
			return nil, &apiError{409, "stale_offer", "This offer has expired. Refresh Shop"}
		}
	}
	if offer.Limit != nil && quantity > *offer.Limit-offer.Used {
		return nil, &apiError{409, "item_allowance_used", "This featured item has already been purchased"}
	}
	capacity, err := readItemCapacity(ctx, tx, user.ID)
	if err != nil {
		return nil, err
	}
	if capacity.Owned+quantity > capacity.Limit {
		return nil, &apiError{409, "item_capacity_full", "Item inventory full. Sell a stored item to make room."}
	}
	if offer.Cost > math.MaxInt64/int64(quantity) {
		return nil, amountOverflow
	}
	if err := throttle(ctx, tx, user.ID, now); err != nil {
		return nil, err
	}
	cost := offer.Cost * int64(quantity)
	wallet, err := changeCommerceWallet(ctx, tx, user.ID, -cost)
	if err != nil {
		return nil, err
	}
	purchase := uuid.New()
	ids := make([]uuid.UUID, quantity)
	for i := range ids {
		ids[i] = uuid.New()
	}
	var batch pgx.Batch
	batch.Queue(`INSERT INTO item_identities (id,owner_id,item_id,item_version,source,reference,ordinal)
		SELECT id,$1,$2,$3,'item_purchase',$4,(ordinal-1)::int FROM unnest($5::uuid[]) WITH ORDINALITY AS a(id,ordinal)`,
		user.ID, offer.Item, offer.Version, purchase.String(), ids)
	batch.Queue(`INSERT INTO item_valuations (owned_item_id,valuation_version,token_value,resale_basis_points)
		SELECT copy.id,v.valuation_version,$3,v.resale_basis_points FROM item_value_definitions v
		CROSS JOIN unnest($4::uuid[]) AS copy(id) WHERE (v.item_id,v.item_version)=($1,$2)`, offer.Item, offer.Version, offer.Cost, ids)
	batch.Queue("INSERT INTO owned_items (id,owner_id) SELECT id,$1 FROM unnest($2::uuid[]) AS copy(id)", user.ID, ids)
	batch.Queue("UPDATE gardens SET state_version=state_version+1 WHERE owner_id=$1", user.ID)
	var remaining *int
	if offer.Limit != nil {
		left := *offer.Limit - offer.Used - quantity
		remaining = &left
		batch.Queue(`INSERT INTO shop_allowances (owner_id,offer_id,offer_version,purchased) VALUES ($1,$2,$3,$4)
			ON CONFLICT (owner_id,offer_id,offer_version) DO UPDATE SET purchased=shop_allowances.purchased+EXCLUDED.purchased`, user.ID, offerID, version, quantity)
	}
	if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
		return nil, err
	}
	owned, err := readItems(ctx, tx, "o.owner_id=$1 AND o.id=ANY($2::uuid[]) ORDER BY o.id", user.ID, ids)
	if err != nil {
		return nil, err
	}
	capacity.Owned += quantity
	capacity.Stored += quantity
	receipt := map[string]any{"requestId": key, "purchaseId": purchase, "offerId": offerID, "offerVersion": version,
		"quantity": quantity, "tokensSpent": numberString(cost), "ownedItemIds": ids, "ownedItems": owned,
		"inventoryBaseStateVersion": base, "gardenStateVersion": base + 1, "remainingAllowance": remaining,
		"itemCapacity": capacity, "acceptedAt": now.UTC()}
	wallet.addTo(receipt)
	if _, err := tx.Exec(ctx, `INSERT INTO collection_events
			(id,owner_id,request_id,operation,payload_hash,token_delta,receipt,created_at)
			VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb,$8)`, purchase, user.ID, key, operation, digest, -cost, receipt, now); err != nil {
		return nil, err
	}
	return receipt, saveRecoveryReceipt(r, tx, user.ID, key, operation, digest, receipt, "purchaseId")
}
