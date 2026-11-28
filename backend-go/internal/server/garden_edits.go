package server

import (
	"context"
	"encoding/json"
	"errors"
	"maps"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type gardenProblem struct {
	*apiError
	details map[string]any
}

func (e gardenProblem) Unwrap() error { return e.apiError }

func gardenError(status int, code, message string, details map[string]any) error {
	return gardenProblem{&apiError{status, code, message}, details}
}

func (s *Server) gardenEdits(previewOnly bool) operation {
	return func(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
		req, err := readGardenRequest(r)
		if err != nil {
			return nil, err
		}
		var known *int64
		if !previewOnly && r.URL.Query().Has("knownInventoryStateVersion") {
			v, err := strconv.ParseInt(r.URL.Query().Get("knownInventoryStateVersion"), 10, 64)
			if err != nil || v < 0 {
				return nil, invalid
			}
			known = &v
		}
		ctx := r.Context()
		owner, err := lookupProfile(ctx, tx, id, true)
		if err != nil {
			return nil, err
		}
		if !previewOnly {
			saved, err := replayRecoverableMutation(r, tx, owner.ID, req.key, "garden_edits", req.digest)
			if err != nil || saved != nil {
				return saved, err
			}
		}
		g, err := readGardenRecord(ctx, tx, owner.ID)
		if err != nil {
			return nil, err
		}
		catalog, err := s.catalogueState(ctx, tx)
		if err != nil {
			return nil, err
		}
		at, err := s.gardenNow(ctx, tx)
		if err != nil {
			return nil, err
		}
		var expedition *uuid.UUID
		if !previewOnly {
			expedition, err = expeditionAt(ctx, tx, owner.ID, at)
			if err != nil {
				return nil, err
			}
			if err := s.settleGardenDaily(ctx, tx, &g, at, owner.Timezone); err != nil {
				return nil, err
			}
			if err := observeExpeditionGarden(ctx, tx, expedition, g.id, at, nil); err != nil {
				return nil, err
			}
		}
		p, err := loadGardenCopies(ctx, tx, g, req)
		if err != nil {
			return nil, err
		}
		limits, err := s.plantCapacity(ctx, tx, owner.ID)
		if err != nil {
			return nil, err
		}
		if err := p.propose(r, g, req, catalog.Version, limits["plantedLimit"]); err != nil {
			return nil, err
		}
		facts := p.facts(p.final)
		config, err := readGardenStrategy(ctx, tx, owner.ID, at)
		if err != nil {
			return nil, err
		}
		view, err := s.evaluateGarden(ctx, tx, config, facts)
		if err != nil {
			return nil, err
		}
		if previewOnly || req.signature != "" || req.fingerprint != "" {
			preview, signature, err := view.preview(config, g, catalog.Version, p)
			if err != nil {
				return nil, err
			}
			if previewOnly {
				return preview, nil
			}
			if err := checkGardenProof(req, preview, signature); err != nil {
				return nil, err
			}
		}
		return s.commitGardenEdit(r, tx, g, catalog, req, p, config, view, at, known, limits, expedition)
	}
}

func checkGardenExpedition(ctx context.Context, tx pgx.Tx, at time.Time) error {
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock_shared(591417021)"); err != nil {
		return err
	}
	var unusable bool
	err := tx.QueryRow(ctx, `WITH boundary AS (SELECT date_trunc('month',$1::timestamptz AT TIME ZONE 'UTC')::date AS month)
		SELECT EXISTS (SELECT 1 FROM boundary b JOIN LATERAL (
			SELECT template_version FROM expedition_schedule WHERE month<=b.month ORDER BY month DESC LIMIT 1) s ON true
			LEFT JOIN expedition_launches l ON l.month=b.month
			JOIN expedition_templates t ON t.version=s.template_version
			WHERE $1>=COALESCE(l.starts_at,b.month::timestamp AT TIME ZONE 'UTC')
			AND (jsonb_typeof(t.definition->'quests')='array' AND jsonb_typeof(t.definition->'milestones')='array'
				AND jsonb_typeof(t.definition->'tags')='object') IS NOT TRUE)`, at).Scan(&unusable)
	if err != nil {
		return err
	}
	if unusable {
		return expeditionUnavailable
	}
	return nil
}

func (s *Server) commitGardenEdit(r *http.Request, tx pgx.Tx, g gardenRecord, catalog catalogueState, req gardenRequest,
	p gardenProposal, config gardenStrategy, view gardenEvaluation, at time.Time, known *int64, limits map[string]int64, expedition *uuid.UUID) (any, error) {
	ctx := r.Context()
	base := g.state
	if !maps.Equal(p.final, p.initial) {
		if g.layout == math.MaxInt64 || g.state == math.MaxInt64 {
			return nil, &apiError{503, "version_exhausted", "Garden version requires maintenance"}
		}
		v, err := s.settleVisitorState(ctx, tx, g.id, g.owner, at, false)
		if err != nil {
			return nil, err
		}
		if v.at.After(at) {
			return nil, visitorContextUnavailable
		}
		if err := saveLayoutGroup(ctx, tx, g, p, false); err != nil {
			return nil, err
		}
		if err := saveLayoutGroup(ctx, tx, g, p, true); err != nil {
			return nil, err
		}
		if _, err := tx.Exec(ctx, `UPDATE gardens SET layout_version=layout_version+1,state_version=state_version+1,
			updated_at=$2 WHERE id=$1`, g.id, at); err != nil {
			return nil, err
		}
		g.layout++
		g.state++
		if err := observeExpeditionGarden(ctx, tx, expedition, g.id, at, nil); err != nil {
			return nil, err
		}
		if err := s.replaceGardenContext(ctx, tx, v, config, view); err != nil {
			return nil, err
		}
	}
	garden, updated, err := presentGarden(r, tx, g, catalog, config, view, req.plants)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": req.key, "garden": garden, "updatedPlants": updated, "inventory": nil, "itemInventory": nil,
		"replayed": nil, "inventoryBaseStateVersion": nil, "capacity": nil}
	if r.Header.Get("X-Forest-Snapshot") == "1" {
		result["replayed"] = false
		membershipChanged := len(p.initial) != len(p.final)
		if !membershipChanged {
			for id := range p.initial {
				if _, ok := p.final[id]; !ok {
					membershipChanged = true
					break
				}
			}
		}
		if known != nil && *known == base && !membershipChanged {
			result["inventoryBaseStateVersion"], result["capacity"] = base, limits
		} else {
			result["inventory"], err = s.inventoryFor(ctx, tx, g.owner, 30, nil)
			if err != nil {
				return nil, err
			}
			result["itemInventory"], err = itemInventoryFor(ctx, tx, g.owner, 100, nil, r.Header)
			if err != nil {
				return nil, err
			}
		}
	}
	return result, saveGardenReceipt(r, tx, g, req, result)
}

