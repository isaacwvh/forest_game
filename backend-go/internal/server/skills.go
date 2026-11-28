package server

import (
	"cmp"
	"encoding/json"
	"maps"
	"math/big"
	"slices"
	"strings"

	"github.com/google/uuid"
)

type skillSelector struct {
	Species, Variants, Stages, Tags []string
}

type skillEffect struct {
	ComponentVersion                                    int
	ID, Name, Description                               string
	System, Scope, Metric, Target, Operation            string
	MinimumStage, StackingGroup, StackingRule, StepBand string
	Recipients                                          *skillSelector
	Condition                                           *struct {
		Type     string
		Selector *skillSelector
		Minimum  int
	}
	Magnitude struct {
		Type, Value string
		Selector    *skillSelector
		Maximum     string
	}
}

type skillPlant struct {
	species, variant string
	tags             []string
	behaviour        packRef
	schema           int
	hasEffects       bool
	effects          []skillEffect
	presentation     json.RawMessage
}

type gardenItemFact struct {
	id                                uuid.UUID
	definition                        packRef
	profile                           packRef
	hasEffects, dailyGrant, stepGrant bool
	effects                           []skillEffect
}

type gardenFacts struct {
	plants []gardenPlantFact
	items  []gardenItemFact
}

type skillCaps struct {
	activity, water, plantAttraction, gardenAttraction, totalAttraction *big.Rat
	flatAttraction, flatAttractionFraction, capacity                    *big.Rat
	flatCapacity                                                        *big.Rat
}

var invalidSkills = &apiError{503, "invalid_skill_configuration", "Skill rules require maintenance"}

func readSkillCaps(document map[string]any) (skillCaps, error) {
	var c skillCaps
	value, ok := document["flatCapacity"].(float64)
	if !ok || value < 0 || value > 1_000_000 || value != float64(int64(value)) || document["schemaVersion"] != float64(1) {
		return c, invalidSkills
	}
	c.flatCapacity = big.NewRat(int64(value), 1)
	for k, destination := range map[string]**big.Rat{
		"activityBonus": &c.activity, "waterBonus": &c.water, "plantAttractionBonus": &c.plantAttraction,
		"gardenAttractionBonus": &c.gardenAttraction, "totalAttractionBonus": &c.totalAttraction,
		"flatAttractionPoints": &c.flatAttraction, "flatAttractionBaseFraction": &c.flatAttractionFraction,
		"capacityBonus": &c.capacity,
	} {
		value, _ := document[k].(string)
		n, err := skillNumber(value)
		if err != nil {
			return c, err
		}
		*destination = n
	}
	return c, nil
}

func skillNumber(raw string) (*big.Rat, error) {
	n, err := activityCoefficient(raw)
	if err != nil {
		return nil, invalidSkills
	}
	return big.NewRat(n, 1_000_000), nil
}

func parseSkillEffects(raw json.RawMessage, item bool) ([]skillEffect, error) {
	if len(raw) == 0 {
		return nil, nil
	}
	var effects []skillEffect
	if err := json.Unmarshal(raw, &effects); err != nil || effects == nil {
		return nil, invalidSkills
	}
	result := make([]skillEffect, 0, len(effects))
	for _, effect := range effects {
		if effect.ComponentVersion == 0 {
			effect.ComponentVersion = 1
		}
		if effect.Operation == "" {
			effect.Operation = "percent"
		}
		if effect.MinimumStage == "" {
			effect.MinimumStage = "adult"
		}
		if effect.StackingRule == "" {
			effect.StackingRule = "strongest"
		}
		if effect.Magnitude.Type == "" {
			effect.Magnitude.Type = "fixed"
		}
		if effect.Condition != nil {
			if effect.Condition.Type == "" {
				effect.Condition.Type = "placed_count"
			}
			if effect.Condition.Minimum == 0 {
				effect.Condition.Minimum = 1
			}
		}
		if !effect.valid() {
			return nil, invalidSkills
		}
		if item && effect.Metric == "workouts" {
			categories := make(map[string]bool, len(workoutCategories))
			for _, value := range workoutCategories {
				categories[value] = true
			}
			for _, kind := range slices.Sorted(maps.Keys(categories)) {
				expanded := effect
				expanded.Metric = "workout_minutes." + kind
				result = append(result, expanded)
			}
		} else if effect.Metric == "workouts" {
			return nil, invalidSkills
		} else {
			result = append(result, effect)
		}
	}
	return result, nil
}

