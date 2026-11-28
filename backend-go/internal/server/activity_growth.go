package server

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"maps"
	"math/big"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var invalidGrowth = &apiError{503, "invalid_growth_configuration", "Growth configuration requires maintenance"}

var growthStages = [...]string{"sprout", "seedling", "young", "adult"}

type activityPlant struct {
	id                      uuid.UUID
	species, variant        string
	growth, before, maximum int64
	profiles                packProfiles
	thresholds, attractions map[string]int64
	coefficients            map[string]json.RawMessage
	conversions             map[string]activityRate
	fraction                map[string]json.RawMessage
	maturedAt               *time.Time
	skill                   skillPlant
	skillBonus              int64
	changed                 bool
}

func readActivityPlants(ctx context.Context, tx pgx.Tx, g gardenRecord) ([]activityPlant, error) {
	rows, err := tx.Query(ctx, `SELECT p.id,p.species_id,p.variant_id,p.growth_micro_units,p.fractional_state,p.first_matured_at,
		g.id,g.version,g.thresholds,g.maximum_growth_micro_units,b.id,b.version,
		COALESCE(b.rules->'metricMultipliers','{}'),COALESCE(b.rules->'conversionRates','{}'),
		COALESCE(jsonb_array_length(b.rules->'gardenEffects'),0)>0,a.id,a.version,a.stage_attraction,
		COALESCE((b.rules->>'schemaVersion')::int,1),a.gameplay_tags
		FROM garden_placements l JOIN owned_plants p ON p.id=l.plant_id
		JOIN growth_profiles g ON (g.id,g.version)=(p.growth_profile_id,p.growth_profile_version)
		JOIN growth_rule_profiles b ON (b.id,b.version)=(p.behaviour_profile_id,p.behaviour_profile_version)
		JOIN attraction_profiles a ON (a.id,a.version)=(p.attraction_profile_id,p.attraction_profile_version)
		WHERE l.garden_id=$1 AND p.owner_id=$2 ORDER BY p.id FOR UPDATE OF p`, g.id, g.owner)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (activityPlant, error) {
		var plant activityPlant
		p := &plant.profiles
		err := row.Scan(&plant.id, &plant.species, &plant.variant, &plant.growth, &plant.fraction, &plant.maturedAt,
			&p.Growth.ID, &p.Growth.Version, &plant.thresholds, &plant.maximum, &p.Behaviour.ID, &p.Behaviour.Version,
			&plant.coefficients, &plant.conversions, &plant.skill.hasEffects, &p.Attraction.ID, &p.Attraction.Version, &plant.attractions, &plant.skill.schema, &plant.skill.tags)
		if err != nil {
			return plant, err
		}
		plant.before = plant.growth
		old := int64(-1)
		for _, stage := range growthStages {
			threshold, found := plant.thresholds[stage]
			attraction, pinned := plant.attractions[stage]
			if !found || threshold <= old || !pinned || attraction < 0 {
				return plant, invalidGrowth
			}
			old = threshold
		}
		if plant.thresholds["sprout"] != 0 || plant.growth < 0 || plant.growth > plant.maximum {
			return plant, invalidGrowth
		}
		plant.skill.species, plant.skill.variant, plant.skill.behaviour = plant.species, plant.variant, p.Behaviour
		return plant, nil
	})
}

func (p activityPlant) stage(quantity int64) string {
	for i := len(growthStages) - 1; i > 0; i-- {
		if quantity >= p.thresholds[growthStages[i]] {
			return growthStages[i]
		}
	}
	return "sprout"
}

type growthTrace struct {
	Plant      uuid.UUID      `json:"plant_id"`
	Credit     uuid.UUID      `json:"activity_credit_id"`
	Before     int64          `json:"before_growth"`
	After      int64          `json:"after_growth"`
	Context    map[string]any `json:"context"`
	Provenance string         `json:"provenance_id"`
}

type growthResult struct {
	plants            []activityPlant
	traces            []growthTrace
	provenance        map[string]map[string]any
	summary           []map[string]any
	facts             []gardenPlantFact
	seedling, changed bool
	matured           int64
}

