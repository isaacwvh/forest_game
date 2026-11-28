package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type visitorRewardProof struct {
	Request uuid.UUID  `json:"requestId"`
	Event   *uuid.UUID `json:"eventId"`
	Visits  string     `json:"visits"`
	Tokens  string     `json:"tokens"`
}

type visitorWelcomeReceipt struct {
	visitorRewardProof
	AcceptedAt  time.Time `json:"acceptedAt"`
	Recoverable bool      `json:"recoverable"`
}

func saveVisitorRewardReceipt(ctx context.Context, tx pgx.Tx, owner string, input visitorInput, response any, proof visitorRewardProof) error {
	if !input.recovery {
		return saveReceipt(ctx, tx, owner, input.key, input.operation, input.digest, response)
	}
	_, err := tx.Exec(ctx, `WITH boundary AS (SELECT clock_timestamp() AS at)
		INSERT INTO api_requests
			(user_id,request_id,operation,payload_hash,response,completion,created_at,recovery_version,response_expires_at)
		SELECT $1,$2,$3,$4,$5::jsonb,jsonb_build_object('version',1,'outcome',$6::jsonb),at,1,at+interval '7 days'
		FROM boundary`, owner, input.key, input.operation, input.digest, response, proof)
	return err
}

func recoverVisitorWelcome(ctx context.Context, tx pgx.Tx, owner string, input visitorInput, runtime *visitorRuntime) (any, error) {
	var receipt visitorWelcomeReceipt
	var event uuid.UUID
	err := tx.QueryRow(ctx, `SELECT id,receipt FROM visitor_reward_events
		WHERE owner_id=$1 AND source_id=$2 AND kind='active_welcome' AND receipt IS NOT NULL`, owner, input.target).Scan(&event, &receipt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if !input.recovery || !receipt.Recoverable {
		return nil, &apiError{http.StatusUpgradeRequired, "recovery_client_update_required", "Update the app to recover this visitor"}
	}
	if receipt.Event == nil || *receipt.Event != event || receipt.Request == uuid.Nil ||
		receipt.Visits == "" || receipt.Tokens == "" || receipt.AcceptedAt.IsZero() {
		return nil, &apiError{503, "recovery_unavailable", "The original visitor receipt needs recovery"}
	}
	if err := runtime.persist(ctx, tx); err != nil {
		return nil, err
	}
	facts := struct {
		visitorRewardProof
		AcceptedAt time.Time `json:"acceptedAt"`
	}{receipt.visitorRewardProof, receipt.AcceptedAt}
	var accepted time.Time
	// The alias has its own durable request identity even though it points to
	// the original welcome, so retrying that alias cannot redeem another slot.
	err = tx.QueryRow(ctx, `WITH boundary AS (SELECT clock_timestamp() AS at)
		INSERT INTO api_requests
			(user_id,request_id,operation,payload_hash,completion,created_at,recovery_version,response_expires_at)
		SELECT $1,$2,'visitor_welcome',$3,jsonb_build_object('version',1,'outcome',$4::jsonb),at,1,at+interval '7 days'
		FROM boundary RETURNING created_at`, owner, input.key, input.digest, facts).Scan(&accepted)
	if err != nil {
		return nil, err
	}
	return map[string]any{"recovery": map[string]any{"version": 1, "status": "completed", "requestId": input.key,
		"operation": input.operation, "acceptedAt": accepted, "outcome": facts, "refreshRequired": true}}, nil
}
