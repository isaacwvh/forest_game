package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var shopPreparing = &apiError{503, "shop_preparing", "Shop is preparing. Please retry shortly"}

type ownedPack struct {
	ID       uuid.UUID `json:"ownedPackId"`
	PackID   string    `json:"packId"`
	Version  int       `json:"version"`
	Acquired time.Time `json:"acquiredAt"`
}

func (s *Server) collection(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	view := r.URL.Query().Get("view")
	if !r.URL.Query().Has("view") {
		view = "full"
	}
	if view != "full" && view != "shop" && view != "packs" && view != "home" {
		return nil, invalid
	}
	ctx := r.Context()
	shopping := view == "full" || view == "shop"
	if shopping {
		if _, err := lookupProfile(ctx, tx, id, false); err != nil {
			return nil, err
		}
		status, err := prepareShop(ctx, tx, false)
		if err != nil {
			return nil, err
		}
		if status == "catching_up" {
			return committedProblem{shopPreparing}, nil
		}
	}
	user, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	catalog, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	wallet, err := readCommerceWallet(ctx, tx, user.ID)
	if err != nil {
		return nil, err
	}
	capacity, err := s.plantCapacity(ctx, tx, user.ID)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"catalogVersion": catalog.Version, "capacity": capacity, "offers": []any{}}
	wallet.addTo(result)
	if view == "home" || view == "full" {
		milestones, err := s.collectionMilestones(r, tx, user.ID, catalog.Version)
		if err != nil {
			return nil, err
		}
		result["milestones"] = milestones
	}
	if !shopping {
		return result, nil
	}
	now, rotation, err := currentShop(r, tx)
	if err != nil {
		return nil, err
	}
	packs, err := s.packOffers(ctx, tx)
	if err != nil {
		return nil, err
	}
	items, err := currentItemOffers(ctx, tx, user.ID, now, rotation != nil)
	if err != nil {
		return nil, err
	}
	itemCapacity, err := readItemCapacity(ctx, tx, user.ID)
	if err != nil {
		return nil, err
	}
	result["offers"], result["shop"], result["itemOffers"], result["itemCapacity"] = packs, rotation, items, itemCapacity
	return result, nil
}

func legacyMilestones(ctx context.Context, tx pgx.Tx, owner, version string) ([]map[string]any, error) {
	result := make([]map[string]any, 0)
	if version != "launch-balance-v1" && version != "launch-visitors-v2" && version != "woodland-v1" {
		return result, nil
	}
	var movement, seedling, maturity bool
	var hostedActive, hostedOffline int64
	var claims []string
	err := tx.QueryRow(ctx, `SELECT
		COALESCE(p.activity_steps>0 OR EXISTS (
			SELECT 1 FROM jsonb_each_text(p.activity_metrics) m
			WHERE split_part(m.value,'/',1)::numeric>0), false),
		p.first_seedling_at IS NOT NULL, COALESCE(p.first_maturity_count>0,false),
		COALESCE(w.hosted_active,0), COALESCE(w.hosted_offline,0),
		ARRAY(SELECT milestone_id FROM milestone_claims WHERE owner_id=$1)
		FROM (SELECT $1::uuid AS id) a
		LEFT JOIN player_progress p ON p.owner_id=a.id
		LEFT JOIN visitor_wallets w ON w.owner_id=a.id`, owner).
		Scan(&movement, &seedling, &maturity, &hostedActive, &hostedOffline, &claims)
	if err != nil {
		return nil, err
	}
	claimed := make(map[string]bool, len(claims))
	for _, key := range claims {
		claimed[key] = true
	}
	scale := int64(10)
	if version == "launch-balance-v1" {
		scale = 1
	}
	for _, m := range []struct {
		key, title, description string
		reward                  int64
		eligible                bool
	}{
		{"first_movement", "First movement", "Sync your first eligible movement.", 30, movement},
		{"first_hosted", "A first guest", "Welcome or collect your first visitor.", 30, hostedActive > 0 || hostedOffline > 0},
		{"three_hosted", "A growing gathering", "Host three visitors in total.", 60, hostedActive >= 3 || hostedOffline >= 3 || hostedActive+hostedOffline >= 3},
		{"first_seedling", "Taking root", "Grow your first seedling through activity.", 30, seedling},
		{"first_maturity", "A mature garden begins", "Grow your first adult through activity.", 90, maturity},
	} {
		result = append(result, map[string]any{"milestoneId": m.key, "title": m.title, "description": m.description,
			"rewardTokens": numberString(m.reward * scale), "eligible": m.eligible, "claimed": claimed[m.key]})
	}
	return result, nil
}

