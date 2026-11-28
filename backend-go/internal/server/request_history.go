package server

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const typedRequestReceipt = `r.operation IN ('register_account','bootstrap_account','update_profile','activity_enrolment')
	OR starts_with(r.operation,'recap_ack:') OR starts_with(r.operation,'milestone_claim:')
	OR starts_with(r.operation,'expedition_evidence:') OR starts_with(r.operation,'expedition_claim:')`
const compactRequestOutcome = `r.operation IN ('activity_sync','garden_edits','visitor_welcome','visitor_claim')`
const visitorControlReceipt = `r.operation IN ('visitor_start','visitor_heartbeat','visitor_end')`
const commerceRequestReceipt = `r.operation IN ('token_exchange','pack_open','item_purchase','plant_sell','item_sell')`
const requestRetention = `CASE
	WHEN ` + visitorControlReceipt + ` THEN interval '24 hours'
	WHEN r.operation IN ('activity_sync','activity_enrolment') THEN interval '30 days'
	ELSE interval '7 days' END`
const requestHasHistoryProof = `r.completion->'version'='1'::jsonb AND jsonb_typeof(r.completion->'outcome')='object'`

func saveSmallRecoveryReceipt(r *http.Request, tx pgx.Tx, owner string, key uuid.UUID, operation, digest string, result any) error {
	return saveRecoveryReceipt(r, tx, owner, key, operation, digest, result, "")
}

func saveRecoveryReceipt(r *http.Request, tx pgx.Tx, owner string, key uuid.UUID, operation, digest string, result any, field string) error {
	ctx := r.Context()
	recovery := r.Header.Get("X-Forest-Recovery") == "1"
	// Opening aliases need a durable pointer even for legacy clients.
	if !recovery && operation != "pack_open" {
		return saveReceipt(ctx, tx, owner, key, operation, digest, result)
	}
	_, err := tx.Exec(ctx, `WITH source AS (
		SELECT $3::text AS operation,$5::jsonb AS response,clock_timestamp() AS at
	), encoded AS (
		SELECT r.*,jsonb_build_object('version',1,'outcome',CASE $6::text
			WHEN '' THEN r.response
			WHEN 'sessionId' THEN jsonb_build_object('sessionId',COALESCE(r.response#>'{session,sessionId}','null'::jsonb))
			ELSE jsonb_build_object($6::text,r.response->$6::text) END) AS proof,
			`+requestRetention+` AS retention
		FROM source r
	)
	INSERT INTO api_requests(user_id,request_id,operation,payload_hash,response,completion,created_at,recovery_version,response_expires_at)
	SELECT $1,$2,operation,$4,response,CASE WHEN octet_length(proof::text)<=8192 THEN proof END,
		at,CASE WHEN $7 THEN 1 ELSE 0 END,CASE WHEN $7 THEN at+retention END FROM encoded`,
		owner, key, operation, digest, result, field, recovery)
	return err
}

