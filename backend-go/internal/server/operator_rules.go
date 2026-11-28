package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

type VisitorRulePublication struct {
	Version    string
	Effective  time.Time
	Fixture    bool
	Definition json.RawMessage
}

type visitorRuleDefinition struct {
	gardenVisitorRules
	SkillPolicyVersion string `json:"skill_policy_version"`
	GapSlots           int    `json:"gap_slots"`
	TokensPerVisit     int    `json:"tokens_per_visit"`
	Tutorial           bool   `json:"tutorial_first_visitor"`
}

func publishVisitorRules(ctx context.Context, tx pgx.Tx, p VisitorRulePublication) (map[string]any, error) {
	if !packIdentifier.MatchString(p.Version) || p.Effective.IsZero() {
		return nil, errors.New("specify a valid rule version and effective timestamp")
	}
	p.Effective = p.Effective.Truncate(time.Microsecond)
	rules := visitorRuleDefinition{
		gardenVisitorRules: gardenVisitorRules{
			Curve: gardenCurve{Strategy: "bounded_attraction_v1", Knee: 300_000_000, KneeProbability: "0.6",
				TailScale: 120_000_000, Multiplier: "1"},
			Protocol: 1, CapacityFlat: 1, Welcome: 20, Heartbeat: 10, Lease: 45, Slot: 30,
		},
		SkillPolicyVersion: "b8-caps-v1", GapSlots: 3, TokensPerVisit: 1,
	}
	decoder := json.NewDecoder(bytes.NewReader(p.Definition))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&rules); err != nil {
		return nil, err
	}
	if (rules.Protocol != 1 && rules.Protocol != 2) || (rules.Protocol == 1 && rules.Curve.Multiplier != "1") ||
		rules.Slot != 30 || rules.Curve.Slot != 30 || rules.Heartbeat < 5 || rules.Heartbeat > 15 ||
		rules.Lease < 30 || rules.Lease > 120 || rules.Welcome < rules.Heartbeat+5 || rules.Welcome > 25 ||
		rules.Welcome+rules.Heartbeat > rules.Lease || rules.GapSlots < 1 || rules.GapSlots > 20 ||
		rules.TokensPerVisit < 1 || rules.TokensPerVisit > 1_000_000 || rules.CapacityFlat < 1 || rules.CapacityFlat > 10 ||
		rules.Curve.BaseCapacity < 0 || rules.Curve.MaxCapacity < rules.Curve.BaseCapacity || rules.Curve.MaxCapacity > 1_000_000_000 ||
		rules.Curve.Knee < 1 || rules.Curve.TailScale < 1 || len(rules.SkillPolicyVersion) == 0 || len(rules.SkillPolicyVersion) > 100 {
		return nil, errors.New("invalid visitor rules or arrival timing")
	}
	if _, _, _, err := gardenVisitorRates(rules.Curve, 100_000_000, true); err != nil {
		return nil, errors.New("invalid visitor rule curve")
	}
	var matches bool
	err := tx.QueryRow(ctx, `SELECT (effective_at,is_fixture,rules)=($2,$3,$4::jsonb)
		FROM visitor_rules WHERE version=$1`, p.Version, p.Effective, p.Fixture, rules).Scan(&matches)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	result := map[string]any{"version": p.Version, "effectiveAt": p.Effective.UTC(), "alreadyPublished": err == nil}
	if err == nil {
		if !matches {
			return nil, errors.New("published visitor rules are immutable")
		}
		return result, nil
	}
	var caps map[string]any
	err = tx.QueryRow(ctx, "SELECT rules FROM skill_policies WHERE version=$1", rules.SkillPolicyVersion).Scan(&caps)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errors.New("visitor rules require an existing skill policy")
	}
	if err != nil {
		return nil, err
	}
	if _, err := readSkillCaps(caps); err != nil {
		return nil, err
	}
	var future bool
	err = tx.QueryRow(ctx, `SELECT $1>GREATEST(clock_timestamp(),
		(SELECT max(settled_at) FROM garden_visitor_state))
		AND NOT EXISTS(SELECT 1 FROM visitor_rules WHERE effective_at=$1)`, p.Effective).Scan(&future)
	if err != nil {
		return nil, err
	}
	if !future {
		return nil, errors.New("visitor rules require an unused effective time after the clock and all settled visitor history")
	}
	_, err = tx.Exec(ctx, "INSERT INTO visitor_rules(version,effective_at,is_fixture,rules) VALUES($1,$2,$3,$4)",
		p.Version, p.Effective, p.Fixture, rules)
	return result, err
}
