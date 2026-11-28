package server

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type gardenPlantFact struct {
	id            uuid.UUID
	growth, stage string
	attraction    int64
	profile       packRef
	skill         skillPlant
}

type gardenCurve struct {
	Strategy        string `json:"strategy"`
	K               int64  `json:"k_micro_units"`
	Starter         string `json:"starter_probability"`
	Max             string `json:"maximum_probability"`
	Slot            int64  `json:"slot_seconds"`
	OfflineFraction string `json:"offline_fraction"`
	OfflineCap      string `json:"offline_rate_cap_per_second"`
	BaseCapacity    int64  `json:"base_capacity"`
	MaxCapacity     int64  `json:"maximum_capacity"`
	Knee            int64  `json:"knee_micro_units"`
	KneeProbability string `json:"knee_probability"`
	TailScale       int64  `json:"tail_scale_micro_units"`
	Multiplier      string `json:"arrival_rate_multiplier"`
}

type gardenVisitorRules struct {
	Curve        gardenCurve `json:"curve"`
	Protocol     int         `json:"arrival_protocol"`
	CapacityFlat int         `json:"capacity_flat_multiplier"`
	Welcome      int         `json:"opportunity_seconds"`
	Heartbeat    int         `json:"heartbeat_seconds"`
	Lease        int         `json:"lease_seconds"`
	Slot         int         `json:"slot_seconds"`
}

type gardenStrategy struct {
	rule, policy, day             string
	fixture, levelPolicy          bool
	rules                         json.RawMessage
	caps                          map[string]any
	def                           gardenVisitorRules
	base, maximum, level, flights int64
	until, midnight               time.Time
}

func (s *gardenStrategy) setProgressLevel(level int64) {
	s.level = level
	s.base = offlineCapacity(level)
	s.maximum = 3 * s.base
}

func readGardenStrategy(ctx context.Context, tx pgx.Tx, owner string, at time.Time) (gardenStrategy, error) {
	var s gardenStrategy
	var caps json.RawMessage
	var upcoming *time.Time
	var zone string
	var steps int64
	err := tx.QueryRow(ctx, `SELECT COALESCE(r.version,''),COALESCE(r.is_fixture,false),r.rules,
		COALESCE(r.rules->>'skill_policy_version','b8-caps-v1'),c.rules,u.game_timezone,
		COALESCE(d.flights,0),COALESCE(p.activity_steps,0),
		EXISTS(SELECT 1 FROM level_benefits_policy WHERE version='level-benefits-v1' AND effective_at<=$2),
		(SELECT min(effective_at) FROM visitor_rules WHERE effective_at>$2)
		FROM users u LEFT JOIN LATERAL (SELECT version,is_fixture,rules FROM visitor_rules
			WHERE effective_at<=$2 ORDER BY effective_at DESC LIMIT 1) r ON true
		LEFT JOIN skill_policies c ON c.version=COALESCE(r.rules->>'skill_policy_version','b8-caps-v1')
		LEFT JOIN daily_skill_activity d ON d.owner_id=u.id AND d.game_date=($2::timestamptz AT TIME ZONE u.game_timezone)::date
		LEFT JOIN player_progress p ON p.owner_id=u.id WHERE u.id=$1`, owner, at).
		Scan(&s.rule, &s.fixture, &s.rules, &s.policy, &caps, &zone, &s.flights, &steps, &s.levelPolicy, &upcoming)
	if err != nil {
		return s, err
	}
	if len(caps) == 0 || json.Unmarshal(caps, &s.caps) != nil || s.caps == nil {
		return s, &apiError{503, "skill_policy_unavailable", "Skill rules require maintenance"}
	}
	location, err := time.LoadLocation(zone)
	if err != nil {
		return s, gardenPresentationUnavailable
	}
	local := at.In(location)
	s.day = local.Format("2006-01-02")
	s.until = time.Date(local.Year(), local.Month(), local.Day()+1, 0, 0, 0, 0, location).UTC()
	s.midnight = s.until
	if upcoming != nil && upcoming.Before(s.until) {
		s.until = upcoming.UTC()
	}
	s.def.CapacityFlat = 1
	if s.rule == "" {
		return s, nil
	}
	s.def.Protocol, s.def.Heartbeat, s.def.Lease, s.def.Welcome, s.def.Slot = 1, 10, 45, 20, 30
	s.def.Curve.Strategy, s.def.Curve.Multiplier, s.def.Curve.Knee, s.def.Curve.KneeProbability = "bounded_attraction_v1", "1", 300_000_000, "0.6"
	s.def.Curve.TailScale = 120_000_000
	if json.Unmarshal(s.rules, &s.def) != nil || s.def.Slot != 30 || s.def.Curve.Slot != 30 ||
		s.def.Heartbeat < 5 || s.def.Heartbeat > 15 || s.def.Lease < 30 || s.def.Lease > 120 ||
		s.def.Welcome < s.def.Heartbeat+5 || s.def.Welcome > 25 || s.def.Welcome+s.def.Heartbeat > s.def.Lease ||
		s.def.Curve.BaseCapacity < 0 || s.def.Curve.MaxCapacity < s.def.Curve.BaseCapacity ||
		s.def.Curve.MaxCapacity > 1_000_000_000 || s.def.CapacityFlat < 1 || s.def.CapacityFlat > 10 {
		return s, &apiError{503, "invalid_visitor_rules", "Visitor rules require maintenance"}
	}
	s.base, s.maximum = s.def.Curve.BaseCapacity, s.def.Curve.MaxCapacity
	if s.levelPolicy {
		s.level = levelForSteps(steps)
		s.base = 600 + 75*min(s.level-1, 4) + 60*min(max(s.level-5, 0), 15)
		s.maximum = 3 * s.base
	}
	return s, nil
}

