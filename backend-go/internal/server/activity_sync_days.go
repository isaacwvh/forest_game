package server

import (
	"context"
	"encoding/json"
	"math"
	"math/big"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var activityCounterExhausted = &apiError{503, "counter_exhausted", "Accounting counter requires maintenance"}

type activityWatermark struct {
	device                             uuid.UUID
	rule                               string
	baseline, baselineCredit, credited int64
	value                              *int64
	observed                           time.Time
}

type activityMetricKey struct {
	day    time.Time
	metric string
}
type syncWatermarks struct {
	days    map[time.Time]activityWatermark
	metrics map[activityMetricKey]activityWatermark
}

func readSyncWatermarks(ctx context.Context, tx pgx.Tx, owner string, dates []time.Time) (syncWatermarks, error) {
	facts := syncWatermarks{make(map[time.Time]activityWatermark), make(map[activityMetricKey]activityWatermark)}
	rows, err := tx.Query(ctx, `SELECT game_date,'' AS metric,device_id,rule_version,baseline_steps,
		baseline_credit_steps,credited_steps,observed_steps,observed_at
		FROM activity_days WHERE owner_id=$1 AND game_date=ANY($2::date[])
		UNION ALL SELECT game_date,metric,device_id,rule_version,baseline,baseline_credit,credited,observed,observed_at
		FROM activity_metric_days WHERE owner_id=$1 AND game_date=ANY($2::date[])
		AND metric IN ('walking_running_distance_km','active_energy_kcal','flights_climbed')`, owner, dates)
	if err != nil {
		return facts, err
	}
	defer rows.Close()
	for rows.Next() {
		var date time.Time
		var metric string
		var row activityWatermark
		if err := rows.Scan(&date, &metric, &row.device, &row.rule, &row.baseline, &row.baselineCredit, &row.credited, &row.value, &row.observed); err != nil {
			return facts, err
		}
		if metric == "" {
			facts.days[date] = row
		} else {
			facts.metrics[activityMetricKey{date, metric}] = row
		}
	}
	return facts, rows.Err()
}

func candidateWatermark(row activityWatermark, value *int64) (int64, error) {
	if value == nil {
		return row.credited, nil
	}
	extra := max(int64(0), *value-row.baseline)
	if row.baselineCredit > math.MaxInt64-extra {
		return 0, activityCounterExhausted
	}
	return max(row.credited, row.baselineCredit+extra), nil
}

func capActivity(value int64, rate activityRate, divisor int64) int64 {
	if rate.Cap != nil {
		return min(value, *rate.Cap*divisor)
	}
	return value
}

type syncDayResult struct {
	Date                string         `json:"gameDate"`
	Available           bool           `json:"available"`
	BaselineEstablished bool           `json:"baselineEstablished"`
	NewlyEligible       int64          `json:"newlyEligibleSteps"`
	WaterSteps          int64          `json:"waterSteps"`
	Credited            int64          `json:"creditedSteps"`
	Rule                string         `json:"ruleVersion"`
	CreditID            *uuid.UUID     `json:"activityCreditId"`
	Metrics             map[string]any `json:"metrics"`
}

type syncDay struct {
	syncDayResult
	date                        time.Time
	start, end                  time.Time
	steps                       activityWatermark
	daily                       map[string]activityWatermark
	quantities                  map[string]*big.Rat
	rates                       map[string]activityRate
	newMetrics                  map[string]*big.Rat
	flights                     int64
	stepsAvailable, stepsLatest bool
}

type syncBucketPlanner struct {
	ctx                       context.Context
	tx                        pgx.Tx
	boundary, today, observed time.Time
	zone                      *time.Location
	device                    *syncDevice
	rules                     syncRules
	existing                  syncWatermarks
	milestones                bool
}

func (p *syncBucketPlanner) day(entry syncEntry, workouts workoutMetrics) (syncDay, error) {
	d := syncDay{date: entry.date, start: activityDayStart(entry.date, p.zone), daily: make(map[string]activityWatermark),
		quantities: make(map[string]*big.Rat), rates: make(map[string]activityRate), newMetrics: make(map[string]*big.Rat)}
	d.end = activityDayStart(entry.date.AddDate(0, 0, 1), p.zone)
	d.Date = entry.date.Format(time.DateOnly)
	d.Available = entry.steps != nil
	d.Metrics = make(map[string]any, len(dailySyncMetrics))
	stepReady := p.device.stepReady()
	value := entry.steps
	if !stepReady && !entry.date.Equal(p.today) {
		value = nil
	}
	d.steps = p.existing.days[entry.date]
	var rule activityRule
	var err error
	if d.steps.rule == "" {
		rule, err = p.rules.effective(p.ctx, p.tx, maxTime(d.start, p.device.enrolled))
		d.steps = activityWatermark{device: p.device.id, rule: rule.version, observed: p.observed}
	} else {
		rule, err = p.rules.pinned(p.ctx, p.tx, d.steps.rule)
	}
	if err != nil {
		return d, err
	}
	if !stepReady && value != nil {
		if err := checkActivityObservation(p.observed, p.boundary, 5*time.Minute); err != nil {
			return d, err
		}
		if !calendarDate(p.observed, p.zone).Equal(p.today) {
			return d, &apiError{422, "baseline_date_mismatch", "Take a fresh current-day observation"}
		}
		p.device.establishSteps(*value, p.boundary, p.today, p.observed)
		d.steps.device, d.steps.baseline, d.steps.baselineCredit = p.device.id, *value, d.steps.credited
		d.steps.value, d.steps.observed = value, p.observed
		d.BaselineEstablished = true
	}
	if d.steps.device != p.device.id && p.device.baselineDate != nil {
		return d, &apiError{409, "activity_device_mismatch", "Reconcile device baseline first"}
	}
	// Missing steps update availability, and preserve the most recent readable total.
	if !p.observed.Before(d.steps.observed) {
		d.steps.observed = p.observed
		if value != nil {
			d.steps.value = value
		}
	}
	candidate, err := candidateWatermark(d.steps, value)
	if err != nil {
		return d, err
	}
	d.Rule = rule.version
	d.NewlyEligible = candidate - d.steps.credited
	d.Credited = candidate
	rate := rule.metrics["steps"]
	d.WaterSteps = capActivity(candidate, rate, 1) - capActivity(d.steps.credited, rate, 1)
	d.rates["steps"] = rate
	d.steps.credited = candidate
	d.stepsAvailable = value != nil
	d.stepsLatest = !p.observed.Before(p.existing.days[entry.date].observed) || d.BaselineEstablished

	for _, metric := range dailySyncMetrics {
		n, ok := entry.metrics[metric.name]
		var measurement *int64
		if ok {
			measurement = &n
		}
		if err := p.metric(&d, metric.name, metric.divisor, measurement); err != nil {
			return d, err
		}
	}
	for metric, quantity := range workouts.quantities {
		d.quantities[metric] = quantity
		d.rates[metric] = workouts.rates[metric]
		d.newMetrics[metric] = quantity
		d.Metrics[metric] = map[string]any{"available": true, "newlyEligible": quantity.RatString(), "waterQuantity": quantity.RatString()}
	}
	if d.NewlyEligible > 0 || len(d.quantities) > 0 {
		id := uuid.New()
		d.CreditID = &id
	}
	return d, nil
}

func (p *syncBucketPlanner) metric(d *syncDay, name string, divisor int64, value *int64) error {
	baseline, available := p.device.metrics[name]
	established := false
	var since struct {
		Date string
		At   time.Time
	}
	if !available && value != nil && d.date.Equal(p.today) {
		p.device.markReady(p.boundary, p.today)
		p.device.setBaseline(name, map[string]string{"date": d.Date, "at": pythonTime(p.boundary)})
		baseline = p.device.metrics[name]
		available, established = true, true
	}
	if available {
		if err := json.Unmarshal(baseline, &since); err != nil || since.Date == "" || since.At.IsZero() {
			return invalidActivityRules
		}
	}
	if !available || d.Date < since.Date {
		d.Metrics[name] = map[string]any{"available": value != nil, "baselineEstablished": false, "newlyEligible": "0", "waterQuantity": "0"}
		return nil
	}
	row := p.existing.metrics[activityMetricKey{d.date, name}]
	var rule activityRule
	var err error
	if row.rule == "" {
		rule, err = p.rules.effective(p.ctx, p.tx, maxTime(maxTime(d.start, p.device.enrolled), since.At))
		row = activityWatermark{device: p.device.id, rule: rule.version, observed: p.observed}
	} else {
		rule, err = p.rules.pinned(p.ctx, p.tx, row.rule)
	}
	if err != nil {
		return err
	}
	if established || row.device != p.device.id {
		if value == nil {
			return nil
		}
		row.device, row.baseline, row.baselineCredit = p.device.id, *value, row.credited
		established = true
	}
	old := row.credited
	candidate, err := candidateWatermark(row, value)
	if err != nil {
		return err
	}
	if !p.observed.Before(row.observed) {
		row.observed, row.value = p.observed, value
	}
	row.credited = candidate
	daily := big.NewRat(candidate-old, divisor)
	d.newMetrics[name] = daily
	water := new(big.Rat)
	if rate, ok := rule.metrics[name]; ok {
		water.SetFrac64(capActivity(candidate, rate, divisor)-capActivity(old, rate, divisor), divisor)
		d.rates[name] = rate
		if water.Sign() > 0 {
			d.quantities[name] = water
		}
	}
	if name == "flights_climbed" {
		d.flights = candidate - old
	}
	var observed any
	if value != nil {
		observed = big.NewRat(*value, divisor).RatString()
	}
	d.daily[name] = row
	d.Metrics[name] = map[string]any{"available": value != nil, "baselineEstablished": established, "observed": observed,
		"newlyEligible": daily.RatString(), "waterQuantity": water.RatString(), "credited": big.NewRat(candidate, divisor).RatString(), "ruleVersion": rule.version}
	return nil
}

func persistActivityDays(ctx context.Context, tx pgx.Tx, owner Profile, input syncInput, device syncDevice, days []syncDay, at time.Time) error {
	var batch pgx.Batch
	if device.dirty {
		batch.Queue(`UPDATE activity_devices SET baseline_at=$2,baseline_observed_at=$3,baseline_date=$4,
			baseline_steps=$5,metric_baselines=$6::jsonb WHERE id=$1`,
			device.id, device.baselineAt, device.baselineObserved, device.baselineDate, device.baselineSteps, device.metrics)
	}
	for _, day := range days {
		row := day.steps
		batch.Queue(`INSERT INTO activity_days (owner_id,game_date,game_timezone,bucket_start,bucket_end,device_id,
			rule_version,baseline_steps,baseline_credit_steps,observed_steps,observed_at,is_available,credited_steps)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
			ON CONFLICT(owner_id,game_date) DO UPDATE SET device_id=excluded.device_id,baseline_steps=excluded.baseline_steps,
			baseline_credit_steps=excluded.baseline_credit_steps,credited_steps=excluded.credited_steps,
			observed_steps=excluded.observed_steps,observed_at=excluded.observed_at,
			is_available=CASE WHEN $14 THEN excluded.is_available ELSE activity_days.is_available END`,
			owner.ID, day.date, owner.Timezone, day.start, day.end, row.device, row.rule, row.baseline, row.baselineCredit, row.value,
			row.observed, day.stepsAvailable, row.credited, day.stepsLatest)
		for _, metric := range dailySyncMetrics {
			if row, ok := day.daily[metric.name]; ok {
				batch.Queue(`INSERT INTO activity_metric_days (owner_id,game_date,metric,device_id,rule_version,baseline,
					baseline_credit,credited,observed,observed_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
					ON CONFLICT(owner_id,game_date,metric) DO UPDATE SET device_id=excluded.device_id,baseline=excluded.baseline,
					baseline_credit=excluded.baseline_credit,credited=excluded.credited,
					observed=excluded.observed,observed_at=excluded.observed_at`,
					owner.ID, day.date, metric.name, row.device, row.rule, row.baseline, row.baselineCredit, row.credited, row.value, row.observed)
			}
		}
		if day.CreditID != nil {
			qs := make(map[string]string, len(day.quantities))
			for k, v := range day.quantities {
				qs[k] = v.RatString()
			}
			batch.Queue(`INSERT INTO activity_credits (id,owner_id,game_date,device_id,request_id,rule_version,start_steps,
				end_steps,water_steps,accepted_at,metric_quantities) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb)`,
				day.CreditID, owner.ID, day.date, device.id, input.key, day.Rule, day.Credited-day.NewlyEligible, day.Credited, day.WaterSteps, at, qs)
		}
		if day.flights > 0 {
			batch.Queue(`INSERT INTO daily_skill_activity(owner_id,game_date,flights) VALUES($1,$2,$3)
				ON CONFLICT(owner_id,game_date) DO UPDATE SET flights=daily_skill_activity.flights+excluded.flights`,
				owner.ID, day.date, day.flights)
		}
	}
	return tx.SendBatch(ctx, &batch).Close()
}