func simulateActivityGrowth(plants []activityPlant, days []syncDay, snapshot *skillSnapshot, at time.Time) (growthResult, error) {
	g := growthResult{plants: plants, provenance: make(map[string]map[string]any)}
	for _, day := range days {
		if day.CreditID == nil {
			continue
		}
		for i := range g.plants {
			p := &g.plants[i]
			trace, shared, err := p.applyActivity(day, snapshot.config, snapshot)
			if err != nil {
				return g, err
			}
			if trace.Before < p.thresholds["seedling"] && p.growth >= p.thresholds["seedling"] {
				g.seedling = true
			}
			if trace.Before < p.thresholds["adult"] && p.growth >= p.thresholds["adult"] && p.maturedAt == nil {
				g.matured++
				p.maturedAt = &at
			}
			g.provenance[trace.Provenance] = shared
			g.traces = append(g.traces, trace)
		}
	}
	return g, nil
}

func (g *growthResult) refresh() {
	g.summary = make([]map[string]any, 0)
	g.facts = make([]gardenPlantFact, 0, len(g.plants))
	for _, p := range g.plants {
		stage := p.stage(p.growth)
		g.facts = append(g.facts, p.gardenFact(p.growth))
		g.changed = g.changed || p.changed
		if p.growth > p.before {
			g.summary = append(g.summary, map[string]any{"plantId": p.id, "beforeGrowthMicroUnits": numberString(p.before),
				"afterGrowthMicroUnits": numberString(p.growth), "awardedGrowthMicroUnits": numberString(p.growth - p.before),
				"beforeStage": p.stage(p.before), "afterStage": stage, "skillBonusGrowthMicroUnits": numberString(p.skillBonus), "speciesId": p.species,
				"variantId": p.variant, "maximumGrowthMicroUnits": numberString(p.maximum)})
		}
	}

}

func (p activityPlant) gardenFact(growth int64) gardenPlantFact {
	stage := p.stage(growth)
	return gardenPlantFact{p.id, numberString(growth), stage, p.attractions[stage], p.profiles.Attraction, p.skill}
}

