package server

import (
	"context"
	"errors"
	"math/big"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

type visitorFraction struct {
	Numerator   string `json:"numerator"`
	Denominator string `json:"denominator"`
}

func (f visitorFraction) rat() (*big.Rat, error) {
	if f.Numerator == "" && f.Denominator == "" {
		return new(big.Rat), nil
	}
	n, nOk := new(big.Int).SetString(f.Numerator, 10)
	d, dOk := new(big.Int).SetString(f.Denominator, 10)
	if !nOk || !dOk || n.Sign() < 0 || d.Sign() <= 0 {
		return nil, errors.New("invalid visitor fraction")
	}
	return new(big.Rat).SetFrac(n, d), nil
}

func visitorAmount(value *big.Rat) visitorFraction {
	return visitorFraction{value.Num().String(), value.Denom().String()}
}

type visitorContext struct {
	id                           string
	rule                         string
	fixture                      bool
	attraction                   string
	capacity                     int64
	protocol                     int
	heartbeat                    int
	lease                        int
	lifetimeMicros               int64
	tokens                       int64
	gapSlots                     int
	tutorial                     bool
	expiry                       *time.Time
	offline, active, probability *big.Rat
}

func readVisitorContext(ctx context.Context, tx pgx.Tx, id string) (visitorContext, error) {
	var c visitorContext
	var offline, active, probability visitorFraction
	err := tx.QueryRow(ctx, `
SELECT c.id::text,c.rule_version,r.is_fixture,c.snapshot->>'attraction',(c.snapshot->>'capacity')::bigint,
	COALESCE((c.snapshot #>> '{rules,arrival_protocol}')::int,1),(c.snapshot #>> '{rules,heartbeat_seconds}')::int,
	(c.snapshot #>> '{rules,lease_seconds}')::int,
	COALESCE((c.snapshot->>'welcomeDurationMicroseconds')::bigint,
		(c.snapshot #>> '{rules,opportunity_seconds}')::bigint * 1000000),
	(c.snapshot #>> '{rules,tokens_per_visit}')::bigint,
	(c.snapshot #>> '{rules,gap_slots}')::int,
	COALESCE((c.snapshot #>> '{rules,tutorial_first_visitor}')::bool,false),
	NULLIF(c.snapshot->>'dailySkillExpiresAt','')::timestamptz,
	c.snapshot->'offlineRate',COALESCE(c.snapshot->'activeRate','{}'),c.snapshot->'probability'
FROM visitor_contexts c JOIN visitor_rules r ON r.version=c.rule_version WHERE c.id=$1`, id).
		Scan(&c.id, &c.rule, &c.fixture, &c.attraction, &c.capacity, &c.protocol, &c.heartbeat, &c.lease,
			&c.lifetimeMicros, &c.tokens, &c.gapSlots, &c.tutorial, &c.expiry, &offline, &active, &probability)
	if err != nil {
		return c, err
	}
	if c.offline, err = offline.rat(); err != nil {
		return c, err
	}
	if c.probability, err = probability.rat(); err != nil {
		return c, err
	}
	if active.Denominator == "" {
		c.active = new(big.Rat).Quo(c.probability, big.NewRat(30, 1))
	} else if c.active, err = active.rat(); err != nil {
		return c, err
	}
	return c, nil
}

var visitorContextUnavailable = &apiError{http.StatusServiceUnavailable, "visitor_context_unavailable", "Visitor context requires reconciliation"}

// Filtering in PostgreSQL avoids fetching active/future opportunity rows simply
// to inspect their expiry. A closing session also invalidates future arrivals.
func expireVisitorOpportunities(ctx context.Context, tx pgx.Tx, garden string, at time.Time, closing bool) error {
	query := "UPDATE visitor_opportunities SET status='expired' WHERE garden_id=$1 AND status='issued'"
	args := []any{garden}
	if !closing {
		query += " AND expires_at<=$2"
		args = append(args, at)
	}
	_, err := tx.Exec(ctx, query, args...)
	return err
}
