package server

import (
	"cmp"
	"maps"
	"math/big"
	"slices"
	"strings"
)

func (s *skillSnapshot) effects(recipient *gardenPlantFact, metrics []string) []map[string]any {
	var scopes [][2]string
	switch {
	case recipient == nil:
		scopes = [][2]string{{"attraction_garden", ""}, {"offline_capacity", ""}, {"welcome_duration", ""}}
	case len(metrics) == 0:
		scopes = [][2]string{{"attraction_plant", ""}, {"water", ""}}
	default:
		scopes = [][2]string{{"water", ""}}
		for _, metric := range metrics {
			scopes = append(scopes, [2]string{"activity", metric})
		}
	}
	rows := make([]map[string]any, 0)
	for _, scope := range scopes {
		for _, operation := range []string{"percent", "flat"} {
			for _, r := range s.resolve(scope[0], recipient, scope[1], operation) {
				w, e := r.winner, r.winner.effect
				plants, items := make(map[string]bool), make(map[string]bool)
				for _, candidate := range r.eligible {
					if candidate.item.ID == "" {
						plants[candidate.source.String()] = true
					} else {
						items[candidate.source.String()] = true
					}
				}
				var metric any
				if e.Metric != "" {
					metric = e.Metric
				}
				row := map[string]any{"id": e.ID, "name": e.Name, "description": e.Description, "system": e.System,
					"scope": e.Scope, "metric": metric, "operation": operation, "magnitude": fractionDecimal(w.value, 28),
					"stackingGroup": e.StackingGroup, "profileId": w.profile.ID, "profileVersion": w.profile.Version,
					"eligibleSourcePlantIds": skillIDs(plants)}
				if e.StepBand != "" {
					row["stepBand"] = e.StepBand
				}
				if w.item.ID != "" {
					row["sourceItemId"], row["sourceItemDefinition"], row["sourceDefinitionVersion"] = w.source.String(), w.item.ID, w.item.Version
					row["eligibleSourceItemIds"], row["sourceKind"] = skillIDs(items), "item"
				} else {
					row["sourcePlantId"] = w.source.String()
				}
				rows = append(rows, row)
			}
		}
	}
	return rows
}

func skillIDs(values map[string]bool) []string {
	ids := make([]string, 0, len(values))
	ids = slices.AppendSeq(ids, maps.Keys(values))
	slices.Sort(ids)
	return ids
}

func skillText(value any) string {
	text, _ := value.(string)
	return text
}

func (s *skillSnapshot) presentation() (map[string]any, error) {
	factors := make([]map[string]any, 0, len(s.facts.plants))
	rows := make([]map[string]any, 0)
	type key struct {
		meta    [6]string
		version int
	}
	indices := make(map[key]int)
	metricsSet := make(map[string]bool)
	for _, c := range s.candidates {
		if c.effect.Scope == "activity" {
			metricsSet[c.effect.Metric] = true
		}
	}
	metrics := skillIDs(metricsSet)
	remember := func(row map[string]any, recipient string) {
		k := key{[6]string{skillText(row["system"]), skillText(row["scope"]), skillText(row["metric"]),
			skillText(row["stackingGroup"]), skillText(row["profileId"]), skillText(row["id"])}, row["profileVersion"].(int)}
		index, ok := indices[k]
		if !ok {
			index = len(rows)
			indices[k] = index
			row["recipientPlantIds"] = []string{}
			rows = append(rows, row)
		}
		ids := rows[index]["recipientPlantIds"].([]string)
		if recipient != "" && (len(ids) == 0 || ids[len(ids)-1] != recipient) {
			rows[index]["recipientPlantIds"] = append(ids, recipient)
		}
	}
	for _, p := range s.facts.plants {
		activity, activityCaps := make(map[string]string, len(metrics)), make(map[string]bool, len(metrics))
		for _, metric := range metrics {
			total := s.total("activity", &p, metric, "percent")
			activity[metric] = fractionDecimal(skillFactor(total, s.caps.activity), 28)
			activityCaps[metric] = total.Cmp(s.caps.activity) >= 0
		}
		water := s.total("water", &p, "", "percent")
		factors = append(factors, map[string]any{"plantId": p.id.String(), "waterFactor": fractionDecimal(skillFactor(water, s.caps.water), 28),
			"waterCapReached": water.Cmp(s.caps.water) >= 0, "activityFactors": activity, "activityCapReached": activityCaps})
		for _, row := range append(s.effects(&p, nil), s.effects(&p, metrics)...) {
			remember(row, p.id.String())
		}
		if s.showBands {
			for _, name := range []string{"first_2000", "after_2000"} {
				band, err := s.band(name)
				if err != nil {
					return nil, err
				}
				for _, row := range band.effects(&p, []string{"steps"}) {
					if row["stepBand"] == name {
						remember(row, p.id.String())
					}
				}
			}
		}
	}
	for _, row := range s.effects(nil, nil) {
		remember(row, "")
	}
	if sources := readStepGrantSources(s.facts.items); len(sources) > 0 {
		rows = append(rows, s.flatWaterSkill(sources, stepGrantFamily, "Alignment of Worlds", "step_tier_water", "12", "steps",
			"2,000 / 4,000 / 6,000 daily steps while placed grant 3 / 4 / 5 flat water per planted plant. Duplicates share progress."))
	}
	var harps []gardenItemFact
	for _, item := range s.facts.items {
		if item.dailyGrant {
			harps = append(harps, item)
		}
	}
	if len(harps) > 0 {
		rows = append(rows, s.flatWaterSkill(harps, dailyWaterFamily, "Morning Rain", "daily_water", "2.5", nil,
			"+2.5 water per eligible planted plant at account-local midnight. Duplicate harps apply once."))
	}
	slices.SortStableFunc(rows, func(a, b map[string]any) int {
		for _, field := range []string{"name", "scope", "metric"} {
			if order := cmp.Compare(skillText(a[field]), skillText(b[field])); order != 0 {
				return order
			}
		}
		return cmp.Compare(a["profileVersion"].(int), b["profileVersion"].(int))
	})
	return map[string]any{"policyVersion": s.config.policy, "caps": s.config.caps, "activeSkills": rows, "growthFactors": factors}, nil
}

