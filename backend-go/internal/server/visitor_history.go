package server

import (
	"context"
	"errors"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"
)

type visitorInterval struct {
	id, rule, mode                      string
	start, end                          time.Time
	before, after, generated, discarded visitorFraction
}

type visitorDayDelta struct {
	at                   time.Time
	micros               int64
	generated, discarded *big.Rat
}

func splitVisitorInterval(interval visitorInterval) ([]visitorDayDelta, error) {
	start, end := interval.start.UTC(), interval.end.UTC()
	bound := start.AddDate(0, 0, 366)
	if !start.Before(end) || end.After(bound) || interval.mode != "active" && interval.mode != "inactive" {
		return nil, errors.New("invalid visitor settlement interval")
	}
	if interval.mode == "inactive" && (interval.before.Denominator == "" || interval.after.Denominator == "" ||
		interval.generated.Denominator == "" || interval.discarded.Denominator == "") {
		return nil, errors.New("incomplete visitor settlement evidence")
	}
	total := end.Sub(start).Microseconds()
	before, err := interval.before.rat()
	if err != nil {
		return nil, err
	}
	after, err := interval.after.rat()
	if err != nil {
		return nil, err
	}
	generated, err := interval.generated.rat()
	if err != nil {
		return nil, err
	}
	discarded, err := interval.discarded.rat()
	if err != nil {
		return nil, err
	}
	retained := new(big.Rat).Sub(after, before)
	if interval.mode == "inactive" && (retained.Sign() < 0 || new(big.Rat).Sub(generated, retained).Cmp(discarded) != 0) {
		return nil, errHistoryReconciliation
	}
	var results []visitorDayDelta
	for start.Before(end) {
		day := time.Date(start.Year(), start.Month(), start.Day(), 0, 0, 0, 0, time.UTC)
		next := day.AddDate(0, 0, 1)
		if end.Before(next) {
			next = end
		}
		micros := next.Sub(start).Microseconds()
		amount := new(big.Rat).Mul(generated, big.NewRat(micros, total))
		delta := visitorDayDelta{day, micros, amount, new(big.Rat)}
		if interval.mode == "inactive" {
			kept := amount
			if retained.Cmp(kept) < 0 {
				kept = new(big.Rat).Set(retained)
			}
			delta.discarded.Sub(amount, kept)
			retained.Sub(retained, kept)
		}
		results = append(results, delta)
		start = next
	}
	return results, nil
}

type visitorHistoryKey struct {
	Day, Rule, Mode string
}

type visitorHistoryTotal struct {
	visitorHistoryKey
	Micros               int64
	Generated, Discarded visitorFraction
}