func (s gardenStrategy) document() map[string]any {
	var rule any
	if s.rule != "" {
		rule = s.rule
	}
	return map[string]any{"schemaVersion": 1, "policyVersion": s.policy, "caps": s.caps, "dailyFlights": s.flights,
		"baseCapacity": s.base, "maximumCapacity": s.maximum, "capacityFlatMultiplier": s.def.CapacityFlat,
		"welcomeSeconds": s.def.Welcome, "gameDate": s.day, "validUntil": pythonTime(s.until), "ruleVersion": rule}
}

func pythonTime(t time.Time) string {
	if t.Nanosecond() != 0 {
		return t.UTC().Format("2006-01-02T15:04:05.000000+00:00")
	}
	return t.UTC().Format("2006-01-02T15:04:05+00:00")
}

type gardenEvaluation struct {
	attraction, capacity, welcomeMicros int64
	facts                               []gardenPlantFact
	summary                             map[string]any
	dailyFlightSource                   bool
}

func (s *Server) evaluateGarden(ctx context.Context, tx pgx.Tx, config gardenStrategy, facts gardenFacts) (gardenEvaluation, error) {
	if err := s.loadGardenSkills(ctx, tx, facts); err != nil {
		return gardenEvaluation{}, err
	}
	return evaluateGarden(config, facts)
}

func evaluateGarden(config gardenStrategy, facts gardenFacts) (gardenEvaluation, error) {
	s, err := buildSkillSnapshot(config, facts)
	if err != nil {
		return gardenEvaluation{}, err
	}
	result := gardenEvaluation{facts: s.facts.plants, dailyFlightSource: s.dailyFlightSource}
	amount, err := s.attraction()
	if err != nil {
		return result, err
	}
	attraction := new(big.Int).Quo(amount.Num(), amount.Denom())
	capacity := s.capacity()
	copies := new(big.Int).Quo(capacity.Num(), capacity.Denom())
	welcome := s.welcomeMicros()
	if !attraction.IsInt64() || !copies.IsInt64() || !welcome.IsInt64() {
		return result, invalidSkills
	}
	result.attraction, result.capacity, result.welcomeMicros = attraction.Int64(), copies.Int64(), welcome.Int64()
	result.summary, err = s.presentation()
	return result, err
}

func (e gardenEvaluation) preview(s gardenStrategy, g gardenRecord, catalogue string, p gardenProposal) (map[string]any, string, error) {
	result := map[string]any{"totalAttractionMicroUnits": numberString(e.attraction), "skillSummary": e.summary,
		"offlineCapacity": e.capacity, "context": s.document()}
	growth, plants, items := make([][]string, 0, len(e.facts)), [][]string{}, [][]string{}
	for _, plant := range e.facts {
		growth = append(growth, []string{plant.id.String(), plant.growth})
	}
	for _, id := range p.ordered(p.final) {
		point := p.final[id]
		value := []string{id.String(), gardenFixed(point.x, 3), gardenFixed(point.y, 3), gardenFixed(point.rotation, 2)}
		if p.copies[id].item {
			items = append(items, value)
		} else {
			plants = append(plants, value)
		}
	}
	proof := map[string]any{"result": result, "growth": growth, "catalog": catalogue, "layout": g.layout, "plants": plants, "items": items}
	encoded, err := canonicalJSON(proof)
	if err != nil {
		return nil, "", err
	}
	// The preview proof uses the reference serializer's comma and colon spaces.
	var spaced bytes.Buffer
	var quoted, escaped bool
	for _, ch := range encoded {
		spaced.WriteByte(ch)
		if quoted {
			if escaped {
				escaped = false
			} else if ch == '\\' {
				escaped = true
			} else if ch == '"' {
				quoted = false
			}
		} else if ch == '"' {
			quoted = true
		} else if ch == ',' || ch == ':' {
			spaced.WriteByte(' ')
		}
	}
	digest := sha256.Sum256(spaced.Bytes())
	result["fingerprint"] = hex.EncodeToString(digest[:])
	return result, skillSignature(e), nil
}