func currentShop(r *http.Request, tx pgx.Tx) (time.Time, map[string]any, error) {
	var now time.Time
	var rotating bool
	var date *string
	var starts, ends *time.Time
	err := tx.QueryRow(r.Context(), `WITH boundary AS (SELECT clock_timestamp() AS at)
		SELECT at, EXISTS (SELECT 1 FROM shop_releases WHERE effective_week<=date_trunc('week',at AT TIME ZONE 'UTC')::date),
		d.shop_date::text,d.starts_at,d.ends_at FROM boundary
		LEFT JOIN shop_days d ON d.shop_date=(at AT TIME ZONE 'UTC')::date AND d.starts_at<=at AND d.ends_at>at`).
		Scan(&now, &rotating, &date, &starts, &ends)
	if err != nil || !rotating {
		return now, nil, err
	}
	if r.Header.Get("X-Forest-Item-Rotations") != "1" {
		return now, nil, itemContentUpdate
	}
	if date == nil {
		return now, nil, shopPreparing
	}
	return now, map[string]any{"serverNow": now, "shopTimezone": "UTC", "rotationId": *date, "startsAt": *starts, "endsAt": *ends}, nil
}

func (s *Server) packOffers(ctx context.Context, tx pgx.Tx) ([]map[string]any, error) {
	type offer struct {
		id, currency string
		version      int
		pack         packKey
		cost         int64
	}
	offers := make([]offer, 0)
	rows, err := tx.Query(ctx, `SELECT id,version,pack_id,pack_version,token_cost,currency
		FROM exchange_offers WHERE active ORDER BY id COLLATE "C",version`)
	if err != nil {
		return nil, err
	}
	for rows.Next() {
		var o offer
		if err := rows.Scan(&o.id, &o.version, &o.pack.ID, &o.pack.Version, &o.cost, &o.currency); err != nil {
			rows.Close()
			return nil, err
		}
		offers = append(offers, o)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	result := make([]map[string]any, 0, len(offers))
	for _, o := range offers {
		pack, err := s.packPresentation(ctx, tx, o.pack, true)
		if err != nil {
			return nil, err
		}
		result = append(result, map[string]any{"offerId": o.id, "offerVersion": o.version,
			"tokenCost": numberString(o.cost), "currency": o.currency, "pack": pack})
	}
	return result, nil
}

func currentItemOffers(ctx context.Context, tx pgx.Tx, owner string, at time.Time, rotating bool) ([]map[string]any, error) {
	rows, err := tx.Query(ctx, `SELECT o.id,o.version,o.token_cost,d.id,d.version,d.display_name,
		d.description,d.rarity,d.asset_version,d.model_key,d.thumbnail_key,w.starts_at,w.ends_at,w.slot,
		CASE WHEN w.purchase_limit IS NOT NULL THEN GREATEST(0,w.purchase_limit-COALESCE(a.purchased,0)) END,
		COALESCE(p.id,''),COALESCE(p.version,0),p.rules
		FROM item_shop_offers o JOIN item_definitions d ON (d.id,d.version)=(o.item_id,o.item_version)
		LEFT JOIN shop_offer_windows w ON (w.offer_id,w.offer_version)=(o.id,o.version)
		LEFT JOIN shop_allowances a ON a.owner_id=$1 AND (a.offer_id,a.offer_version)=(o.id,o.version)
		LEFT JOIN item_skill_bindings b ON (b.item_id,b.item_version)=(d.id,d.version)
		LEFT JOIN item_skill_profiles p ON (p.id,p.version)=(b.profile_id,b.profile_version)
		WHERE o.active AND (($3::bool AND w.starts_at<=$2 AND w.ends_at>$2) OR (NOT $3::bool AND w.offer_id IS NULL))
		ORDER BY o.id COLLATE "C",o.version`, owner, at, rotating)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := make([]map[string]any, 0)
	for rows.Next() {
		var offer, item, name, description, rarity, assets, model, thumbnail, profile string
		var offerVersion, itemVersion, skillVersion int
		var cost int64
		var starts, ends *time.Time
		var slot *string
		var remaining *int
		var rules json.RawMessage
		err := rows.Scan(&offer, &offerVersion, &cost, &item, &itemVersion, &name, &description, &rarity,
			&assets, &model, &thumbnail, &starts, &ends, &slot, &remaining, &profile, &skillVersion, &rules)
		if err != nil {
			return nil, err
		}
		skills, _, err := itemSkillPresentation(profile, skillVersion, rules)
		if err != nil {
			return nil, err
		}
		entry := map[string]any{"offerId": offer, "offerVersion": offerVersion, "tokenCost": numberString(cost),
			"itemId": item, "definitionVersion": itemVersion, "displayName": name, "description": description,
			"rarity": rarity, "assetVersion": assets, "modelKey": model, "thumbnailKey": thumbnail, "gardenSkills": skills}
		if starts != nil {
			entry["startsAt"], entry["endsAt"], entry["slot"], entry["remainingAllowance"] = *starts, *ends, *slot, remaining
		}
		result = append(result, entry)
	}
	return result, rows.Err()
}

func packPage(openings bool) operation {
	return func(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
		limit, after, err := parsePage(r, 30, 100)
		if err != nil {
			return nil, err
		}
		latest := false
		if openings && r.URL.Query().Has("latest") {
			switch strings.ToLower(r.URL.Query().Get("latest")) {
			case "1", "true", "t", "on", "yes", "y":
				latest = true
			case "0", "false", "f", "off", "no", "n":
			default:
				return nil, invalid
			}
		}
		ctx := r.Context()
		user, err := lookupProfile(ctx, tx, id, false)
		if err != nil {
			return nil, err
		}
		var cursorTime *time.Time
		if after != nil {
			query := "SELECT acquired_at FROM owned_packs WHERE owner_id=$1 AND id=$2"
			message := "Refresh the pack list"
			if openings {
				query = "SELECT opened_at FROM pack_openings WHERE owner_id=$1 AND id=$2"
				message = "Refresh the opening history"
			}
			if err := tx.QueryRow(ctx, query, user.ID, after).Scan(&cursorTime); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					return nil, &apiError{400, "invalid_cursor", message}
				}
				return nil, err
			}
		}
		if openings {
			return openingPage(ctx, tx, user.ID, limit, after, cursorTime, latest)
		}
		rows, err := tx.Query(ctx, `SELECT p.id,p.pack_id,p.pack_version,p.acquired_at FROM owned_packs p
			WHERE p.owner_id=$1 AND ($2::timestamptz IS NULL OR (p.acquired_at,p.id)>($2,$3))
			AND NOT EXISTS (SELECT 1 FROM pack_openings o WHERE o.pack_id=p.id)
			ORDER BY p.acquired_at,p.id LIMIT $4`, user.ID, cursorTime, after, limit+1)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		packs := make([]ownedPack, 0)
		for rows.Next() {
			var p ownedPack
			if err := rows.Scan(&p.ID, &p.PackID, &p.Version, &p.Acquired); err != nil {
				return nil, err
			}
			packs = append(packs, p)
		}
		var next *uuid.UUID
		if len(packs) > limit {
			packs = packs[:limit]
			next = &packs[limit-1].ID
		}
		return map[string]any{"packs": packs, "nextCursor": next}, rows.Err()
	}
}

func openingPage(ctx context.Context, tx pgx.Tx, owner string, limit int, after *uuid.UUID, at *time.Time, latest bool) (any, error) {
	fetch := limit + 1
	if latest {
		fetch = 1
	}
	rows, err := tx.Query(ctx, `SELECT o.id,e.receipt FROM pack_openings o JOIN collection_events e ON e.id=o.event_id AND e.owner_id=o.owner_id
		WHERE o.owner_id=$1 AND ($2::timestamptz IS NULL OR (o.opened_at,o.id)<($2,$3))
		ORDER BY o.opened_at DESC,o.id DESC LIMIT $4`, owner, at, after, fetch)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	receipts := make([]json.RawMessage, 0)
	var last, next *uuid.UUID
	for rows.Next() {
		var id uuid.UUID
		var receipt json.RawMessage
		if err := rows.Scan(&id, &receipt); err != nil {
			return nil, err
		}
		if len(receipts) == limit {
			next = last
			break
		}
		receipts = append(receipts, receipt)
		last = &id
	}
	return map[string]any{"openings": receipts, "nextCursor": next}, rows.Err()
}
