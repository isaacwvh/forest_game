package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type milestonePack struct {
	ID       string `json:"packId"`
	Version  int    `json:"version"`
	Quantity int    `json:"quantity"`
}

type milestoneReward struct {
	Tokens, Gems int64
	Packs        []milestonePack
}

func (s *Server) claimMilestone(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	fields, err := readBody(r, "requestId")
	if err != nil {
		return nil, err
	}
	request, err := requestID(fields)
	if err != nil {
		return nil, err
	}
	key := r.PathValue("id")
	operation := "milestone_claim:" + key
	digest, err := requestDigest(operation, map[string]any{})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	if result, err := replayRecoverableMutation(r, tx, owner.ID, request, operation, digest); err != nil || result != nil {
		return result, err
	}
	var garden string
	err = tx.QueryRow(ctx, "SELECT id::text FROM gardens WHERE owner_id=$1 FOR UPDATE", owner.ID).Scan(&garden)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, gardenPresentationUnavailable
	}
	if err != nil {
		return nil, err
	}
	catalog, err := s.catalogueState(ctx, tx)
	if err != nil {
		return nil, err
	}
	var previous map[string]any
	err = tx.QueryRow(ctx, "SELECT receipt FROM milestone_claims WHERE owner_id=$1 AND milestone_id=$2", owner.ID, key).Scan(&previous)
	if err == nil {
		if _, advanced := previous["policyVersion"]; advanced {
			previous["requestId"] = request.String()
		}
		return previous, saveSmallRecoveryReceipt(r, tx, owner.ID, request, operation, digest, previous)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	policy, err := readMilestonePolicy(ctx, tx)
	if err != nil {
		return nil, err
	}
	var entries []map[string]any
	if policy.version != "" {
		if at.Before(policy.effective) {
			return nil, milestoneNotFound
		}
		if !policy.valid {
			return nil, milestonesUnavailable
		}
		if err := refreshMilestoneEntitlements(ctx, tx, owner.ID, at); err != nil {
			return nil, err
		}
		entries, err = advancedMilestones(ctx, tx, owner.ID, policy.version, at, &key)
	} else {
		entries, err = legacyMilestones(ctx, tx, owner.ID, catalog.Version)
	}
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry["milestoneId"] != key {
			continue
		}
		if entry["eligible"] != true {
			message := "Complete the milestone before claiming"
			if policy.version != "" {
				message = "This milestone is incomplete or already fulfilled"
				if unavailable, ok := entry["unavailableReason"].(string); ok {
					message = unavailable
				}
			}
			return nil, &apiError{409, "milestone_not_ready", message}
		}
		if policy.version != "" && r.Header.Get("X-Forest-Milestones") != "1" {
			return nil, &apiError{426, "milestones_client_update_required", "Update the app to claim this reward"}
		}
		m := packMutation{owner: owner.ID, request: request, event: uuid.New(), operation: operation, digest: digest, at: at}
		return s.grantMilestone(r, tx, m, key, policy.version, entry)
	}
	return nil, milestoneNotFound
}

func parseMilestoneReward(entry map[string]any, advanced bool) (milestoneReward, error) {
	var result milestoneReward
	parse := func(field string) (int64, error) {
		value, ok := entry[field].(string)
		if !ok {
			return 0, milestonesUnavailable
		}
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil || n < 0 {
			return 0, milestonesUnavailable
		}
		return n, nil
	}
	var err error
	result.Tokens, err = parse("rewardTokens")
	if err != nil || !advanced {
		return result, err
	}
	result.Gems, err = parse("rewardGems")
	if err != nil {
		return result, err
	}
	if _, ok := entry["rewardPacks"].([]any); !ok {
		return result, milestonesUnavailable
	}
	data, err := json.Marshal(entry["rewardPacks"])
	if err != nil || json.Unmarshal(data, &result.Packs) != nil {
		return result, milestonesUnavailable
	}
	for _, p := range result.Packs {
		if p.Quantity < 1 || p.Version < 1 || !packIdentifier.MatchString(p.ID) {
			return result, milestonesUnavailable
		}
	}
	return result, nil
}

