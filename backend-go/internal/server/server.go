package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const SchemaVersion = 2
const maintenanceLock int64 = 711023001

type Server struct {
	Pool            *pgxpool.Pool
	Auth            *Verifier
	Environment     string
	WorkerConfig    *WorkerConfig
	catalogues      catalogueCache
	visitorContexts visitorContextCache
	packs           packCache
	skillProfiles   skillProfileCache
	visitorClock    func() time.Time
}

type apiError struct {
	Status  int
	Code    string
	Message string
}

func (e *apiError) Error() string { return e.Code }

var (
	invalid                = &apiError{422, "invalid_request", "Invalid request fields"}
	maintenance            = &apiError{503, "maintenance", "The garden is being updated. Your saved requests are safe; please retry shortly."}
	maintenanceUnavailable = &apiError{503, "maintenance_state_unavailable", maintenance.Message}
)

func reply(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		slog.Debug("response interrupted", "error_type", fmt.Sprintf("%T", err))
	}
}

func failure(w http.ResponseWriter, err error) {
	var problem *apiError
	if !errors.As(err, &problem) {
		slog.Error("game operation failed", "error_type", fmt.Sprintf("%T", err))
		problem = &apiError{500, "internal_error", "The request could not be completed"}
	}
	if problem.Status == http.StatusUnauthorized {
		w.Header().Set("WWW-Authenticate", "Bearer")
	}
	if problem.Status == http.StatusServiceUnavailable {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Retry-After", "30")
	}
	payload := map[string]any{
		"code": problem.Code, "message": problem.Message,
	}
	var detailed gardenProblem
	if errors.As(err, &detailed) && detailed.details != nil {
		payload["details"] = detailed.details
	}
	reply(w, problem.Status, map[string]any{"error": payload})
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("GET /health/ready", s.ready)
	mux.HandleFunc("GET /v1/me", s.game(s.profile))
	mux.HandleFunc("PATCH /v1/me", s.game(s.updateProfile))
	mux.HandleFunc("POST /v1/accounts", s.game(s.register))
	mux.HandleFunc("POST /v1/accounts/bootstrap", s.game(s.register))
	mux.HandleFunc("GET /v1/catalog", s.game(s.catalogue))
	mux.HandleFunc("GET /v1/me/inventory", s.game(s.inventory))
	mux.HandleFunc("GET /v1/me/garden", s.game(s.garden))
	mux.HandleFunc("GET /v1/me/garden/snapshot", s.game(s.gardenSnapshot))
	mux.HandleFunc("POST /v1/me/garden/preview", s.game(s.gardenEdits(true)))
	mux.HandleFunc("POST /v1/me/garden/edits", s.game(s.gardenEdits(false)))
	mux.HandleFunc("GET /v1/me/items", s.game(s.itemInventory))
	mux.HandleFunc("GET /v1/me/collection", s.game(s.collection))
	mux.HandleFunc("POST /v1/me/milestones/{id}/claim", s.game(s.claimMilestone))
	mux.HandleFunc("GET /v1/me/expeditions/current", s.game(s.currentExpedition))
	mux.HandleFunc("GET /v1/me/expeditions", s.game(s.expeditionArchive))
	mux.HandleFunc("GET /v1/me/expeditions/{run}", s.game(s.expeditionDetail))
	mux.HandleFunc("POST /v1/me/expeditions/{run}/evidence", s.game(s.uploadExpeditionEvidence))
	mux.HandleFunc("POST /v1/me/expeditions/{run}/rewards/{entitlement}/claim", s.game(s.claimExpedition))
	mux.HandleFunc("GET /v1/me/packs", s.game(packPage(false)))
	mux.HandleFunc("GET /v1/me/pack-openings", s.game(packPage(true)))
	mux.HandleFunc("GET /v1/pack-definitions/{packID}/versions/{version}", s.game(s.packDefinition))
	mux.HandleFunc("POST /v1/me/exchanges", s.game(s.exchangePack))
	mux.HandleFunc("POST /v1/me/packs/{id}/open", s.game(s.openPack))
	mux.HandleFunc("POST /v1/me/item-purchases", s.game(s.purchaseItem))
	mux.HandleFunc("GET /v1/me/items/{id}/sale-quote", s.game(saleQuote(sellItemKind)))
	mux.HandleFunc("POST /v1/me/items/{id}/sell", s.game(s.sellOwned(sellItemKind)))
	mux.HandleFunc("GET /v1/me/plants/{id}/sale-quote", s.game(saleQuote(sellPlantKind)))
	mux.HandleFunc("POST /v1/me/plants/{id}/sell", s.game(s.sellOwned(sellPlantKind)))
	mux.HandleFunc("GET /v1/me/catalog-discovery", s.game(s.discovery))
	mux.HandleFunc("GET /v1/me/plants/{id}", s.game(s.plant))
	mux.HandleFunc("GET /v1/me/capacity", s.game(s.capacity))
	mux.HandleFunc("GET /v1/me/activity", s.game(s.activityStatus))
	mux.HandleFunc("POST /v1/activity/enrolments", s.game(s.activityEnrol))
	mux.HandleFunc("POST /v1/activity/sync", s.game(s.syncActivity))
	mux.HandleFunc("GET /v1/me/account-summary", s.game(s.accountSummary))
	mux.HandleFunc("GET /v1/me/home-attention", s.game(s.homeAttention))
	mux.HandleFunc("GET /v1/me/reward-recaps", s.game(s.recaps))
	mux.HandleFunc("POST /v1/reward-recaps/{id}/ack", s.game(s.acknowledgeRecap))
	mux.HandleFunc("POST /v1/me/level-up-notices/{id}/present", s.game(s.presentLevel))
	mux.HandleFunc("GET /v1/me/visitors", s.game(s.visitor))
	mux.HandleFunc("POST /v1/me/visitor-sessions", s.game(s.visitorMutation("visitor_start")))
	mux.HandleFunc("POST /v1/me/visitor-sessions/{id}/heartbeat", s.game(s.visitorMutation("visitor_heartbeat")))
	mux.HandleFunc("POST /v1/me/visitor-sessions/{id}/end", s.game(s.visitorMutation("visitor_end")))
	mux.HandleFunc("POST /v1/me/visitor-opportunities/{id}/welcome", s.game(s.visitorMutation("visitor_welcome")))
	mux.HandleFunc("POST /v1/me/stored-visits/claim", s.game(s.visitorMutation("visitor_claim")))
	return mux
}