type layoutRow struct {
	ID  uuid.UUID   `json:"id"`
	X   json.Number `json:"x"`
	Y   json.Number `json:"y"`
	Yaw json.Number `json:"yaw"`
}

func saveLayoutGroup(ctx context.Context, tx pgx.Tx, g gardenRecord, p gardenProposal, item bool) error {
	removals := make([]uuid.UUID, 0)
	updates := make([]layoutRow, 0)
	for id := range p.initial {
		if _, ok := p.final[id]; !ok && p.copies[id].item == item {
			removals = append(removals, id)
		}
	}
	for id, point := range p.final {
		initial, ok := p.initial[id]
		if p.copies[id].item != item || ok && initial == point {
			continue
		}
		updates = append(updates, layoutRow{id, json.Number(gardenFixed(point.x, 3)), json.Number(gardenFixed(point.y, 3)),
			json.Number(gardenFixed(point.rotation, 2))})
	}
	if len(removals) == 0 && len(updates) == 0 {
		return nil
	}
	table, column := "garden_placements", "plant_id"
	if item {
		table, column = "item_placements", "item_id"
	}
	// Only the two constant table/column pairs above can enter this SQL.
	_, err := tx.Exec(ctx, `WITH removed AS (
		DELETE FROM `+table+` WHERE owner_id=$1 AND garden_id=$2 AND `+column+`=ANY($3::uuid[])
	) INSERT INTO `+table+` (`+column+`,owner_id,garden_id,x,y,rotation_degrees)
	SELECT row.id,$1,$2,row.x,row.y,row.yaw FROM jsonb_to_recordset($4::jsonb) AS row(id uuid,x numeric,y numeric,yaw numeric)
	ON CONFLICT (`+column+`) DO UPDATE SET x=excluded.x,y=excluded.y,rotation_degrees=excluded.rotation_degrees`,
		g.owner, g.id, removals, updates)
	return err
}

func replayRecoverableMutation(r *http.Request, tx pgx.Tx, owner string, request uuid.UUID, kind, hash string) (any, error) {
	var operation, digest string
	var response, outcome json.RawMessage
	var at time.Time
	err := tx.QueryRow(r.Context(), `SELECT operation,payload_hash,response,completion->'outcome',created_at FROM api_requests
		WHERE user_id=$1 AND request_id=$2`, owner, request).Scan(&operation, &digest, &response, &outcome, &at)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if operation != kind || digest != hash {
		return nil, &apiError{409, "idempotency_conflict", "Request ID was used for different input"}
	}
	if response != nil {
		if kind != "garden_edits" || r.Header.Get("X-Forest-Snapshot") != "1" {
			return response, nil
		}
		var saved map[string]json.RawMessage
		if err := json.Unmarshal(response, &saved); err != nil {
			return nil, err
		}
		saved["replayed"] = json.RawMessage("true")
		return saved, nil
	}
	if r.Header.Get("X-Forest-Recovery") != "1" {
		return nil, &apiError{426, "recovery_client_update_required", "Update the app to recover this request"}
	}
	if len(outcome) == 0 || string(outcome) == "null" {
		return nil, &apiError{503, "recovery_unavailable", "The saved request needs recovery"}
	}
	if strings.HasPrefix(kind, "milestone_claim:") || strings.HasPrefix(kind, "expedition_claim:") || strings.HasPrefix(kind, "expedition_evidence:") {
		return outcome, nil
	}
	return map[string]any{"recovery": map[string]any{"version": 1, "status": "completed", "requestId": request,
		"operation": operation, "acceptedAt": at, "outcome": outcome, "refreshRequired": true}}, nil
}

func saveGardenReceipt(r *http.Request, tx pgx.Tx, g gardenRecord, req gardenRequest, result map[string]any) error {
	recovery := 0
	if r.Header.Get("X-Forest-Recovery") == "1" {
		recovery = 1
	}
	_, err := tx.Exec(r.Context(), `WITH boundary AS (SELECT clock_timestamp() AS at)
		INSERT INTO api_requests (user_id,request_id,operation,payload_hash,response,completion,created_at,recovery_version,response_expires_at)
		SELECT $1,$2,'garden_edits',$3,$4::jsonb,
			jsonb_build_object('version',1,'outcome',jsonb_build_object('requestId',$2::uuid,'gardenId',$5::uuid)),
			at,$6,CASE WHEN $6=1 THEN at+interval '7 days' END FROM boundary`, g.owner, req.key, req.digest, result, g.id, recovery)
	return err
}
