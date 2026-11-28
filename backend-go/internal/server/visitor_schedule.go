package server

import (
	"context"
	"crypto/rand"
	"errors"
	"math"
	"math/big"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type arrivalSchedule struct {
	context   string
	next      *time.Time
	remaining visitorFraction
	sequence  int64
	tutorial  bool
}

type scheduledArrival struct {
	slot            int64
	issued, expires time.Time
}

func loadSchedule(ctx context.Context, tx pgx.Tx, garden string) (arrivalSchedule, error) {
	var row arrivalSchedule
	err := tx.QueryRow(ctx, `SELECT context_id::text,next_at,remaining,sequence,tutorial_used FROM visitor_schedules WHERE garden_id=$1`, garden).
		Scan(&row.context, &row.next, &row.remaining, &row.sequence, &row.tutorial)
	return row, err
}

func jitterArrival() (*big.Rat, error) {
	draw, err := rand.Int(rand.Reader, big.NewInt(1_000_001))
	if err != nil {
		return nil, err
	}
	return big.NewRat(500_000+draw.Int64(), 1_000_000), nil
}

func advanceArrival(at time.Time, remaining, rate *big.Rat) (time.Time, error) {
	if rate.Sign() <= 0 {
		return time.Time{}, errors.New("invalid arrival rate")
	}
	wait := new(big.Rat).Mul(new(big.Rat).Quo(remaining, rate), big.NewRat(1_000_000, 1))
	micros := ceilRat(wait)
	if !micros.IsInt64() || micros.Int64() > math.MaxInt64/int64(time.Microsecond) {
		return time.Time{}, visitorContextUnavailable
	}
	return at.Add(time.Duration(micros.Int64()) * time.Microsecond), nil
}

func pauseSchedule(ctx context.Context, tx pgx.Tx, garden string, at time.Time) error {
	row, err := loadSchedule(ctx, tx, garden)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && row.next == nil {
		return nil
	}
	if err != nil {
		return err
	}
	context, err := readVisitorContext(ctx, tx, row.context)
	if err != nil {
		return err
	}
	var next *time.Time
	err = tx.QueryRow(ctx, `SELECT min(issued_at) FROM visitor_opportunities WHERE garden_id=$1 AND status='issued' AND issued_at>$2`, garden, at).Scan(&next)
	if err != nil {
		return err
	}
	if next == nil {
		next = row.next
	}
	var remaining *big.Rat
	if next.Before(at) {
		remaining, err = jitterArrival()
		if err != nil {
			return err
		}
	} else {
		remaining = new(big.Rat).Mul(visitorDuration(at, *next), context.active)
		if cap := big.NewRat(3, 2); remaining.Cmp(cap) > 0 {
			remaining = cap
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE visitor_opportunities SET status='expired' WHERE garden_id=$1 AND status='issued' AND issued_at>$2`, garden, at); err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `UPDATE visitor_schedules SET next_at=NULL,remaining=$2::jsonb WHERE garden_id=$1`, garden, visitorAmount(remaining))
	return err
}

func (v *visitorRuntime) schedule(ctx context.Context, tx pgx.Tx) error {
	if v.active == nil || v.active.protocol != 2 || v.config.protocol != 2 || v.config.active.Sign() == 0 {
		return nil
	}
	row, err := loadSchedule(ctx, tx, v.state.garden)
	if errors.Is(err, pgx.ErrNoRows) {
		row.context = v.config.id
		err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM visitor_opportunities WHERE garden_id=$1)`, v.state.garden).Scan(&row.tutorial)
		row.tutorial = row.tutorial || v.state.issued
	}
	if err != nil {
		return err
	}
	if row.context != v.config.id && row.next != nil {
		if err := pauseSchedule(ctx, tx, v.state.garden, v.at); err != nil {
			return err
		}
		row, err = loadSchedule(ctx, tx, v.state.garden)
		if err != nil {
			return err
		}
	}
	if row.next == nil || row.next.Before(v.at) {
		var remaining *big.Rat
		switch {
		case !row.tutorial:
			row.tutorial = true
			remaining = new(big.Rat).Mul(v.config.active, big.NewRat(5, 1))
			if remaining.Cmp(big.NewRat(1, 1)) > 0 {
				remaining = big.NewRat(1, 1)
			}
		case row.next == nil && row.remaining.Denominator != "":
			remaining, err = row.remaining.rat()
		default:
			remaining, err = jitterArrival()
		}
		if err != nil {
			return err
		}
		next, err := advanceArrival(v.at, remaining, v.config.active)
		if err != nil {
			return err
		}
		row.next = &next
	}
	if v.config.lifetimeMicros <= 0 || v.config.lifetimeMicros > 120_000_000 {
		return visitorContextUnavailable
	}
	lifetime := time.Duration(v.config.lifetimeMicros) * time.Microsecond
	horizon := v.active.Expires.Add(-lifetime)
	if !row.next.After(horizon) {
		rows, err := tx.Query(ctx, `SELECT slot,issued_at,expires_at FROM visitor_opportunities
			WHERE garden_id=$1 AND status='issued' ORDER BY issued_at,id`, v.state.garden)
		if err != nil {
			return err
		}
		pending, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (a scheduledArrival, err error) {
			err = r.Scan(&a.slot, &a.issued, &a.expires)
			return
		})
		if err != nil {
			return err
		}
		var batch pgx.Batch
		for len(pending) < 128 && !row.next.After(horizon) {
			var used [12]bool
			var firstExpiry time.Time
			for _, event := range pending {
				if row.next.Before(event.expires) {
					if firstExpiry.IsZero() || event.expires.Before(firstExpiry) {
						firstExpiry = event.expires
					}
					if event.slot < 0 && !row.next.Before(event.issued) {
						used[(-event.slot-1)%12] = true
					}
				}
			}
			found := false
			for range 12 {
				if row.sequence == math.MaxInt64 {
					return visitorContextUnavailable
				}
				row.sequence++
				if !used[(row.sequence-1)%12] {
					found = true
					break
				}
			}
			if !found {
				row.next = &firstExpiry
				break
			}
			event := scheduledArrival{-row.sequence, *row.next, row.next.Add(lifetime)}
			batch.Queue(`INSERT INTO visitor_opportunities
				(id,garden_id,session_id,context_id,slot,issued_at,expires_at,rule_version,tokens,status)
				VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'issued')`, uuid.New(), v.state.garden, v.active.ID, v.config.id,
				event.slot, event.issued, event.expires, v.config.rule, v.config.tokens)
			pending = append(pending, event)
			v.state.issued = true
			remaining, err := jitterArrival()
			if err != nil {
				return err
			}
			next, err := advanceArrival(*row.next, remaining, v.config.active)
			if err != nil {
				return err
			}
			row.next = &next
		}
		if batch.Len() > 0 {
			if err := tx.SendBatch(ctx, &batch).Close(); err != nil {
				return err
			}
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO visitor_schedules (garden_id,context_id,next_at,remaining,sequence,tutorial_used)
		VALUES ($1,$2,$3,'{}',$4,$5) ON CONFLICT (garden_id) DO UPDATE SET context_id=excluded.context_id,
		next_at=excluded.next_at,remaining=excluded.remaining,sequence=excluded.sequence,tutorial_used=excluded.tutorial_used`,
		v.state.garden, v.config.id, row.next, row.sequence, row.tutorial)
	return err
}

func (v *visitorRuntime) issueLegacyArrival(ctx context.Context, tx pgx.Tx) error {
	c := &v.config
	state := &v.state
	slot := v.at.Unix() / 30
	if c.protocol == 2 || v.active == nil || !v.legacyDue {
		return nil
	}
	state.slot = slot
	if c.probability.Sign() <= 0 {
		return nil
	}
	var pending bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM visitor_opportunities WHERE garden_id=$1 AND status='issued')`, state.garden).Scan(&pending); err != nil {
		return err
	}
	if pending {
		return nil
	}
	state.gap++
	draw, err := rand.Int(rand.Reader, c.probability.Denom())
	if err != nil {
		return err
	}
	if !(c.tutorial && !state.issued) && state.gap < c.gapSlots && draw.Cmp(c.probability.Num()) >= 0 {
		return nil
	}
	at := time.Unix(slot*30, 0).UTC()
	lifetime := time.Duration(c.lifetimeMicros) * time.Microsecond
	expires := at.Add(lifetime)
	if expires.After(v.active.Expires) {
		expires = v.active.Expires
	}
	if expires.Sub(v.at) < lifetime-time.Duration(c.heartbeat)*time.Second {
		return nil
	}
	_, err = tx.Exec(ctx, `INSERT INTO visitor_opportunities
		(id,garden_id,session_id,context_id,slot,issued_at,expires_at,rule_version,tokens,status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'issued')`, uuid.New(), state.garden, v.active.ID, c.id, slot, at, expires, c.rule, c.tokens)
	if err == nil {
		state.issued = true
		state.gap = 0
	}
	return err
}