func gardenVisitorRates(curve gardenCurve, attraction int64, planted bool) (probability, active, offline *big.Rat, err error) {
	parse := func(text string) *big.Rat {
		n, ok := new(big.Rat).SetString(text)
		if !ok || n.Sign() < 0 {
			err = visitorContextUnavailable
			return new(big.Rat)
		}
		return n
	}
	starter, maximum, offlineFraction, offlineCap, multiplier := parse(curve.Starter), parse(curve.Max),
		parse(curve.OfflineFraction), parse(curve.OfflineCap), parse(curve.Multiplier)
	one := big.NewRat(1, 1)
	if err != nil || starter.Sign() == 0 || starter.Cmp(maximum) > 0 || maximum.Cmp(one) > 0 ||
		offlineFraction.Cmp(one) >= 0 || multiplier.Sign() == 0 || multiplier.Cmp(big.NewRat(10, 1)) > 0 ||
		curve.K <= 0 || curve.Slot != 30 {
		return nil, nil, nil, visitorContextUnavailable
	}
	probability = new(big.Rat)
	if planted {
		switch curve.Strategy {
		case "bounded_attraction_v1":
			at := big.NewRat(attraction, 1)
			part := new(big.Rat).Quo(at, new(big.Rat).Add(at, big.NewRat(curve.K, 1)))
			probability.Mul(maximum, part)
			if probability.Cmp(starter) < 0 {
				probability.Set(starter)
			}
		case "linear_softcap_v2":
			knee := parse(curve.KneeProbability)
			if err != nil || curve.Knee <= 0 || curve.TailScale <= 0 || starter.Cmp(knee) >= 0 || knee.Cmp(maximum) >= 0 {
				return nil, nil, nil, visitorContextUnavailable
			}
			if attraction <= curve.Knee {
				probability.Sub(knee, starter).Mul(probability, big.NewRat(attraction, curve.Knee)).Add(probability, starter)
			} else {
				decay := softcapDecay(big.NewRat(attraction-curve.Knee, curve.TailScale))
				probability.Sub(maximum, new(big.Rat).Mul(new(big.Rat).Sub(maximum, knee), decay))
			}
		default:
			return nil, nil, nil, visitorContextUnavailable
		}
	}
	active = new(big.Rat).Mul(probability, multiplier)
	active.Quo(active, big.NewRat(curve.Slot, 1))
	offline = new(big.Rat).Mul(active, offlineFraction)
	if offline.Cmp(offlineCap) > 0 {
		offline.Set(offlineCap)
	}
	return probability, active, offline, nil
}

// The published curve freezes Decimal's 36-digit decay in the visitor context.
func softcapDecay(distance *big.Rat) *big.Rat {
	distance = smallerRat(distance, big.NewRat(60, 1))
	rounded, _ := new(big.Rat).SetString(fractionDecimal(distance, 36))
	const precision = 256
	work := func() *big.Float { return new(big.Float).SetPrec(precision) }
	y := work().Quo(work().SetRat(rounded), work().SetInt64(64))
	sum, term := work().SetInt64(1), work().SetInt64(1)
	for i := int64(1); i <= 60; i++ {
		term.Mul(term, y).Quo(term, work().SetInt64(i))
		sum.Add(sum, term)
	}
	for range 6 {
		sum.Mul(sum, sum)
	}
	decay, _ := work().Quo(work().SetInt64(1), sum).Rat(nil)
	frozen, _ := new(big.Rat).SetString(fractionDecimal(decay, 36))
	return frozen
}