func (s *Server) ready(w http.ResponseWriter, r *http.Request) {
	var revision int
	var dirty bool
	err := s.Pool.QueryRow(r.Context(), "SELECT version, dirty FROM public.schema_migrations").Scan(&revision, &dirty)
	if err != nil {
		failure(w, &apiError{503, "database_not_ready", "Database is not ready"})
		return
	}
	if dirty || revision != SchemaVersion {
		failure(w, &apiError{503, "schema_not_ready", "Database schema is not ready"})
		return
	}
	reply(w, 200, map[string]string{"status": "ready"})
}

// A shop request can advance bounded catch-up work and still need a retry.
type committedProblem struct{ err error }

type operation func(*http.Request, pgx.Tx, Identity) (any, error)

func (s *Server) game(run operation) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
		defer cancel()
		tx, err := s.Pool.Begin(ctx)
		if err != nil {
			failure(w, maintenanceUnavailable)
			return
		}
		defer func() {
			cleanup, stop := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
			defer stop()
			_ = tx.Rollback(cleanup)
		}()
		metrics := new(requestMetrics)
		scoped := measuredTx{Tx: tx, metrics: metrics}
		if err := admit(ctx, scoped); err != nil {
			failure(w, err)
			return
		}
		token := strings.Fields(r.Header.Get("Authorization"))
		if len(token) != 2 || !strings.EqualFold(token[0], "Bearer") {
			failure(w, &apiError{401, "authentication_required", "Bearer authentication required"})
			return
		}
		identity, err := s.Auth.Verify(ctx, token[1])
		if err != nil {
			failure(w, err)
			return
		}
		result, err := run(r.WithContext(ctx), scoped, identity)
		if err == nil {
			err = tx.Commit(ctx)
		}
		if err != nil {
			failure(w, err)
			return
		}
		if result, ok := result.(committedProblem); ok {
			failure(w, result.err)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		if s.Environment == "local" || s.Environment == "test" {
			w.Header().Set("X-Forest-DB-Result-Bytes", strconv.Itoa(metrics.resultBytes))
			w.Header().Set("X-Forest-DB-Statements", strconv.Itoa(metrics.statements))
		}
		reply(w, 200, result)
	}
}

func admit(ctx context.Context, tx pgx.Tx) error {
	var locked bool
	if err := tx.QueryRow(ctx, "SELECT pg_try_advisory_xact_lock_shared($1)", maintenanceLock).Scan(&locked); err != nil {
		return maintenanceUnavailable
	}
	if !locked {
		return maintenance
	}
	var closed bool
	if err := tx.QueryRow(ctx, "SELECT maintenance FROM public.runtime_control WHERE id=1").Scan(&closed); err != nil {
		return maintenanceUnavailable
	}
	if closed {
		return maintenance
	}
	return nil
}
