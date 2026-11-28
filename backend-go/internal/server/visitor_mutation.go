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

type visitorControl struct {
	sequence                   int64
	request, operation, digest *string
	at                         *time.Time
}

type visitorInput struct {
	key                                     uuid.UUID
	target, installation, operation, digest string
	protocol                                int
	expected                                *int64
	recovery                                bool
}

func readVisitorMutation(r *http.Request, operation string) (visitorInput, error) {
	v := visitorInput{operation: operation, protocol: 1, recovery: r.Header.Get("X-Forest-Recovery") == "1"}
	keys := []string{"requestId"}
	control := operation == "visitor_start" || operation == "visitor_end" || operation == "visitor_heartbeat"
	if control {
		keys = append(keys, "installationId", "arrivalProtocol", "controlProtocol", "expectedControlSequence")
	}
	body, err := readBody(r, keys...)
	if err != nil {
		return v, err
	}
	v.key, err = requestID(body)
	if err != nil {
		return v, err
	}
	payload := map[string]any{}
	if control {
		raw, err := stringField(body, "installationId")
		if err != nil {
			return v, err
		}
		installation, err := uuid.Parse(raw)
		if err != nil {
			return v, invalid
		}
		v.installation = installation.String()
		payload["installationId"] = v.installation
		if body["arrivalProtocol"] != nil {
			if err := json.Unmarshal(body["arrivalProtocol"], &v.protocol); err != nil ||
				string(body["arrivalProtocol"]) == "null" || v.protocol < 1 || v.protocol > 2 {
				return v, invalid
			}
			if v.protocol != 1 {
				payload["arrivalProtocol"] = v.protocol
			}
		}
		var controlVersion *int
		for _, field := range []struct {
			name   string
			target any
		}{
			{"controlProtocol", &controlVersion}, {"expectedControlSequence", &v.expected},
		} {
			if body[field.name] != nil {
				if err := json.Unmarshal(body[field.name], field.target); err != nil {
					return v, invalid
				}
			}
		}
		if (controlVersion == nil) != (v.expected == nil) {
			return v, invalid
		}
		if controlVersion != nil {
			if *controlVersion != 1 || *v.expected < 0 || *v.expected == math.MaxInt64 {
				return v, invalid
			}
			if !v.recovery {
				return v, &apiError{422, "control_recovery_required", "Sequenced controls require recovery support"}
			}
			payload["controlProtocol"], payload["expectedControlSequence"] = *controlVersion, *v.expected
		}
	}
	digestOperation := operation
	if r.PathValue("id") != "" {
		target, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			return v, invalid
		}
		v.target = target.String()
		digestOperation += ":" + v.target
	}
	v.digest, err = requestDigest(digestOperation, payload)
	return v, err
}

func readControl(ctx context.Context, tx pgx.Tx, owner string) (visitorControl, error) {
	var previous visitorControl
	err := tx.QueryRow(ctx, `SELECT sequence,request_id::text,operation,payload_hash,accepted_at
		FROM visitor_controls WHERE owner_id=$1`, owner).
		Scan(&previous.sequence, &previous.request, &previous.operation, &previous.digest, &previous.at)
	if errors.Is(err, pgx.ErrNoRows) {
		err = nil
	}
	return previous, err
}

func (v visitorInput) checkControl(previous visitorControl) (map[string]any, error) {
	isSame := previous.request != nil && v.key.String() == *previous.request
	if isSame && (previous.operation == nil || previous.digest == nil || *previous.operation != v.operation || *previous.digest != v.digest) {
		return nil, &apiError{409, "idempotency_conflict", "Control ID was used for different input"}
	}
	if previous.sequence == *v.expected {
		return nil, nil
	}
	status := "stale_control"
	var acceptedAt *time.Time
	if isSame {
		status, acceptedAt = "completed", previous.at
	}
	return map[string]any{"recovery": map[string]any{"version": 1, "status": status, "requestId": v.key,
		"operation": v.operation, "acceptedAt": acceptedAt, "outcome": map[string]int64{"controlSequence": previous.sequence},
		"refreshRequired": true}}, nil
}

