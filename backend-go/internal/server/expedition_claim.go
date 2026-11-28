package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var expeditionRewardNotFound = &apiError{404, "expedition_reward_not_found", "Earn this reward before collecting it"}

type expeditionReward struct {
	Tokens  int64  `json:"tokens"`
	Gems    int64  `json:"gems"`
	Pack    string `json:"packId"`
	Item    string `json:"itemId"`
	Version int    `json:"version"`
}

func (s *Server) claimExpedition(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	if r.Header.Get("X-Forest-Expeditions") != "1" {
		return nil, expeditionClientUpdate
	}
	run, err := uuid.Parse(r.PathValue("run"))
	if err != nil {
		return nil, invalid
	}
	entitlement, err := uuid.Parse(r.PathValue("entitlement"))
	if err != nil {
		return nil, invalid
	}
	fields, err := readBody(r, "requestId")
	if err != nil {
		return nil, err
	}
	key, err := requestID(fields)
	if err != nil {
		return nil, err
	}
	operation := "expedition_claim:" + entitlement.String()
	digest, err := requestDigest(operation, map[string]any{})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	if saved, err := replayRecoverableMutation(r, tx, owner.ID, key, operation, digest); err != nil || saved != nil {
		if err != nil {
			return nil, err
		}
		return saved, checkExpeditionClaimReplay(saved, run)
	}
	var rewardKey string
	var reward expeditionReward
	var prior map[string]any
	err = tx.QueryRow(ctx, `SELECT e.reward_key,e.reward,c.receipt FROM expedition_entitlements e JOIN expedition_runs r ON r.id=e.run_id
		LEFT JOIN expedition_claims c ON c.entitlement_id=e.id
		WHERE e.id=$1 AND r.id=$2 AND r.owner_id=$3`, entitlement, run, owner.ID).Scan(&rewardKey, &reward, &prior)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, expeditionRewardNotFound
	}
	if err != nil {
		return nil, err
	}
	if prior != nil {
		prior["requestId"] = key.String()
		return prior, saveSmallRecoveryReceipt(r, tx, owner.ID, key, operation, digest, prior)
	}
	g, err := readGardenRecord(ctx, tx, owner.ID)
	if err != nil {
		return nil, err
	}
	if _, err := s.catalogueState(ctx, tx); err != nil {
		return nil, err
	}
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	m := packMutation{owner: owner.ID, request: key, event: uuid.New(), operation: operation, digest: digest, at: at}
	return s.grantExpeditionReward(r, tx, m, g, run, entitlement, rewardKey, reward)
}

func checkExpeditionClaimReplay(value any, run uuid.UUID) error {
	wire, err := json.Marshal(value)
	if err != nil {
		return err
	}
	var receipt struct {
		Run      uuid.UUID `json:"runId"`
		Recovery *struct {
			Outcome struct {
				Run uuid.UUID `json:"runId"`
			} `json:"outcome"`
		} `json:"recovery"`
	}
	if err := json.Unmarshal(wire, &receipt); err != nil {
		return err
	}
	actual := receipt.Run
	if receipt.Recovery != nil {
		actual = receipt.Recovery.Outcome.Run
	}
	if actual != run {
		return &apiError{409, "idempotency_conflict", "Claim belongs to another run"}
	}
	return nil
}