func (p *activityPlant) applyActivity(day syncDay, config gardenStrategy, snapshot *skillSnapshot) (growthTrace, map[string]any, error) {
	tr := growthTrace{Plant: p.id, Credit: *day.CreditID, Before: p.growth}
	if p.maximum != p.thresholds["adult"] {
		return tr, nil, &apiError{503, "unsupported_maturity_profile", "Terminal maturity must match the adult threshold"}
	}
	fraction, err := growthRemainder(p.fraction)
	if err != nil {
		return tr, nil, invalidGrowth
	}
	quantity := make(map[string]*big.Rat, len(day.quantities)+1)
	for metric, value := range day.quantities {
		quantity[metric] = value
	}
	quantity["steps"] = big.NewRat(day.WaterSteps, 1)
	calculated, neutral := new(big.Rat), new(big.Rat)
	metricRates := make(map[string]activityRate, len(day.quantities))
	metricQuantities := make(map[string]string, len(day.quantities))
	activityFactors := make(map[string]string, len(day.rates))
	var modifiers map[string]*big.Rat
	waterFactor := big.NewRat(1, 1)
	var skillContext map[string]any
	if snapshot != nil {
		modifiers, waterFactor, skillContext, err = snapshot.growth(p.gardenFact(p.before), slices.Sorted(maps.Keys(day.rates)), day.Credited-day.NewlyEligible, day.WaterSteps)
		if err != nil || waterFactor.Cmp(big.NewRat(5, 2)) > 0 {
			return tr, nil, invalidGrowth
		}
		activityFactors = skillContext["activityFactors"].(map[string]string)
	} else {
		for metric := range day.rates {
			activityFactors[metric] = "1"
		}
		skillContext = map[string]any{"policyVersion": config.policy, "caps": config.caps, "activityFactors": activityFactors, "waterFactor": "1", "effects": []any{}}
	}
	var stepRate activityRate
	stepCoefficient := "0"
	for metric, value := range quantity {
		rate := day.rates[metric]
		override, hasOverride := p.conversions[metric]
		if !hasOverride && strings.HasPrefix(metric, "workout_minutes.") {
			override, hasOverride = p.conversions["workout_minutes.*"]
		}
		if hasOverride {
			rate = override
		}
		if !rate.valid() {
			return tr, nil, invalidGrowth
		}
		text := "0"
		raw := p.coefficients[metric]
		if raw == nil && strings.HasPrefix(metric, "workout_minutes.") {
			raw = p.coefficients["workout_minutes.*"]
		}
		if raw != nil {
			text = string(raw)
			if strings.HasPrefix(text, "\"") && json.Unmarshal(raw, &text) != nil {
				return tr, nil, invalidGrowth
			}
		}
		coefficient, err := activityCoefficient(text)
		if err != nil {
			return tr, nil, invalidGrowth
		}
		normal, _ := activityCoefficient(rate.Normalisation)
		component := new(big.Rat).Mul(value, big.NewRat(coefficient, normal))
		component.Mul(component, big.NewRat(rate.Water, 1))
		neutral.Add(neutral, component)
		if factor := modifiers[metric]; factor != nil {
			if factor.Cmp(big.NewRat(5, 2)) > 0 {
				return tr, nil, invalidGrowth
			}
			component.Mul(component, factor)
		}
		calculated.Add(calculated, component)
		if metric == "steps" {
			stepRate, stepCoefficient = rate, text
		} else {
			metricRates[metric], metricQuantities[metric] = rate, value.RatString()
		}
	}
	afterActivity := calculated.RatString()
	calculated.Mul(calculated, waterFactor)
	total := new(big.Rat).Add(calculated, fraction)
	remaining := big.NewRat(p.maximum-p.growth, 1)
	afterFraction := map[string]json.RawMessage{}
	clamped := total.Cmp(remaining) > 0
	if total.Cmp(remaining) >= 0 {
		p.growth = p.maximum
	} else {
		earned := new(big.Int).Quo(total.Num(), total.Denom()).Int64()
		p.growth += earned
		remainder := new(big.Rat).Sub(total, big.NewRat(earned, 1))
		if remainder.Sign() != 0 {
			afterFraction["numerator"], _ = json.Marshal(remainder.Num().String())
			afterFraction["denominator"], _ = json.Marshal(remainder.Denom().String())
		}
	}
	tr.After = p.growth
	neutral.Add(neutral, fraction)
	neutralAward := new(big.Int).Quo(neutral.Num(), neutral.Denom())
	if neutral.Cmp(remaining) >= 0 {
		neutralAward.SetInt64(p.maximum - tr.Before)
	}
	bonus := tr.After - tr.Before - neutralAward.Int64()
	p.skillBonus += bonus
	profile := func(ref packRef) map[string]any { return map[string]any{"id": ref.ID, "version": ref.Version} }
	shared := map[string]any{
		"profiles":    map[string]any{"growth": profile(p.profiles.Growth), "behaviour": profile(p.profiles.Behaviour), "attraction": profile(p.profiles.Attraction)},
		"ruleVersion": day.Rule, "metricRates": metricRates, "metricReceipts": day.Metrics,
		"coefficient": stepCoefficient, "normalisation": stepRate.Normalisation, "baseWaterMicroUnits": numberString(stepRate.Water),
		"skills":         skillContext,
		"activityFactor": activityFactors["steps"], "waterFactor": fractionDecimal(waterFactor, 28),
	}
	// Serialize nested DTO fields through generic JSON to match the reference's sorted-key fingerprint.
	wire, err := json.Marshal(shared)
	if err != nil {
		return tr, nil, err
	}
	d := json.NewDecoder(strings.NewReader(string(wire)))
	d.UseNumber()
	var canonical map[string]any
	if err := d.Decode(&canonical); err != nil {
		return tr, nil, err
	}
	proof, err := canonicalJSON(canonical)
	if err != nil {
		return tr, nil, err
	}
	digest := sha256.Sum256(proof)
	tr.Provenance = hex.EncodeToString(digest[:])
	tr.Context = map[string]any{"steps": day.WaterSteps, "metricQuantities": metricQuantities, "snapshotStage": p.stage(p.before),
		"postActivityWaterMicroUnits": afterActivity, "calculatedMicroUnits": calculated.RatString(),
		"beforeFraction": p.fraction, "afterFraction": afterFraction, "beforeStage": p.stage(tr.Before), "afterStage": p.stage(tr.After),
		"maturityClamped": clamped, "awardedMicroUnits": numberString(tr.After - tr.Before), "skillBonusGrowthMicroUnits": numberString(bonus)}
	p.changed = p.changed || p.growth != tr.Before || string(p.fraction["numerator"]) != string(afterFraction["numerator"]) ||
		string(p.fraction["denominator"]) != string(afterFraction["denominator"])
	p.fraction = afterFraction
	return tr, shared, nil
}

func growthRemainder(values map[string]json.RawMessage) (*big.Rat, error) {
	if len(values) == 0 {
		return new(big.Rat), nil
	}
	if len(values) != 2 || values["numerator"] == nil || values["denominator"] == nil {
		return nil, invalidGrowth
	}
	var n, d json.Number
	if json.Unmarshal(values["numerator"], &n) != nil || json.Unmarshal(values["denominator"], &d) != nil || n == "" || d == "" {
		return nil, invalidGrowth
	}
	value, err := (visitorFraction{n.String(), d.String()}).rat()
	if err != nil || value.Cmp(big.NewRat(1, 1)) >= 0 {
		return nil, invalidGrowth
	}
	return value, nil
}