func (s *Server) visitorMutation(kind string) operation {
	return func(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
		ctx := r.Context()
		input, err := readVisitorMutation(r, kind)
		if err != nil {
			return nil, err
		}
		owner, err := lookupProfile(ctx, tx, id, true)
		if err != nil {
			return nil, err
		}
		if saved, err := replayRecoverableMutation(r, tx, owner.ID, input.key, kind, input.digest); err != nil || saved != nil {
			return saved, err
		}
		if input.expected != nil {
			previous, err := readControl(ctx, tx, owner.ID)
			if err != nil {
				return nil, err
			}
			if data, err := input.checkControl(previous); err != nil || data != nil {
				return data, err
			}
		}
		if _, err := s.catalogueState(ctx, tx); err != nil {
			return nil, err
		}
		v, err := s.settleVisitors(ctx, tx, owner, kind == "visitor_heartbeat")
		if err != nil {
			return nil, err
		}
		var result any
		switch kind {
		case "visitor_start", "visitor_heartbeat", "visitor_end":
			if err := v.applyControl(ctx, tx, owner.ID, input); err != nil {
				return nil, err
			}
			if input.expected != nil {
				_, err = tx.Exec(ctx, `INSERT INTO visitor_controls (owner_id,sequence,request_id,operation,payload_hash,accepted_at)
					VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT (owner_id) DO UPDATE SET sequence=excluded.sequence,
					request_id=excluded.request_id,operation=excluded.operation,payload_hash=excluded.payload_hash,accepted_at=excluded.accepted_at`,
					owner.ID, *input.expected+1, input.key, kind, input.digest, v.at)
				if err != nil {
					return nil, err
				}
			}
		case "visitor_welcome", "visitor_claim":
			result, err = s.applyReward(ctx, tx, owner.ID, input, v)
			if err != nil {
				return nil, err
			}
		}
		if result != nil {
			return result, nil
		}
		if v.state.version == math.MaxInt64 {
			return nil, visitorContextUnavailable
		}
		v.state.version++
		if err := v.schedule(ctx, tx); err != nil {
			return nil, err
		}
		if err := v.persist(ctx, tx); err != nil {
			return nil, err
		}
		summary, err := s.visitorSummary(ctx, tx, owner.ID, v)
		if err != nil {
			return nil, err
		}
		// A sequence is the durable receipt for recent controls.
		if input.expected == nil {
			if err := saveRecoveryReceipt(r, tx, owner.ID, input.key, kind, input.digest, summary, "sessionId"); err != nil {
				return nil, err
			}
		}
		return summary, nil
	}
}

func (v *visitorRuntime) applyControl(ctx context.Context, tx pgx.Tx, owner string, input visitorInput) error {
	if input.operation == "visitor_start" {
		if v.config.protocol == 2 && input.protocol != 2 {
			return &apiError{409, "visitor_client_update_required", "Update Movement Forest to use the new visitor arrivals"}
		}
		if v.active != nil && v.active.Installation != input.installation {
			return &apiError{409, "visitor_session_conflict", "Visitors are active on another device. Wait for its lease to expire"}
		}
		if v.active == nil {
			v.active = &visitorSession{uuid.NewString(), input.installation, v.at.Add(time.Duration(v.config.lease) * time.Second), input.protocol}
			v.state.slot = max(v.state.slot, v.at.Unix()/30)
			_, err := tx.Exec(ctx, `INSERT INTO visitor_sessions
				(id,owner_id,garden_id,installation_id,started_at,lease_expires_at,arrival_protocol)
				VALUES ($1,$2,$3,$4,$5,$6,$7)`, v.active.ID, owner, v.state.garden, input.installation, v.at, v.active.Expires, input.protocol)
			return err
		}
	} else if v.active == nil || v.active.ID != input.target || v.active.Installation != input.installation {
		return &apiError{409, "visitor_session_inactive", "This visitor session has ended. Reconnect to start again"}
	}
	if input.operation == "visitor_end" {
		return v.close(ctx, tx, v.at)
	}
	if input.operation == "visitor_heartbeat" {
		if err := v.issueLegacyArrival(ctx, tx); err != nil {
			return err
		}
	}
	v.active.Expires = v.at.Add(time.Duration(v.config.lease) * time.Second)
	_, err := tx.Exec(ctx, "UPDATE visitor_sessions SET lease_expires_at=$2 WHERE id=$1", v.active.ID, v.active.Expires)
	return err
}

