package server

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type recap struct {
	ID        uuid.UUID       `json:"recapId"`
	CreatedAt time.Time       `json:"createdAt"`
	Payload   json.RawMessage `json:"payload"`
}

func (s *Server) recaps(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	limit, after, err := parsePage(r, 30, 100)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, `SELECT id,created_at,payload FROM reward_recaps WHERE owner_id=$1 AND acknowledged_at IS NULL
		AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3`, p.ID, after, limit+1)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (value recap, err error) {
		err = r.Scan(&value.ID, &value.CreatedAt, &value.Payload)
		value.CreatedAt = value.CreatedAt.UTC()
		return
	})
	if err != nil {
		return nil, err
	}
	if items == nil {
		items = []recap{}
	}
	var cursor *uuid.UUID
	if len(items) > limit {
		items = items[:limit]
		cursor = &items[limit-1].ID
	}
	return map[string]any{"recaps": items, "nextCursor": cursor}, nil
}

func (s *Server) acknowledgeRecap(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	target, err := uuid.Parse(r.PathValue("id"))
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
	operation := "recap_ack:" + target.String()
	hash, err := requestDigest(operation, map[string]any{})
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if saved, err := replay(ctx, tx, p.ID, key, operation, hash, r.Header.Get("X-Forest-Recovery") == "1"); err != nil || saved != nil {
		return saved, err
	}
	var acknowledged time.Time
	err = tx.QueryRow(ctx, `UPDATE reward_recaps SET acknowledged_at=COALESCE(acknowledged_at,clock_timestamp())
		WHERE owner_id=$1 AND id=$2 RETURNING acknowledged_at`, p.ID, target).Scan(&acknowledged)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{404, "recap_not_found", "Recap not found"}
	}
	if err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": key, "recapId": target, "acknowledgedAt": acknowledged.UTC()}
	return result, saveSmallRecoveryReceipt(r, tx, p.ID, key, operation, hash, result)
}