// Keep the original receipts of legacy clients. Compaction only removes a
// recoverable response after its window, under the same owner lock as writers.
func compactRequestHistory(ctx context.Context, tx pgx.Tx, at *time.Time) error {
	var counts requestHistoryCounts
	err := tx.QueryRow(ctx, `
	WITH boundary AS MATERIALIZED (SELECT COALESCE($1::timestamptz,clock_timestamp()) AS now),
	queues AS (
		(SELECT r.user_id,r.request_id,r.created_at FROM api_requests r
		WHERE r.response IS NOT NULL AND jsonb_typeof(r.response)='object'
			AND ((`+typedRequestReceipt+`) OR `+compactRequestOutcome+` OR `+visitorControlReceipt+` OR `+commerceRequestReceipt+`)
			AND ((r.completion IS NULL AND (NOT (`+typedRequestReceipt+`)
					OR octet_length(jsonb_build_object('version',1,'outcome',r.response)::text)<=8192))
				OR (r.operation='pack_open' AND NOT (r.completion ? 'version') AND r.response ? 'openingId'
					AND r.completion=jsonb_build_object('outcome',jsonb_build_object('openingId',r.response->'openingId'))))
		ORDER BY r.user_id,r.created_at,r.request_id LIMIT $2)
		UNION ALL
		(SELECT r.user_id,r.request_id,r.created_at FROM api_requests r,boundary
		WHERE r.response IS NOT NULL AND jsonb_typeof(r.response)='object'
			AND ((`+typedRequestReceipt+`) OR `+compactRequestOutcome+` OR `+visitorControlReceipt+` OR `+commerceRequestReceipt+`)
			AND r.recovery_version=1 AND r.response_expires_at<=boundary.now AND `+requestHasHistoryProof+`
		ORDER BY r.response_expires_at,r.user_id,r.request_id LIMIT $2)
	), candidates AS MATERIALIZED (
		SELECT user_id,request_id FROM queues ORDER BY user_id,created_at,request_id LIMIT $2
	), locked_owners AS MATERIALIZED (
		SELECT id FROM users WHERE id IN (SELECT user_id FROM candidates)
		ORDER BY id FOR UPDATE SKIP LOCKED
	), prepared AS MATERIALIZED (
		SELECT r.user_id,r.request_id,r.operation,r.recovery_version,r.payload_hash,r.created_at,
			r.completion,r.response,
			COALESCE(r.response_expires_at,r.created_at+`+requestRetention+`) AS expiry,
			CASE
				WHEN `+requestHasHistoryProof+` THEN r.completion
				WHEN r.completion IS NOT NULL AND NOT (r.operation='pack_open' AND r.response ? 'openingId'
					AND r.completion=jsonb_build_object('outcome',jsonb_build_object('openingId',r.response->'openingId'))) THEN NULL
				WHEN (`+typedRequestReceipt+`) THEN jsonb_build_object('version',1,'outcome',r.response)
				WHEN `+compactRequestOutcome+` THEN `+activityHistoryCompletion+`
				WHEN `+visitorControlReceipt+` THEN jsonb_build_object('version',1,'outcome',jsonb_build_object('sessionId',COALESCE(r.response#>'{session,sessionId}','null'::jsonb)))
				WHEN `+commerceRequestReceipt+` THEN jsonb_build_object('version',1,'outcome',
					jsonb_strip_nulls(jsonb_build_object('openingId',r.response->'openingId','exchangeId',r.response->'exchangeId',
						'saleId',r.response->'saleId','purchaseId',r.response->'purchaseId')))
			END AS proof
		FROM candidates c JOIN locked_owners u ON u.id=c.user_id
		JOIN api_requests r ON (r.user_id,r.request_id)=(c.user_id,c.request_id)
		WHERE jsonb_typeof(r.response)='object'
	), verified AS MATERIALIZED (
		SELECT r.*,r.recovery_version=1 AND r.expiry<=boundary.now AND CASE
			WHEN `+typedRequestReceipt+` THEN r.proof->'outcome'=r.response
			WHEN `+visitorControlReceipt+` THEN r.proof#>'{outcome,sessionId}' IS NOT DISTINCT FROM COALESCE(r.response#>'{session,sessionId}','null'::jsonb)
				AND (r.proof->'sequencedControl' IS DISTINCT FROM 'true'::jsonb OR EXISTS(
					SELECT 1 FROM visitor_controls c WHERE c.owner_id=r.user_id
						AND (c.accepted_at>=r.created_at OR (c.request_id,c.operation,c.payload_hash)=(r.request_id,r.operation,r.payload_hash))))
			WHEN r.operation IN ('token_exchange','item_purchase') THEN EXISTS(
				SELECT 1 FROM collection_events e WHERE (e.owner_id,e.request_id)=(r.user_id,r.request_id)
					AND e.operation=r.operation AND e.payload_hash=r.payload_hash AND e.receipt=r.response)
			WHEN r.operation='pack_open' THEN EXISTS(
				SELECT 1 FROM pack_openings o JOIN collection_events e ON (e.owner_id,e.id)=(o.owner_id,o.event_id)
				WHERE o.owner_id=r.user_id AND o.id=CASE WHEN pg_input_is_valid(r.proof#>>'{outcome,openingId}','uuid')
					THEN (r.proof#>>'{outcome,openingId}')::uuid END AND e.operation=r.operation
					AND e.payload_hash=r.payload_hash AND e.receipt=r.response)
			WHEN r.operation='plant_sell' THEN EXISTS(
				SELECT 1 FROM plant_sales e WHERE (e.owner_id,e.request_id)=(r.user_id,r.request_id)
					AND e.payload_hash=r.payload_hash AND e.receipt=r.response)
			WHEN r.operation='item_sell' THEN EXISTS(
				SELECT 1 FROM item_sales e WHERE (e.owner_id,e.request_id)=(r.user_id,r.request_id)
					AND e.payload_hash=r.payload_hash AND e.receipt=r.response)
			ELSE true END AS expired
		FROM prepared r,boundary
		WHERE jsonb_typeof(r.proof->'outcome')='object' AND octet_length(r.proof::text)<=8192
	), retiring AS MATERIALIZED (
		SELECT v.* FROM verified v JOIN visitor_controls c ON c.owner_id=v.user_id
		WHERE v.expired AND v.operation IN ('visitor_start','visitor_heartbeat','visitor_end')
			AND v.proof->'sequencedControl'='true'::jsonb
			AND (c.accepted_at>=v.created_at OR (c.request_id,c.operation,c.payload_hash)=(v.request_id,v.operation,v.payload_hash))
	), deleted AS (
		DELETE FROM api_requests r USING retiring v WHERE (r.user_id,r.request_id)=(v.user_id,v.request_id)
		RETURNING 1
	), changed AS (
		UPDATE api_requests r SET completion=v.proof,
			response_expires_at=CASE WHEN v.recovery_version=1 THEN v.expiry ELSE r.response_expires_at END,
			response=CASE WHEN v.expired THEN NULL ELSE r.response END
		FROM verified v WHERE (r.user_id,r.request_id)=(v.user_id,v.request_id)
			AND (v.completion IS DISTINCT FROM v.proof OR v.expired OR (v.recovery_version=1 AND r.response_expires_at IS NULL))
			AND NOT EXISTS(SELECT 1 FROM retiring d WHERE (d.user_id,d.request_id)=(v.user_id,v.request_id))
		RETURNING v.completion IS DISTINCT FROM v.proof AS backfilled,v.expired AS compacted
	)
	SELECT (SELECT count(*) FROM candidates c WHERE EXISTS(SELECT 1 FROM locked_owners u WHERE u.id=c.user_id)),
		(SELECT count(*) FROM changed WHERE backfilled),(SELECT count(*) FROM changed WHERE compacted),(SELECT count(*) FROM deleted)
	WHERE EXISTS(SELECT 1 FROM candidates)`, at, workerSettings(ctx).BatchLimit).
		Scan(&counts.Examined, &counts.Backfilled, &counts.Compacted, &counts.DeletedControls)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err == nil {
		if report := workerReportFrom(ctx); report != nil {
			report.Responses = counts
		}
	}
	return err
}
