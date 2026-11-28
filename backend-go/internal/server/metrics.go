package server

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type requestMetrics struct {
	statements  int
	resultBytes int
}

type measuredTx struct {
	pgx.Tx
	metrics *requestMetrics
}

func (tx measuredTx) Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error) {
	tx.metrics.statements++
	return tx.Tx.Exec(ctx, sql, args...)
}

func (tx measuredTx) Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error) {
	tx.metrics.statements++
	rows, err := tx.Tx.Query(ctx, sql, args...)
	if err != nil {
		return rows, err
	}
	return measuredRows{rows, tx.metrics}, nil
}

func (tx measuredTx) QueryRow(ctx context.Context, sql string, args ...any) pgx.Row {
	rows, err := tx.Query(ctx, sql, args...)
	return measuredRow{rows, err}
}

func (tx measuredTx) SendBatch(ctx context.Context, batch *pgx.Batch) pgx.BatchResults {
	tx.metrics.statements += batch.Len()
	return tx.Tx.SendBatch(ctx, batch)
}

type measuredRows struct {
	pgx.Rows
	metrics *requestMetrics
}

func (r measuredRows) Next() bool {
	if !r.Rows.Next() {
		return false
	}
	for _, value := range r.Rows.RawValues() {
		r.metrics.resultBytes += len(value)
	}
	return true
}

type measuredRow struct {
	rows pgx.Rows
	err  error
}

func (r measuredRow) Scan(dest ...any) error {
	if r.err != nil {
		return r.err
	}
	defer r.rows.Close()
	if !r.rows.Next() {
		if err := r.rows.Err(); err != nil {
			return err
		}
		return pgx.ErrNoRows
	}
	if err := r.rows.Scan(dest...); err != nil {
		return err
	}
	r.rows.Close()
	return r.rows.Err()
}