func (s *skillSnapshot) flatWaterSkill(sources []gardenItemFact, family, name, scope, magnitude string, metric any, description string) map[string]any {
	sourceIDs := make([]string, 0, len(sources))
	for _, source := range sources {
		sourceIDs = append(sourceIDs, source.id.String())
	}
	plantIDs := make([]string, 0, len(s.facts.plants))
	for _, plant := range s.facts.plants {
		plantIDs = append(plantIDs, plant.id.String())
	}
	return map[string]any{"id": family, "name": name, "description": description, "system": "growth",
		"scope": scope, "metric": metric, "operation": "flat", "magnitude": magnitude, "stackingGroup": "item_" + family,
		"sourceKind": "item", "sourceItemId": sourceIDs[0], "profileId": sources[0].profile.ID,
		"profileVersion": sources[0].profile.Version, "eligibleSourcePlantIds": []string{}, "eligibleSourceItemIds": sourceIDs,
		"recipientPlantIds": plantIDs}
}

func skillSignature(evaluation gardenEvaluation) string {
	effects, factors := []string{}, []string{}
	for _, e := range evaluation.summary["activeSkills"].([]map[string]any) {
		effects = append(effects, strings.Join([]string{skillText(e["id"]), skillText(e["scope"]), skillText(e["metric"]),
			skillText(e["stepBand"]), skillText(e["stackingGroup"]), skillText(e["magnitude"]), strings.Join(e["recipientPlantIds"].([]string), ",")}, "/"))
	}
	for _, f := range evaluation.summary["growthFactors"].([]map[string]any) {
		factorMap := f["activityFactors"].(map[string]string)
		metrics := make([]string, 0, len(factorMap))
		for _, metric := range slices.Sorted(maps.Keys(factorMap)) {
			metrics = append(metrics, metric+"="+factorMap[metric])
		}
		factors = append(factors, skillText(f["plantId"])+":"+skillText(f["waterFactor"])+":"+strings.Join(metrics, ","))
	}
	slices.Sort(effects)
	slices.Sort(factors)
	return strings.Join([]string{numberString(evaluation.attraction), numberString(evaluation.capacity), strings.Join(effects, "|"), strings.Join(factors, "|")}, "#")
}

func (s *skillSnapshot) growth(p gardenPlantFact, metrics []string, afterSteps, waterSteps int64) (map[string]*big.Rat, *big.Rat, map[string]any, error) {
	activity := make(map[string]*big.Rat, len(metrics))
	display := make(map[string]string, len(metrics))
	for _, m := range metrics {
		activity[m] = skillFactor(s.total("activity", &p, m, "percent"), s.caps.activity)
	}
	water := skillFactor(s.total("water", &p, "", "percent"), s.caps.water)
	facts := map[string]any{"policyVersion": s.config.policy, "caps": s.config.caps,
		"waterFactor": fractionDecimal(water, 28), "effects": s.effects(&p, metrics)}
	if waterSteps > 0 && s.stepBands {
		// The input's credited watermark is monotone, so addition cannot overflow.
		first := max(int64(0), min(afterSteps+waterSteps, 2000)-min(afterSteps, 2000))
		parts := make([]map[string]any, 0, 2)
		weighted := new(big.Rat)
		for index, name := range []string{"first_2000", "after_2000"} {
			weight := first
			if index == 1 {
				weight = waterSteps - first
			}
			if weight == 0 {
				continue
			}
			band, err := s.band(name)
			if err != nil {
				return nil, nil, nil, err
			}
			factor := skillFactor(band.total("activity", &p, "steps", "percent"), s.caps.activity)
			weighted.Add(weighted, new(big.Rat).Mul(factor, big.NewRat(weight, 1)))
			effects := make([]map[string]any, 0)
			for _, row := range band.effects(&p, []string{"steps"}) {
				if row["stepBand"] == name {
					effects = append(effects, row)
				}
			}
			parts = append(parts, map[string]any{"band": name, "waterSteps": numberString(weight),
				"activityFactor": fractionDecimal(factor, 28), "effects": effects})
		}
		activity["steps"] = weighted.Quo(weighted, big.NewRat(waterSteps, 1))
		facts["stepBandSegments"] = parts
	}
	for m, n := range activity {
		display[m] = fractionDecimal(n, 28)
	}
	facts["activityFactors"] = display
	return activity, water, facts, nil
}