type rewardLot struct {
	Rule   string `json:"ruleVersion"`
	Visits int64  `json:"visits"`
	Tokens int64  `json:"tokens"`
}

func (s *Server) applyReward(ctx context.Context, tx pgx.Tx, owner string, input visitorInput, v *visitorRuntime) (any, error) {
	var visits, tokens int64
	var event *uuid.UUID
	var milestones visitorMilestonePolicy
	lots := []rewardLot{}
	welcome := input.operation == "visitor_welcome"
	if welcome {
		var session, status, rule string
		var issued, expires time.Time
		var previous json.RawMessage
		err := tx.QueryRow(ctx, `SELECT session_id::text,status,rule_version,issued_at,expires_at,tokens,result
			FROM visitor_opportunities WHERE id=$1 AND garden_id=$2`, input.target, v.state.garden).
			Scan(&session, &status, &rule, &issued, &expires, &tokens, &previous)
		if errors.Is(err, pgx.ErrNoRows) {
			if recovered, err := recoverVisitorWelcome(ctx, tx, owner, input, v); err != nil || recovered != nil {
				return recovered, err
			}
			return nil, &apiError{404, "visitor_not_found", "Visitor not found"}
		}
		if err != nil {
			return nil, err
		}
		if status == "welcomed" {
			var saved struct {
				Summary json.RawMessage `json:"summary"`
			}
			if err := json.Unmarshal(previous, &saved); err != nil || len(saved.Summary) == 0 {
				if recovered, err := recoverVisitorWelcome(ctx, tx, owner, input, v); err != nil || recovered != nil {
					return recovered, err
				}
				return nil, &apiError{503, "recovery_unavailable", "The original visitor receipt needs recovery"}
			}
			if err := v.persist(ctx, tx); err != nil {
				return nil, err
			}
			var proof visitorRewardProof
			if err := json.Unmarshal(previous, &proof); err != nil {
				return nil, err
			}
			return previous, saveVisitorRewardReceipt(ctx, tx, owner, input, previous, proof)
		}
		if v.active == nil || v.active.ID != session || status != "issued" || !v.at.Before(expires) {
			return nil, &apiError{409, "visitor_expired", "This visitor has departed. Wait for the next arrival"}
		}
		if v.at.Before(issued) {
			return nil, &apiError{409, "visitor_not_arrived", "This visitor has not arrived yet"}
		}
		visits = 1
		lots = append(lots, rewardLot{rule, 1, tokens})
	} else {
		visits = v.state.whole
		if visits > 0 {
			rows, err := tx.Query(ctx, `SELECT rule_version,visits,(visits * tokens_per_visit)
				FROM visitor_storage_lots WHERE garden_id=$1 AND visits>0 ORDER BY rule_version`, v.state.garden)
			if err != nil {
				return nil, err
			}
			lots, err = pgx.CollectRows(rows, func(row pgx.CollectableRow) (lot rewardLot, err error) {
				err = row.Scan(&lot.Rule, &lot.Visits, &lot.Tokens)
				return
			})
			if err != nil {
				return nil, err
			}
			var total int64
			for _, lot := range lots {
				if lot.Tokens > math.MaxInt64-tokens || lot.Visits > math.MaxInt64-total {
					return nil, visitorContextUnavailable
				}
				tokens += lot.Tokens
				total += lot.Visits
			}
			if total != visits {
				return nil, visitorContextUnavailable
			}
			if _, err := tx.Exec(ctx, "UPDATE visitor_storage_lots SET visits=0 WHERE garden_id=$1 AND visits>0", v.state.garden); err != nil {
				return nil, err
			}
			v.state.whole = 0
		}
	}
	if visits > 0 {
		var err error
		milestones, err = verifyRewardPolicy(ctx, tx, v.at)
		if err != nil {
			return nil, err
		}
		key := uuid.New()
		event = &key
		kind, source, active, offline := "offline_claim", input.key.String(), int64(0), visits
		if welcome {
			kind, source, active, offline = "active_welcome", input.target, visits, 0
		}
		detail := map[string]any{"visits": numberString(visits), "tokens": numberString(tokens), "lots": lots,
			"remainingFraction": visitorAmount(v.state.remainder)}
		var batch pgx.Batch
		batch.Queue(`UPDATE visitor_wallets SET tokens=tokens+$2,hosted_active=hosted_active+$3,
			hosted_offline=hosted_offline+$4,economy_version=economy_version+1 WHERE owner_id=$1`, owner, tokens, active, offline)
		batch.Queue(`INSERT INTO visitor_reward_events (id,owner_id,kind,source_id,created_at,detail)
			VALUES ($1,$2,$3,$4,$5,$6::jsonb)`, key, owner, kind, source, v.at, detail)
		batch.Queue(`INSERT INTO visitor_wallet_entries (id,owner_id,event_id,amount,created_at)
			VALUES ($1,$2,$3,$4,$5)`, uuid.New(), owner, key, tokens, v.at)
		if welcome {
			batch.Queue("UPDATE visitor_opportunities SET status='welcomed' WHERE id=$1", input.target)
		}
		if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
			return nil, err
		}
		if milestones.enabled {
			if err := observeMilestoneVisitors(ctx, tx, owner, v.at, visits, milestones.events); err != nil {
				return nil, err
			}
		}
		if welcome {
			err := observeExpeditionWelcome(ctx, tx, owner, v.state.garden, v.at, uuid.MustParse(input.target))
			if errors.Is(err, expeditionUnavailable) {
				return nil, &apiError{503, "visitor_progress_unavailable", "Visitor reward progress requires reconciliation"}
			}
			if err != nil {
				return nil, err
			}
		}
	}
	if v.state.version == math.MaxInt64 {
		return nil, visitorContextUnavailable
	}
	v.state.version++
	if err := v.schedule(ctx, tx); err != nil {
		return nil, err
	}
	if err := v.persist(ctx, tx); err != nil {
		return nil, err
	}
	summary, err := s.visitorSummary(ctx, tx, owner, v)
	if err != nil {
		return nil, err
	}
	proof := visitorRewardProof{Request: input.key, Event: event, Visits: numberString(visits), Tokens: numberString(tokens)}
	result := struct {
		visitorRewardProof
		Summary map[string]any `json:"summary"`
	}{proof, summary}
	if welcome {
		receipt := visitorWelcomeReceipt{proof, v.at, input.recovery}
		if _, err := tx.Exec(ctx, "UPDATE visitor_reward_events SET receipt=$2::jsonb WHERE id=$1", event, receipt); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, "UPDATE visitor_opportunities SET result=$2::jsonb WHERE id=$1", input.target, result); err != nil {
			return nil, err
		}
	}
	return result, saveVisitorRewardReceipt(ctx, tx, owner, input, result, proof)
}

type visitorMilestonePolicy struct{ enabled, events bool }

func verifyRewardPolicy(ctx context.Context, tx pgx.Tx, at time.Time) (visitorMilestonePolicy, error) {
	var policy visitorMilestonePolicy
	var valid bool
	err := tx.QueryRow(ctx, `WITH policy AS (
		SELECT (jsonb_typeof(definition->'quests')='array' AND jsonb_typeof(definition->'species')='object') IS TRUE AS valid
		FROM milestone_policies WHERE active AND effective_at<=$1
	) SELECT
		EXISTS(SELECT 1 FROM policy), COALESCE((SELECT valid FROM policy),true),
		EXISTS(SELECT 1 FROM milestone_events WHERE starts_at<=$1 AND ends_at>$1)`,
		at).Scan(&policy.enabled, &valid, &policy.events)
	if err != nil {
		return policy, err
	}
	if !valid {
		return policy, &apiError{503, "visitor_progress_unavailable", "Visitor reward progress requires reconciliation"}
	}
	return policy, nil
}