func (e skillEffect) valid() bool {
	if e.ComponentVersion < 1 || e.ComponentVersion > 2 || e.Name == "" || e.Description == "" || !packIdentifier.MatchString(e.ID) ||
		!packIdentifier.MatchString(e.StackingGroup) || e.MinimumStage != "adult" || e.StackingRule != "strongest" ||
		(e.Operation != "percent" && e.Operation != "flat") {
		return false
	}
	if e.StepBand != "" && (e.ComponentVersion != 2 || e.Scope != "activity" || e.Metric != "steps" ||
		(e.StepBand != "first_2000" && e.StepBand != "after_2000")) {
		return false
	}
	var growth, plantTarget bool
	switch e.Scope {
	case "activity", "water":
		growth, plantTarget = true, true
	case "attraction_plant":
		plantTarget = true
	case "attraction_garden", "offline_capacity", "welcome_duration":
	default:
		return false
	}
	if growth && (e.System != "growth" || e.Operation == "flat") || !growth && e.System != "visitors" ||
		plantTarget && e.Target != "all_planted_plants" && e.Target != "selected_plants" ||
		!plantTarget && e.Target != "garden" || (e.Target == "selected_plants") != (e.Recipients != nil) ||
		(e.Scope == "activity") != (e.Metric != "") {
		return false
	}
	if e.Condition != nil && (e.Condition.Type != "placed_count" || e.Condition.Selector == nil ||
		e.Condition.Minimum < 1 || e.Condition.Minimum > 10000) {
		return false
	}
	if _, err := skillNumber(e.Magnitude.Value); err != nil {
		return false
	}
	switch e.Magnitude.Type {
	case "fixed":
		return e.Magnitude.Selector == nil && e.Magnitude.Maximum == ""
	case "daily_flights":
		if e.ComponentVersion != 2 || e.Scope != "attraction_garden" || e.Magnitude.Selector != nil {
			return false
		}
	case "per_species":
		if e.ComponentVersion != 2 || e.Magnitude.Selector == nil {
			return false
		}
	case "per_copy":
		if e.Magnitude.Selector == nil {
			return false
		}
	default:
		return false
	}
	_, err := skillNumber(e.Magnitude.Maximum)
	return err == nil
}

func selectedSkillPlant(p gardenPlantFact, s *skillSelector) bool {
	if s == nil {
		return true
	}
	if len(s.Species) > 0 && !slices.Contains(s.Species, p.skill.species) ||
		len(s.Variants) > 0 && !slices.Contains(s.Variants, p.skill.variant) ||
		len(s.Stages) > 0 && !slices.Contains(s.Stages, p.stage) {
		return false
	}
	for _, tag := range s.Tags {
		if !slices.Contains(p.skill.tags, tag) {
			return false
		}
	}
	return true
}

type skillCandidate struct {
	effect  skillEffect
	value   *big.Rat
	source  uuid.UUID
	profile packRef
	item    packRef
}

func compareSkillCandidate(a, b skillCandidate) int {
	if c := cmp.Compare(a.effect.ID, b.effect.ID); c != 0 {
		return c
	}
	if c := cmp.Compare(a.profile.ID, b.profile.ID); c != 0 {
		return c
	}
	if c := cmp.Compare(a.profile.Version, b.profile.Version); c != 0 {
		return c
	}
	return cmp.Compare(a.source.String(), b.source.String())
}

type skillResolution struct {
	winner   skillCandidate
	eligible []skillCandidate
}

type skillKey struct {
	scope, metric, operation string
	recipient                uuid.UUID
}

type skillSnapshot struct {
	facts                                   gardenFacts
	config                                  gardenStrategy
	caps                                    skillCaps
	candidates                              []skillCandidate
	resolved                                map[skillKey][]skillResolution
	bands                                   map[string]*skillSnapshot
	stepBands, showBands, dailyFlightSource bool
}

func buildSkillSnapshot(config gardenStrategy, facts gardenFacts) (*skillSnapshot, error) {
	caps, err := readSkillCaps(config.caps)
	if err != nil {
		return nil, err
	}
	// Place and activity queries use UUID ordering. Sort copies so pure callers do too.
	facts.plants = slices.Clone(facts.plants)
	facts.items = slices.Clone(facts.items)
	slices.SortFunc(facts.plants, func(a, b gardenPlantFact) int { return cmp.Compare(a.id.String(), b.id.String()) })
	slices.SortFunc(facts.items, func(a, b gardenItemFact) int { return cmp.Compare(a.id.String(), b.id.String()) })
	return skillSnapshotForBand(config, facts, caps, "")
}