func compactVisitorIntervals(ctx context.Context, tx pgx.Tx, garden string, now time.Time) (int, error) {
	rows, err := tx.Query(ctx, `SELECT s.id::text,c.rule_version,s.mode,s.start_at,s.end_at,
		COALESCE(s.detail->'before','{}'),COALESCE(s.detail->'after','{}'),
		COALESCE(s.detail->'generated','{}'),COALESCE(s.detail->'discarded','{}')
		FROM visitor_settlements s JOIN visitor_contexts c ON c.id=s.context_id
		JOIN garden_visitor_state v ON v.garden_id=s.garden_id
		WHERE s.garden_id=$1 AND s.end_at<=v.settled_at AND s.end_at<=$2
			AND s.end_at-s.start_at<=interval '366 days' ORDER BY s.start_at,s.id LIMIT $3`,
		garden, now.Add(-7*24*time.Hour), workerSettings(ctx).BatchLimit)
	if err != nil {
		return 0, err
	}
	intervals, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (value visitorInterval, err error) {
		err = r.Scan(&value.id, &value.rule, &value.mode, &value.start, &value.end, &value.before, &value.after, &value.generated, &value.discarded)
		return
	})
	if err != nil || len(intervals) == 0 {
		return 0, err
	}
	totals := make(map[visitorHistoryKey]visitorDayDelta)
	ids := make([]string, 0, len(intervals))
	for _, interval := range intervals {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		deltas, err := splitVisitorInterval(interval)
		if err != nil {
			return 0, err
		}
		for _, delta := range deltas {
			key := visitorHistoryKey{delta.at.Format(time.DateOnly), interval.rule, interval.mode}
			if total, ok := totals[key]; ok {
				delta.generated.Add(delta.generated, total.generated)
				delta.discarded.Add(delta.discarded, total.discarded)
				delta.micros += total.micros
			}
			totals[key] = delta
		}
		ids = append(ids, interval.id)
	}
	if err := storeVisitorDayTotals(ctx, tx, garden, totals); err != nil {
		return 0, err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM visitor_settlements WHERE garden_id=$1 AND id=ANY($2::uuid[])`, garden, ids)
	if err == nil && tag.RowsAffected() != int64(len(ids)) {
		err = errors.New("visitor history changed during compaction")
	}
	return len(ids), err
}

func storeVisitorDayTotals(ctx context.Context, tx pgx.Tx, garden string, totals map[visitorHistoryKey]visitorDayDelta) error {
	keys := make([]visitorHistoryKey, 0, len(totals))
	for key := range totals {
		keys = append(keys, key)
	}
	rows, err := tx.Query(ctx, `SELECT h.day::text,h.rule_version,h.kind,h.generated,h.discarded
		FROM visitor_day_summaries h JOIN jsonb_to_recordset($2::jsonb) k("Day" date,"Rule" text,"Mode" text)
		ON (h.day,h.rule_version,h.kind)=(k."Day",k."Rule",k."Mode") WHERE h.garden_id=$1`, garden, keys)
	if err != nil {
		return err
	}
	for rows.Next() {
		var key visitorHistoryKey
		var generated, discarded visitorFraction
		if err := rows.Scan(&key.Day, &key.Rule, &key.Mode, &generated, &discarded); err != nil {
			rows.Close()
			return err
		}
		earned, err := generated.rat()
		if err != nil {
			rows.Close()
			return err
		}
		lost, err := discarded.rat()
		if err != nil {
			rows.Close()
			return err
		}
		total := totals[key]
		total.generated.Add(total.generated, earned)
		total.discarded.Add(total.discarded, lost)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	updates := make([]visitorHistoryTotal, 0, len(totals))
	for key, total := range totals {
		updates = append(updates, visitorHistoryTotal{key, total.micros, visitorAmount(total.generated), visitorAmount(total.discarded)})
	}
	_, err = tx.Exec(ctx, `INSERT INTO visitor_day_summaries(garden_id,day,rule_version,kind,microseconds,generated,discarded,visits,tokens)
		SELECT $1,"Day","Rule","Mode","Micros","Generated","Discarded",0,0
		FROM jsonb_to_recordset($2::jsonb) v("Day" date,"Rule" text,"Mode" text,"Micros" bigint,"Generated" jsonb,"Discarded" jsonb)
		ON CONFLICT(garden_id,day,rule_version,kind) DO UPDATE
		SET microseconds=visitor_day_summaries.microseconds+excluded.microseconds,
			generated=excluded.generated,discarded=excluded.discarded`, garden, updates)
	return err
}

func reconcileVisitorHistory(ctx context.Context, tx pgx.Tx, owner, garden string) error {
	var balanced bool
	err := tx.QueryRow(ctx, `
SELECT COALESCE(v.stored_whole=COALESCE((SELECT sum(visits) FROM visitor_storage_lots WHERE garden_id=$2),0),true)
 AND COALESCE(
	w.tokens=COALESCE((SELECT sum(amount) FROM visitor_wallet_entries WHERE owner_id=$1),0)
	  +COALESCE((SELECT sum(token_delta) FROM collection_events WHERE owner_id=$1),0)
	  +COALESCE((SELECT sum(tokens) FROM plant_sales WHERE owner_id=$1),0)
	  +COALESCE((SELECT sum(tokens) FROM item_sales WHERE owner_id=$1),0)
	AND w.hosted_active=COALESCE((SELECT sum((detail->>'visits')::numeric) FROM visitor_reward_events WHERE owner_id=$1 AND kind='active_welcome'),0)
	AND w.hosted_offline=COALESCE((SELECT sum((detail->>'visits')::numeric) FROM visitor_reward_events WHERE owner_id=$1 AND kind='offline_claim'),0)
	AND (NOT w.progression_initialized OR (
		w.step_gems_earned=COALESCE((SELECT sum(amount) FROM gem_grants WHERE owner_id=$1),0)
		AND w.step_gems_earned=COALESCE((SELECT activity_steps/10000 FROM player_progress WHERE owner_id=$1),0)
		AND w.lifetime_gems_earned=w.step_gems_earned
		  +COALESCE((SELECT sum(amount) FROM milestone_bonus_grants WHERE owner_id=$1),0)
		  +COALESCE((SELECT sum(amount) FROM expedition_bonus_grants WHERE owner_id=$1),0)
		AND w.gems=w.lifetime_gems_earned+COALESCE((SELECT sum(gem_delta) FROM collection_events WHERE owner_id=$1),0))), true)
FROM users u LEFT JOIN garden_visitor_state v ON v.garden_id=$2 LEFT JOIN visitor_wallets w ON w.owner_id=u.id WHERE u.id=$1`, owner, garden).Scan(&balanced)
	if err != nil {
		return err
	}
	if !balanced {
		return errHistoryReconciliation
	}
	return nil
}