func persistGrowthPlants(ctx context.Context, tx pgx.Tx, owner string, plants []activityPlant, at time.Time) error {
	updates := make([]map[string]any, 0, len(plants))
	for _, p := range plants {
		if p.changed {
			updates = append(updates, map[string]any{"id": p.id, "growth": p.growth, "fraction": p.fraction, "matured_at": p.maturedAt})
		}
	}
	if len(updates) == 0 {
		return nil
	}
	_, err := tx.Exec(ctx, `UPDATE owned_plants p SET growth_micro_units=u.growth,fractional_state=u.fraction,
			first_matured_at=COALESCE(p.first_matured_at,u.matured_at),updated_at=$3
			FROM jsonb_to_recordset($2::jsonb) u(id uuid,growth bigint,fraction jsonb,matured_at timestamptz)
			WHERE p.owner_id=$1 AND p.id=u.id`, owner, updates, at)
	return err
}

func (g growthResult) persistTraces(ctx context.Context, tx pgx.Tx) error {
	if len(g.traces) == 0 {
		return nil
	}
	keys := make([]string, 0, len(g.provenance))
	for id := range g.provenance {
		keys = append(keys, id)
	}
	slices.Sort(keys)
	shared := make([]map[string]any, 0, len(keys))
	for _, id := range keys {
		shared = append(shared, map[string]any{"id": id, "payload": g.provenance[id]})
	}
	if _, err := tx.Exec(ctx, `INSERT INTO growth_provenance (id,payload)
		SELECT id,payload FROM jsonb_to_recordset($1::jsonb) AS v(id text,payload jsonb) ORDER BY id
		ON CONFLICT(id) DO NOTHING`, shared); err != nil {
		return err
	}
	var locked int
	err := tx.QueryRow(ctx, `SELECT count(*) FROM (SELECT id FROM growth_provenance WHERE id=ANY($1::text[])
		ORDER BY id FOR KEY SHARE) hold`, keys).Scan(&locked)
	if err != nil {
		return err
	}
	if locked != len(keys) {
		return errors.New("growth provenance was unavailable during commit")
	}
	_, err = tx.Exec(ctx, `INSERT INTO plant_growth_credits (plant_id,activity_credit_id,before_growth,after_growth,context,provenance_id)
		SELECT plant_id,activity_credit_id,before_growth,after_growth,context,provenance_id
		FROM jsonb_to_recordset($1::jsonb) v(plant_id uuid,activity_credit_id uuid,before_growth bigint,after_growth bigint,context jsonb,provenance_id text)`, g.traces)
	return err
}

func discoverActivityStages(ctx context.Context, tx pgx.Tx, g gardenRecord, at time.Time, newMilestoneGrowth bool) error {
	var inserted, versioned, milestone bool
	err := tx.QueryRow(ctx, `WITH reached AS (
		INSERT INTO catalog_stage_discoveries(owner_id,species_id,variant_id,stage,recorded_at)
		SELECT DISTINCT p.owner_id,p.species_id,p.variant_id,entry.stage,$3::timestamptz
		FROM garden_placements l JOIN owned_plants p ON p.id=l.plant_id
		JOIN growth_profiles gp ON (gp.id,gp.version)=(p.growth_profile_id,p.growth_profile_version)
		CROSS JOIN LATERAL jsonb_each_text(gp.thresholds) entry(stage,threshold)
		WHERE l.garden_id=$1 AND p.owner_id=$2 AND entry.threshold::bigint<=p.growth_micro_units
		ON CONFLICT DO NOTHING RETURNING 1
	), advanced AS (
		UPDATE catalog_discovery_state SET version=version+1 WHERE owner_id=$2
		AND version<9223372036854775807 AND EXISTS(SELECT 1 FROM reached) RETURNING 1
	) SELECT EXISTS(SELECT 1 FROM reached),EXISTS(SELECT 1 FROM advanced),
		EXISTS(SELECT 1 FROM milestone_policies WHERE active AND effective_at<=$3)`, g.id, g.owner, at).Scan(&inserted, &versioned, &milestone)
	if err != nil {
		return err
	}
	if inserted && !versioned {
		return &apiError{503, "discovery_not_ready", "Catalog discovery requires a database upgrade or maintenance"}
	}
	if milestone && (inserted || newMilestoneGrowth) {
		return refreshMilestoneEntitlements(ctx, tx, g.owner, at)
	}
	return nil
}