func skillSnapshotForBand(config gardenStrategy, facts gardenFacts, caps skillCaps, band string) (*skillSnapshot, error) {
	s := &skillSnapshot{facts: facts, config: config, caps: caps, resolved: make(map[skillKey][]skillResolution), bands: make(map[string]*skillSnapshot)}
	operations := make(map[[4]string]string)
	add := func(effects []skillEffect, source uuid.UUID, profile, item packRef) error {
		for _, e := range effects {
			s.showBands = s.showBands || e.StepBand != ""
			s.dailyFlightSource = s.dailyFlightSource || e.Magnitude.Type == "daily_flights"
			if e.StepBand != "" && e.StepBand != band {
				continue
			}
			if e.Condition != nil && s.countSelected(e.Condition.Selector, false) < int64(e.Condition.Minimum) {
				continue
			}
			value, err := skillNumber(e.Magnitude.Value)
			if err != nil {
				return err
			}
			if e.Magnitude.Type != "fixed" {
				limit, err := skillNumber(e.Magnitude.Maximum)
				if err != nil {
					return err
				}
				count := config.flights
				if e.Magnitude.Type != "daily_flights" {
					count = s.countSelected(e.Magnitude.Selector, e.Magnitude.Type == "per_species")
				}
				value = smallerRat(value.Mul(value, big.NewRat(count, 1)), limit)
			}
			if value.Sign() == 0 {
				continue
			}
			key := [4]string{e.System, e.Scope, e.Metric, e.StackingGroup}
			if old := operations[key]; old != "" && old != e.Operation {
				return invalidSkills
			}
			operations[key] = e.Operation
			s.candidates = append(s.candidates, skillCandidate{e, value, source, profile, item})
		}
		return nil
	}
	for _, p := range facts.plants {
		s.stepBands = s.stepBands || p.skill.schema == 3
		if p.stage == "adult" {
			if err := add(p.skill.effects, p.id, p.skill.behaviour, packRef{}); err != nil {
				return nil, err
			}
		}
	}
	for _, i := range facts.items {
		if err := add(i.effects, i.id, i.profile, i.definition); err != nil {
			return nil, err
		}
	}
	return s, nil
}

func (s *skillSnapshot) countSelected(selector *skillSelector, distinct bool) int64 {
	var count int64
	var species map[string]bool
	if distinct {
		species = make(map[string]bool)
	}
	for _, p := range s.facts.plants {
		if !selectedSkillPlant(p, selector) {
			continue
		}
		if !distinct {
			count++
			continue
		}
		if !species[p.skill.species] {
			count++
			species[p.skill.species] = true
		}
	}
	return count
}

func (s *skillSnapshot) resolve(scope string, recipient *gardenPlantFact, metric, operation string) []skillResolution {
	key := skillKey{scope: scope, metric: metric, operation: operation}
	if recipient != nil {
		key.recipient = recipient.id
	}
	if rows, ok := s.resolved[key]; ok {
		return rows
	}
	groups := make(map[string][]skillCandidate)
	for _, c := range s.candidates {
		e := c.effect
		if e.Scope == scope && e.Metric == metric && e.Operation == operation && (recipient == nil || selectedSkillPlant(*recipient, e.Recipients)) {
			groups[e.StackingGroup] = append(groups[e.StackingGroup], c)
		}
	}
	rows := make([]skillResolution, 0, len(groups))
	for _, group := range slices.Sorted(maps.Keys(groups)) {
		eligible := groups[group]
		slices.SortStableFunc(eligible, compareSkillCandidate)
		winner := eligible[0]
		for _, c := range eligible[1:] {
			if c.value.Cmp(winner.value) > 0 {
				winner = c
			}
		}
		rows = append(rows, skillResolution{winner, eligible})
	}
	s.resolved[key] = rows
	return rows
}

func (s *skillSnapshot) total(scope string, p *gardenPlantFact, metric, operation string) *big.Rat {
	sum := new(big.Rat)
	for _, r := range s.resolve(scope, p, metric, operation) {
		sum.Add(sum, r.winner.value)
	}
	return sum
}