func (s *Server) grantExpeditionReward(r *http.Request, tx pgx.Tx, m packMutation, g gardenRecord,
	run, entitlement uuid.UUID, key string, reward expeditionReward) (map[string]any, error) {
	ctx := r.Context()
	if reward.Tokens < 0 || reward.Gems < 0 || ((reward.Item != "" || reward.Pack != "") && reward.Version < 1) {
		return nil, expeditionUnavailable
	}
	packs := []ownedPack{}
	ownedItems := []uuid.UUID{}
	if reward.Pack != "" {
		room, err := s.plantCapacity(ctx, tx, m.owner)
		if err != nil {
			return nil, err
		}
		if room["unopenedPacks"] >= room["packLimit"] {
			return nil, &apiError{409, "pack_capacity_exceeded", "Pack storage full. Open a pack, then retry."}
		}
		if _, err := s.readPack(ctx, tx, packKey{reward.Pack, reward.Version}, true); err != nil {
			return nil, err
		}
		packs = append(packs, ownedPack{ID: uuid.New(), PackID: reward.Pack, Version: reward.Version, Acquired: m.at})
	}
	if reward.Item != "" {
		id, err := grantExpeditionItem(ctx, tx, g, reward.Item, reward.Version, run.String()+"/"+key)
		if err != nil {
			return nil, err
		}
		ownedItems = append(ownedItems, id)
	}
	wallet, err := grantRewardWallet(ctx, tx, m.owner, reward.Tokens, reward.Gems)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": m.request, "runId": run, "entitlementId": entitlement, "rewardKey": key,
		"tokensEarned": numberString(reward.Tokens), "gemsEarned": numberString(reward.Gems),
		"packs": packs, "ownedItemIds": ownedItems, "claimedAt": m.at}
	wallet.addTo(result)
	if err := m.saveEvent(ctx, tx, result, 0, 0); err != nil {
		return nil, err
	}
	event := uuid.New()
	var batch pgx.Batch
	batch.Queue(`INSERT INTO visitor_reward_events(id,owner_id,kind,source_id,created_at,detail)
		VALUES($1,$2,'expedition',$3,$4,jsonb_build_object('tokens',$5::text,'gems',$6::text,'entitlementId',$3::uuid))`,
		event, m.owner, entitlement, m.at, numberString(reward.Tokens), numberString(reward.Gems))
	if reward.Tokens > 0 {
		batch.Queue("INSERT INTO visitor_wallet_entries(id,owner_id,event_id,amount,created_at) VALUES($1,$2,$3,$4,$5)",
			uuid.New(), m.owner, event, reward.Tokens, m.at)
	}
	if reward.Gems > 0 {
		batch.Queue("INSERT INTO expedition_bonus_grants(entitlement_id,owner_id,amount) VALUES($1,$2,$3)", entitlement, m.owner, reward.Gems)
	}
	for _, pack := range packs {
		batch.Queue("INSERT INTO owned_packs(id,owner_id,pack_id,pack_version,exchange_id,acquired_at) VALUES($1,$2,$3,$4,$5,$6)",
			pack.ID, m.owner, pack.PackID, pack.Version, m.event, m.at)
	}
	batch.Queue("INSERT INTO expedition_claims(entitlement_id,owner_id,receipt) VALUES($1,$2,$3::jsonb)", entitlement, m.owner, result)
	if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
		return nil, err
	}
	tag, err := tx.Exec(ctx, "UPDATE expedition_runs SET progress_version=progress_version+1 WHERE id=$1 AND progress_version<9223372036854775807", run)
	if err != nil {
		return nil, err
	}
	if tag.RowsAffected() != 1 {
		return nil, amountOverflow
	}
	return result, saveSmallRecoveryReceipt(r, tx, m.owner, m.request, m.operation, m.digest, result)
}

func grantExpeditionItem(ctx context.Context, tx pgx.Tx, g gardenRecord, item string, version int, reference string) (uuid.UUID, error) {
	var id uuid.UUID
	var oldItem string
	var oldVersion int
	err := tx.QueryRow(ctx, `SELECT id,item_id,item_version FROM item_identities
		WHERE owner_id=$1 AND source='expedition_reward' AND reference=$2 AND ordinal=0`, g.owner, reference).
		Scan(&id, &oldItem, &oldVersion)
	if err == nil {
		if oldItem != item || oldVersion != version {
			return uuid.Nil, &apiError{409, "item_grant_conflict", "Reward source was used for a different item grant"}
		}
		return id, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, err
	}
	var rule *string
	var value *int64
	var basis *int
	var owned int
	err = tx.QueryRow(ctx, `SELECT v.valuation_version,v.token_value,v.resale_basis_points,
		(SELECT count(*) FROM owned_items WHERE owner_id=$1)
		FROM item_definitions d LEFT JOIN item_value_definitions v ON (v.item_id,v.item_version)=(d.id,d.version)
		WHERE d.id=$2 AND d.version=$3`, g.owner, item, version).Scan(&rule, &value, &basis, &owned)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, &apiError{409, "item_unavailable", "Item is not published"}
	}
	if err != nil {
		return uuid.Nil, err
	}
	if owned >= itemLimit {
		return uuid.Nil, &apiError{409, "item_capacity_full", "Item inventory full. Make room before collecting this reward."}
	}
	if g.state == 9223372036854775807 {
		return uuid.Nil, &apiError{503, "version_exhausted", "Garden version requires maintenance"}
	}
	if value == nil {
		if fallback := approvedExpeditionItemValue(item, version); fallback > 0 {
			name, rate := "item-resale-v1", 2500
			rule, value, basis = &name, &fallback, &rate
		}
	}
	id = uuid.New()
	var batch pgx.Batch
	batch.Queue(`INSERT INTO item_identities(id,owner_id,item_id,item_version,source,reference,ordinal)
		VALUES($1,$2,$3,$4,'expedition_reward',$5,0)`, id, g.owner, item, version, reference)
	if value != nil {
		batch.Queue("INSERT INTO item_valuations(owned_item_id,valuation_version,token_value,resale_basis_points) VALUES($1,$2,$3,$4)",
			id, rule, value, basis)
	}
	batch.Queue("INSERT INTO owned_items(id,owner_id) VALUES($1,$2)", id, g.owner)
	batch.Queue("UPDATE gardens SET state_version=state_version+1 WHERE id=$1", g.id)
	return id, tx.SendBatch(ctx, &batch).Close()
}

func approvedExpeditionItemValue(item string, version int) int64 {
	if version != 1 {
		return 0
	}
	switch item {
	case "astronomers-satchel":
		return 500
	case "comet-basin":
		return 1250
	case "worldseed-orrery":
		return 5500
	default:
		return 0
	}
}