func (s *Server) gardenVisitorSnapshot(config gardenStrategy, e gardenEvaluation) (map[string]any, error) {
	if config.rule == "" {
		return nil, &apiError{503, "visitor_rules_unavailable", "Visitor rules are unavailable"}
	}
	if config.fixture && s.Environment != "local" && s.Environment != "test" {
		return nil, &apiError{503, "fixture_visitor_rules_disabled", "Development visitor rules are disabled"}
	}
	if config.def.Protocol != 1 && config.def.Protocol != 2 || config.def.Protocol == 1 && config.def.Curve.Multiplier != "1" {
		return nil, visitorContextUnavailable
	}
	probability, active, offline, err := gardenVisitorRates(config.def.Curve, e.attraction, len(e.facts) > 0)
	if err != nil {
		return nil, err
	}
	sources := make([]map[string]any, 0, len(e.facts))
	for _, plant := range e.facts {
		sources = append(sources, map[string]any{"plantId": plant.id, "stage": plant.stage,
			"attractionMicroUnits": numberString(plant.attraction),
			"profile":              map[string]any{"id": plant.profile.ID, "version": plant.profile.Version}})
	}
	snapshot := map[string]any{"sources": sources, "attraction": numberString(e.attraction), "capacity": e.capacity,
		"rules": config.rules, "offlineRate": visitorAmount(offline), "activeRate": visitorAmount(active), "probability": visitorAmount(probability),
		"welcomeDurationMicroseconds": e.welcomeMicros, "itemDurationPolicy": "garden-items-v1:+25%", "skills": e.summary}
	if e.welcomeMicros+int64(config.def.Heartbeat)*1_000_000 > int64(config.def.Lease)*1_000_000 {
		return nil, &apiError{503, "invalid_visitor_rules", "Lease must cover the effective welcome duration"}
	}
	if e.dailyFlightSource && config.flights > 0 {
		snapshot["dailySkillExpiresAt"] = pythonTime(config.midnight)
	}
	if config.levelPolicy {
		snapshot["levelBenefits"] = map[string]any{"version": "level-benefits-v1", "level": config.level, "base": config.base}
	}
	return snapshot, nil
}

func (s *Server) createGardenContext(ctx context.Context, tx pgx.Tx, garden, owner string, at time.Time) (string, error) {
	g := gardenRecord{id: garden, owner: owner}
	proposal, err := loadGardenCopies(ctx, tx, g, gardenRequest{})
	if err != nil {
		return "", err
	}
	facts := proposal.facts(proposal.initial)
	config, err := readGardenStrategy(ctx, tx, owner, at)
	if err != nil {
		return "", err
	}
	view, err := s.evaluateGarden(ctx, tx, config, facts)
	if err != nil {
		return "", err
	}
	snapshot, err := s.gardenVisitorSnapshot(config, view)
	if err != nil {
		return "", err
	}
	return saveGardenContext(ctx, tx, garden, at, config.rule, snapshot)
}

func saveGardenContext(ctx context.Context, tx pgx.Tx, garden string, at time.Time, rule string, snapshot map[string]any) (string, error) {
	id := uuid.NewString()
	_, err := tx.Exec(ctx, `INSERT INTO visitor_contexts (id,garden_id,effective_at,rule_version,snapshot)
		VALUES ($1,$2,$3,$4,$5::jsonb)`, id, garden, at, rule, snapshot)
	return id, err
}

func (s *Server) replaceGardenContext(ctx context.Context, tx pgx.Tx, v *visitorRuntime, config gardenStrategy, view gardenEvaluation) error {
	snapshot, err := s.gardenVisitorSnapshot(config, view)
	if err != nil {
		return err
	}
	var same bool
	err = tx.QueryRow(ctx, "SELECT rule_version=$2 AND snapshot=$3::jsonb FROM visitor_contexts WHERE id=$1",
		v.state.context, config.rule, snapshot).Scan(&same)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if !same {
		id, err := saveGardenContext(ctx, tx, v.state.garden, v.at, config.rule, snapshot)
		if err != nil {
			return err
		}
		if err := pauseSchedule(ctx, tx, v.state.garden, v.at); err != nil {
			return err
		}
		v.config, err = s.cachedVisitorContext(ctx, tx, id)
		if err != nil {
			return err
		}
		v.state.context = id
	}
	if v.state.version == math.MaxInt64 {
		return visitorContextUnavailable
	}
	v.state.version++
	if err := v.schedule(ctx, tx); err != nil {
		return err
	}
	return v.persist(ctx, tx)
}

func checkGardenProof(req gardenRequest, result map[string]any, signature string) error {
	if strings.HasPrefix(req.signature, "sha256:") {
		digest := sha256.Sum256([]byte(signature))
		signature = "sha256:" + hex.EncodeToString(digest[:])
	}
	if req.fingerprint != "" && result["fingerprint"] != req.fingerprint || req.signature != "" && signature != req.signature {
		return &apiError{http.StatusConflict, "strategy_changed", "Garden effects changed. Review before saving."}
	}
	return nil
}