func smallerRat(a, b *big.Rat) *big.Rat {
	if a.Cmp(b) <= 0 {
		return a
	}
	return b
}

func skillFactor(value, cap *big.Rat) *big.Rat {
	return new(big.Rat).Add(big.NewRat(1, 1), smallerRat(value, cap))
}

func (s *skillSnapshot) attraction() (*big.Rat, error) {
	base, total := new(big.Rat), new(big.Rat)
	flat := s.total("attraction_garden", nil, "", "flat")
	for _, p := range s.facts.plants {
		if p.attraction < 0 {
			return nil, invalidSkills
		}
		value := big.NewRat(p.attraction, 1)
		base.Add(base, value)
		total.Add(total, value.Mul(value, skillFactor(s.total("attraction_plant", &p, "", "percent"), s.caps.plantAttraction)))
		flat.Add(flat, s.total("attraction_plant", &p, "", "flat"))
	}
	total.Mul(total, skillFactor(s.total("attraction_garden", nil, "", "percent"), s.caps.gardenAttraction))
	micro := big.NewRat(1_000_000, 1)
	budget := smallerRat(new(big.Rat).Mul(micro, s.caps.flatAttraction), new(big.Rat).Mul(base, s.caps.flatAttractionFraction))
	total.Add(total, smallerRat(flat.Mul(flat, micro), budget))
	return smallerRat(total, base.Mul(base, new(big.Rat).Add(big.NewRat(1, 1), s.caps.totalAttraction))), nil
}

func (s *skillSnapshot) capacity() *big.Rat {
	base := big.NewRat(s.config.base, 1)
	value := new(big.Rat).Mul(base, skillFactor(s.total("offline_capacity", nil, "", "percent"), s.caps.capacity))
	flat := s.total("offline_capacity", nil, "", "flat")
	flat.Mul(flat, big.NewRat(int64(s.config.def.CapacityFlat), 1))
	value.Add(value, smallerRat(flat, s.caps.flatCapacity))
	ceiling := base.Mul(base, new(big.Rat).Add(big.NewRat(1, 1), s.caps.capacity))
	return smallerRat(smallerRat(value, ceiling), big.NewRat(s.config.maximum, 1))
}

func (s *skillSnapshot) welcomeMicros() *big.Int {
	base := big.NewRat(int64(s.config.def.Welcome)*1_000_000, 1)
	return ceilRat(base.Mul(base, skillFactor(s.total("welcome_duration", nil, "", "percent"), big.NewRat(1, 4))))
}

func (s *skillSnapshot) band(name string) (*skillSnapshot, error) {
	if value := s.bands[name]; value != nil {
		return value, nil
	}
	value, err := skillSnapshotForBand(s.config, s.facts, s.caps, name)
	if err != nil {
		return nil, err
	}
	s.bands[name] = value
	return value, nil
}

func fractionDecimal(n *big.Rat, precision int) string {
	if n.Sign() == 0 {
		return "0"
	}
	a, b := new(big.Int).Abs(n.Num()), n.Denom()
	scale := len(a.String()) - len(b.String())
	ten := big.NewInt(10)
	power := func(n int) *big.Int { return new(big.Int).Exp(ten, big.NewInt(int64(n)), nil) }
	if scale >= 0 {
		if a.Cmp(new(big.Int).Mul(b, power(scale))) < 0 {
			scale--
		}
	} else if new(big.Int).Mul(a, power(-scale)).Cmp(b) < 0 {
		scale--
	}
	places := precision - 1 - scale
	divisor := new(big.Int).Set(b)
	if places >= 0 {
		a.Mul(a, power(places))
	} else {
		divisor.Mul(divisor, power(-places))
	}
	q, r := new(big.Int), new(big.Int)
	q.QuoRem(a, divisor, r)
	doubled := r.Lsh(r, 1).Cmp(divisor)
	if doubled > 0 || doubled == 0 && q.Bit(0) == 1 {
		q.Add(q, big.NewInt(1))
	}
	result := q.String()
	if places > 0 {
		if len(result) <= places {
			result = strings.Repeat("0", places-len(result)+1) + result
		}
		point := len(result) - places
		result = strings.TrimRight(strings.TrimRight(result[:point]+"."+result[point:], "0"), ".")
	} else if places < 0 {
		result += strings.Repeat("0", -places)
	}
	if n.Sign() < 0 {
		return "-" + result
	}
	return result
}