func (s *Server) grantMilestone(r *http.Request, tx pgx.Tx, m packMutation, key, policy string, entry map[string]any) (any, error) {
	ctx := r.Context()
	advanced := policy != ""
	reward, err := parseMilestoneReward(entry, advanced)
	if err != nil {
		return nil, err
	}
	packs := []ownedPack{}
	var capacity map[string]int64
	superseded := []string{}
	if advanced {
		capacity, err = s.plantCapacity(ctx, tx, m.owner)
		if err != nil {
			return nil, err
		}
		room := capacity["packLimit"] - capacity["unopenedPacks"]
		if room < 0 {
			return nil, &apiError{409, "pack_capacity_exceeded", "Pack storage full. Open a pack, then retry."}
		}
		for _, pack := range reward.Packs {
			if int64(pack.Quantity) > room {
				return nil, &apiError{409, "pack_capacity_exceeded", "Pack storage full. Open a pack, then retry."}
			}
			room -= int64(pack.Quantity)
		}
		for _, pack := range reward.Packs {
			if _, err := s.readPack(ctx, tx, packKey{pack.ID, pack.Version}, true); err != nil {
				return nil, err
			}
			for range pack.Quantity {
				packs = append(packs, ownedPack{ID: uuid.New(), PackID: pack.ID, Version: pack.Version, Acquired: m.at})
			}
		}
		capacity["unopenedPacks"] += int64(len(packs))
		if key == "special_run_10km" {
			var replaces bool
			err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM milestone_entitlements
				WHERE owner_id=$1 AND milestone_id='special_run_5km' AND superseded_by IS NOT NULL)`, m.owner).Scan(&replaces)
			if err != nil {
				return nil, err
			}
			if replaces {
				superseded = append(superseded, "special_run_5km")
			}
		}
	}

	wallet, err := grantRewardWallet(ctx, tx, m.owner, reward.Tokens, reward.Gems)
	if err != nil {
		return nil, err
	}
	event := uuid.New()
	source := uuid.NewSHA1(uuid.NameSpaceURL, []byte(m.owner+"/"+key))
	detail := map[string]any{"milestoneId": key, "tokens": numberString(reward.Tokens)}
	receipt := map[string]any{"requestId": m.request, "milestoneId": key, "milestoneEventId": event,
		"tokensEarned": numberString(reward.Tokens), "claimedAt": m.at}
	wallet.addTo(receipt)
	if advanced {
		detail["gems"] = numberString(reward.Gems)
		receipt["gemsEarned"], receipt["packs"], receipt["capacity"] = numberString(reward.Gems), packs, capacity
		receipt["policyVersion"], receipt["supersededMilestoneIds"] = policy, superseded
	}
	var batch pgx.Batch
	batch.Queue(`INSERT INTO visitor_reward_events(id,owner_id,kind,source_id,created_at,detail)
		VALUES($1,$2,'milestone',$3,$4,$5::jsonb)`, event, m.owner, source, m.at, detail)
	if reward.Tokens > 0 {
		batch.Queue(`INSERT INTO visitor_wallet_entries(id,owner_id,event_id,amount,created_at)
			VALUES($1,$2,$3,$4,$5)`, uuid.New(), m.owner, event, reward.Tokens, m.at)
	}
	if reward.Gems > 0 {
		batch.Queue("INSERT INTO milestone_bonus_grants(owner_id,milestone_id,amount,created_at) VALUES($1,$2,$3,$4)", m.owner, key, reward.Gems, m.at)
	}
	if advanced {
		batch.Queue(`INSERT INTO collection_events(id,owner_id,request_id,operation,payload_hash,token_delta,gem_delta,receipt,created_at)
			VALUES($1,$2,$3,$4,$5,0,0,$6::jsonb,$7)`, m.event, m.owner, m.request, m.operation, m.digest, receipt, m.at)
		if len(packs) > 0 {
			batch.Queue(`INSERT INTO owned_packs(id,owner_id,pack_id,pack_version,exchange_id,acquired_at)
				SELECT p."ownedPackId",$1,p."packId",p.version,$2,$3
				FROM jsonb_to_recordset($4::jsonb) p("ownedPackId" uuid,"packId" text,version int)`, m.owner, m.event, m.at, packs)
		}
	}
	batch.Queue(`INSERT INTO milestone_claims(owner_id,milestone_id,reward_tokens,claimed_at,receipt)
		VALUES($1,$2,$3,$4,$5::jsonb)`, m.owner, key, reward.Tokens, m.at, receipt)
	if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
		return nil, err
	}
	return receipt, saveSmallRecoveryReceipt(r, tx, m.owner, m.request, m.operation, m.digest, receipt)
}

func grantRewardWallet(ctx context.Context, tx pgx.Tx, owner string, tokens, gems int64) (commerceWallet, error) {
	var wallet commerceWallet
	err := tx.QueryRow(ctx, `INSERT INTO visitor_wallets AS w
		(owner_id,tokens,hosted_active,hosted_offline,gems,lifetime_gems_earned,economy_version)
		VALUES($1,$2,0,0,$3,$3,1)
		ON CONFLICT(owner_id) DO UPDATE SET tokens=w.tokens+excluded.tokens,gems=w.gems+excluded.gems,
			lifetime_gems_earned=w.lifetime_gems_earned+excluded.lifetime_gems_earned,
			economy_version=w.economy_version+1
		WHERE w.tokens<=9223372036854775807-excluded.tokens AND w.gems<=9223372036854775807-excluded.gems
			AND w.lifetime_gems_earned<=9223372036854775807-excluded.lifetime_gems_earned
			AND w.economy_version<9223372036854775807
		RETURNING tokens,gems,economy_version`, owner, tokens, gems).Scan(&wallet.Tokens, &wallet.Gems, &wallet.Version)
	if errors.Is(err, pgx.ErrNoRows) {
		return wallet, amountOverflow
	}
	if err != nil {
		return wallet, err
	}
	return wallet, nil
}
