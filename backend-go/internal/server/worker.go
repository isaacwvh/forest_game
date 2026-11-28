package server

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const workerLock int64 = 711023002

var errHistoryReconciliation = errors.New("history reconciliation failed")

type workerReportKey struct{}

type WorkerConfig struct {
	Budget     time.Duration
	BatchLimit int
	Responses  bool
	Visitors   bool
	Growth     bool
	Metrics    bool
}

var defaultWorkerConfig = WorkerConfig{
	Budget: 40 * time.Second, BatchLimit: historyLimit, Responses: true, Visitors: true, Growth: true,
}

type workerExecution struct {
	config  WorkerConfig
	report  workerReport
	metrics requestMetrics
}

func workerSettings(ctx context.Context) WorkerConfig {
	if execution, _ := ctx.Value(workerReportKey{}).(*workerExecution); execution != nil {
		return execution.config
	}
	return defaultWorkerConfig
}

type requestHistoryCounts struct {
	Examined        int64 `json:"examined"`
	Backfilled      int64 `json:"backfilled"`
	Compacted       int64 `json:"compacted"`
	DeletedControls int64 `json:"deletedControls"`
}

type historyWorkerReport struct {
	Settlements   int64                `json:"settlements"`
	Earnings      int64                `json:"earnings"`
	Opportunities int64                `json:"opportunities"`
	Dependencies  int64                `json:"dependencies"`
	GrowthCredits int64                `json:"growthCredits"`
	Recaps        int64                `json:"recaps"`
	GrowthEvents  int64                `json:"growthEvents"`
	Provenance    int64                `json:"provenance"`
	DryRun        bool                 `json:"dryRun"`
	Responses     requestHistoryCounts `json:"responses"`
}

type workerReport struct {
	Status                string  `json:"status"`
	Reason                string  `json:"reason,omitempty"`
	ElapsedSeconds        float64 `json:"elapsedSeconds"`
	CommittedTransactions int     `json:"committedTransactions"`
	*historyWorkerReport
	Queries                 *int  `json:"queries,omitempty"`
	DBResultValueBytes      *int  `json:"dbResultValueBytes,omitempty"`
	DBResultSampleTruncated *bool `json:"dbResultSampleTruncated,omitempty"`
}

func workerReportFrom(ctx context.Context) *historyWorkerReport {
	if execution, _ := ctx.Value(workerReportKey{}).(*workerExecution); execution != nil {
		return execution.report.historyWorkerReport
	}
	return nil
}

func (s *Server) WorkerHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health/live", func(w http.ResponseWriter, _ *http.Request) {
		reply(w, 200, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("POST /tasks/shop", s.reportedWorker(shopTick, "shop"))
	mux.HandleFunc("POST /tasks/history", s.reportedWorker(runHistory, "history"))
	return mux
}

func (s *Server) worker(run func(context.Context, pgx.Tx) (string, error)) http.HandlerFunc {
	return s.reportedWorker(run, "")
}

func (s *Server) reportedWorker(run func(context.Context, pgx.Tx) (string, error), task string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		config := defaultWorkerConfig
		if s.WorkerConfig != nil {
			config = *s.WorkerConfig
		}
		ctx, cancel := context.WithTimeout(r.Context(), config.Budget)
		defer cancel()
		execution := workerExecution{config: config}
		report := &execution.report
		if task == "history" {
			report.historyWorkerReport = &historyWorkerReport{}
		}
		ctx = context.WithValue(ctx, workerReportKey{}, &execution)
		report.Status, report.Reason = s.workerPass(ctx, run)
		report.ElapsedSeconds = time.Since(started).Seconds()
		if config.Metrics {
			truncated := false
			report.Queries = &execution.metrics.statements
			report.DBResultValueBytes = &execution.metrics.resultBytes
			report.DBResultSampleTruncated = &truncated
		}
		if report.CommittedTransactions == 0 {
			report.historyWorkerReport = nil
		}
		code := http.StatusOK
		if report.Status != "ok" && report.Status != "ready" && report.Status != "skipped" {
			code = http.StatusServiceUnavailable
		}
		w.Header().Set("Cache-Control", "no-store")
		reply(w, code, report)
		if s.WorkerConfig != nil {
			slog.Info("worker completed", "task", task, "http_status", code,
				"status", report.Status, "reason", report.Reason, "elapsed_seconds", report.ElapsedSeconds,
				"committed_transactions", report.CommittedTransactions, "history", report.historyWorkerReport)
		}
	}
}

func (s *Server) workerPass(ctx context.Context, run func(context.Context, pgx.Tx) (string, error)) (string, string) {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return "retry", ""
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Second)
		defer cancel()
		_ = tx.Rollback(cleanup)
	}()
	// The lock is released with this transaction on either success or failure.
	execution, _ := ctx.Value(workerReportKey{}).(*workerExecution)
	if execution != nil && execution.config.Metrics {
		tx = measuredTx{Tx: tx, metrics: &execution.metrics}
	}
	var locked bool
	err = tx.QueryRow(ctx, `SELECT pg_try_advisory_xact_lock($1) FROM public.schema_migrations
		WHERE version=$2 AND NOT dirty`, workerLock, SchemaVersion).Scan(&locked)
	if errors.Is(err, pgx.ErrNoRows) {
		return "failed", ""
	}
	if err != nil {
		return "retry", ""
	}
	if !locked {
		return "skipped", "busy"
	}
	if err := admit(ctx, tx); err != nil {
		if errors.Is(err, maintenance) {
			return "skipped", "maintenance"
		}
		return "retry", ""
	}
	status, err := run(ctx, tx)
	var dbError *pgconn.PgError
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded) ||
		(errors.As(err, &dbError) && dbError.Code == "57014") {
		return "budget_exhausted", ""
	}
	if errors.Is(err, errHistoryReconciliation) {
		return "reconciliation_failed", ""
	}
	if err != nil || ctx.Err() != nil {
		return "retry", ""
	}
	if err := tx.Commit(ctx); err != nil {
		return "retry", ""
	}
	if execution != nil {
		execution.report.CommittedTransactions = 1
	}
	return status, ""
}
