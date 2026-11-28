package server

import (
	"cmp"
	"context"
	"encoding/json"
	"math/big"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const microsPerMinute = 60_000_000

var workoutCategories = map[int]string{
	13: "cycling", 20: "strength_training", 24: "hiking", 37: "running",
	46: "swimming", 50: "strength_training", 52: "walking", 57: "yoga",
}

type workoutInterval struct{ start, end time.Time }

type recordedWorkoutDay struct {
	rule      string
	intervals []workoutInterval
	credited  *big.Rat
	dirty     bool
}

type workoutMetrics struct {
	quantities map[string]*big.Rat
	rates      map[string]activityRate
}

type workoutReceipt struct {
	ID      uuid.UUID `json:"workoutId"`
	Status  string    `json:"status"`
	Minutes string    `json:"newlyEligibleMinutes,omitempty"`
}

type workoutImport struct {
	ID      uuid.UUID      `json:"workout_id"`
	Payload map[string]any `json:"payload"`
	Outcome string         `json:"outcome"`
}

type workoutPlan struct {
	days              map[time.Time]*recordedWorkoutDay
	metrics           map[time.Time]workoutMetrics
	imports           []workoutImport
	receipts          []workoutReceipt
	milestoneWorkouts []milestoneWorkout
}

func (p *syncBucketPlanner) planWorkouts(owner string, input syncInput) (workoutPlan, error) {
	plan := workoutPlan{receipts: make([]workoutReceipt, 0, len(input.workouts))}
	if !input.workoutsAvailable {
		return plan, nil
	}
	if p.device.metrics["workouts"] == nil {
		p.device.markReady(p.boundary, p.today)
		p.device.setBaseline("workouts", map[string]string{"at": pythonTime(p.boundary)})
	}
	if len(input.workouts) == 0 {
		return plan, nil
	}
	var baseline struct{ At time.Time }
	if err := json.Unmarshal(p.device.metrics["workouts"], &baseline); err != nil || baseline.At.IsZero() {
		return plan, invalidActivityRules
	}
	cutoff := maxTime(p.device.enrolled, baseline.At)
	observedDate := calendarDate(p.observed, p.zone)
	earliest := maxTime(cutoff, activityDayStart(observedDate.AddDate(0, 0, -6), p.zone))
	workouts := slices.Clone(input.workouts)
	slices.SortFunc(workouts, func(a, b workoutInput) int {
		if order := a.start.Compare(b.start); order != 0 {
			return order
		}
		if order := cmp.Compare(a.source, b.source); order != 0 {
			return order
		}
		return cmp.Compare(a.id.String(), b.id.String())
	})
	ids := make([]uuid.UUID, len(workouts))
	for i, w := range workouts {
		ids[i] = w.id
	}
	rows, err := p.tx.Query(p.ctx, "SELECT workout_id FROM activity_workouts WHERE owner_id=$1 AND workout_id=ANY($2::uuid[])", owner, ids)
	if err != nil {
		return plan, err
	}
	saved, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return plan, err
	}
	known := make(map[uuid.UUID]bool, len(saved))
	for _, id := range saved {
		known[id] = true
	}
	if len(known) != len(workouts) && !earliest.After(p.observed) {
		plan.days, err = readWorkoutDays(p.ctx, p.tx, owner, calendarDate(earliest, p.zone), observedDate)
		if err != nil {
			return plan, err
		}
	} else {
		plan.days = make(map[time.Time]*recordedWorkoutDay)
	}
	plan.metrics = make(map[time.Time]workoutMetrics)
	for _, w := range workouts {
		if known[w.id] {
			plan.receipts = append(plan.receipts, workoutReceipt{ID: w.id, Status: "already_processed"})
			continue
		}
		receipt := workoutReceipt{ID: w.id, Minutes: "0"}
		switch {
		case w.manual:
			receipt.Status = "manual_excluded"
		case w.end.After(p.observed) || w.end.After(p.boundary):
			receipt.Status = "future_excluded"
		case !w.end.After(earliest):
			receipt.Status = "before_baseline_or_window"
		default:
			var uncapped *big.Rat
			if p.milestones {
				uncapped = new(big.Rat)
			}
			minutes, err := p.workoutMinutes(&plan, w, cutoff, earliest, uncapped)
			if err != nil {
				return plan, err
			}
			receipt.Status = "accepted"
			if minutes.Sign() == 0 {
				receipt.Status = "no_new_eligible_minutes"
			}
			receipt.Minutes = minutes.RatString()
			if uncapped != nil && uncapped.Sign() > 0 {
				plan.milestoneWorkouts = append(plan.milestoneWorkouts, milestoneWorkout{w, earliest, uncapped})
			}
		}
		plan.imports = append(plan.imports, workoutImport{w.id, w.payload, receipt.Status})
		plan.receipts = append(plan.receipts, receipt)
	}
	return plan, nil
}

func readWorkoutDays(ctx context.Context, tx pgx.Tx, owner string, first, last time.Time) (map[time.Time]*recordedWorkoutDay, error) {
	rows, err := tx.Query(ctx, `SELECT game_date,rule_version,covered_intervals,credited_microseconds,remainder
		FROM activity_workout_days WHERE owner_id=$1 AND game_date BETWEEN $2 AND $3`, owner, first, last)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	days := make(map[time.Time]*recordedWorkoutDay)
	for rows.Next() {
		var date time.Time
		var count int64
		var remainder map[string]json.RawMessage
		var wire [][2]string
		day := new(recordedWorkoutDay)
		if err := rows.Scan(&date, &day.rule, &wire, &count, &remainder); err != nil {
			return nil, err
		}
		if count < 0 {
			return nil, invalidActivityRules
		}
		fraction, err := growthRemainder(remainder)
		if err != nil {
			return nil, invalidActivityRules
		}
		day.credited = fraction.Add(fraction, big.NewRat(count, 1))
		for _, pair := range wire {
			a, firstErr := time.Parse(time.RFC3339Nano, pair[0])
			b, lastErr := time.Parse(time.RFC3339Nano, pair[1])
			if firstErr != nil || lastErr != nil || !b.After(a) {
				return nil, invalidActivityRules
			}
			day.intervals = addWorkoutCoverage(day.intervals, workoutInterval{a, b})
		}
		days[date] = day
	}
	return days, rows.Err()
}

func (p *syncBucketPlanner) workoutMinutes(plan *workoutPlan, w workoutInput, cutoff, earliest time.Time, uncapped *big.Rat) (*big.Rat, error) {
	segments := []workoutSegment{w.workoutSegment}
	if w.hasSegments {
		segments = slices.Clone(w.segments)
		slices.SortStableFunc(segments, func(a, b workoutSegment) int {
			if order := a.start.Compare(b.start); order != 0 {
				return order
			}
			if order := a.end.Compare(b.end); order != 0 {
				return order
			}
			return cmp.Compare(a.kind, b.kind)
		})
	}
	awarded := new(big.Rat)
	for _, segment := range segments {
		category := workoutCategories[segment.kind]
		if category == "" || segment.milliseconds == 0 {
			continue
		}
		metric := "workout_minutes." + category
		density := big.NewRat(segment.milliseconds*1000, workoutMicros(segment.start, segment.end))
		cursor, limit := maxTime(segment.start, earliest), segment.end
		for cursor.Before(limit) {
			date := calendarDate(cursor, p.zone)
			next := activityDayStart(date.AddDate(0, 0, 1), p.zone)
			if !next.After(cursor) {
				return nil, invalidActivityRules
			}
			stop := limit
			if next.Before(stop) {
				stop = next
			}
			add, err := p.creditWorkoutInterval(plan, date, cutoff, metric, workoutInterval{cursor, stop}, density, uncapped)
			if err != nil {
				return nil, err
			}
			awarded.Add(awarded, add)
			cursor = stop
		}
	}
	return awarded, nil
}

func (p *syncBucketPlanner) creditWorkoutInterval(plan *workoutPlan, date, cutoff time.Time, metric string, interval workoutInterval, density, uncapped *big.Rat) (*big.Rat, error) {
	day := plan.days[date]
	var rule activityRule
	var err error
	if day == nil {
		rule, err = p.rules.effective(p.ctx, p.tx, maxTime(activityDayStart(date, p.zone), cutoff))
		day = &recordedWorkoutDay{rule: rule.version, credited: new(big.Rat), dirty: true}
		plan.days[date] = day
	} else {
		rule, err = p.rules.pinned(p.ctx, p.tx, day.rule)
	}
	if err != nil {
		return nil, err
	}
	rate, enabled := rule.metrics[metric]
	if !enabled {
		return new(big.Rat), nil
	}
	fresh := workoutMicros(interval.start, interval.end)
	for _, covered := range day.intervals {
		if !covered.end.After(interval.start) {
			continue
		}
		if !covered.start.Before(interval.end) {
			break
		}
		start := maxTime(covered.start, interval.start)
		end := interval.end
		if covered.end.Before(end) {
			end = covered.end
		}
		fresh -= workoutMicros(start, end)
	}
	if fresh <= 0 {
		return new(big.Rat), nil
	}
	day.dirty = true
	day.intervals = addWorkoutCoverage(day.intervals, interval)
	next := new(big.Rat).Mul(density, big.NewRat(fresh, 1))
	if uncapped != nil {
		uncapped.Add(uncapped, new(big.Rat).Quo(next, big.NewRat(microsPerMinute, 1)))
	}
	next.Add(next, day.credited)
	cap := big.NewRat(rule.workoutCapSeconds*1_000_000, 1)
	if next.Cmp(cap) > 0 {
		next.Set(cap)
	}
	delta := new(big.Rat).Sub(next, day.credited)
	day.credited = next
	if delta.Sign() <= 0 {
		return new(big.Rat), nil
	}
	minutes := delta.Quo(delta, big.NewRat(microsPerMinute, 1))
	value, found := plan.metrics[date]
	if !found {
		value = workoutMetrics{map[string]*big.Rat{}, map[string]activityRate{}}
		plan.metrics[date] = value
	}
	if value.quantities[metric] == nil {
		value.quantities[metric] = new(big.Rat)
	}
	value.quantities[metric].Add(value.quantities[metric], minutes)
	value.rates[metric] = rate
	return minutes, nil
}

// Both interval lists and their results represent unions of half-open ranges.
func addWorkoutCoverage(covered []workoutInterval, added workoutInterval) []workoutInterval {
	low, high := 0, len(covered)
	for low < high {
		mid := (low + high) / 2
		if covered[mid].end.Before(added.start) {
			low = mid + 1
		} else {
			high = mid
		}
	}
	first, last := low, low
	for last < len(covered) && !covered[last].start.After(added.end) {
		if covered[last].start.Before(added.start) {
			added.start = covered[last].start
		}
		added.end = maxTime(added.end, covered[last].end)
		last++
	}
	return slices.Replace(covered, first, last, added)
}

func (p workoutPlan) persist(ctx context.Context, tx pgx.Tx, owner string, at time.Time) error {
	var batch pgx.Batch
	days := make([]map[string]any, 0, len(p.days))
	for date, day := range p.days {
		if !day.dirty {
			continue
		}
		pairs := make([][2]string, 0, len(day.intervals))
		for _, i := range day.intervals {
			pairs = append(pairs, [2]string{pythonTime(i.start), pythonTime(i.end)})
		}
		count := new(big.Int).Quo(day.credited.Num(), day.credited.Denom()).Int64()
		left := new(big.Rat).Sub(day.credited, big.NewRat(count, 1))
		remainder := map[string]string{}
		if left.Sign() > 0 {
			remainder = map[string]string{"numerator": left.Num().String(), "denominator": left.Denom().String()}
		}
		days = append(days, map[string]any{"game_date": date.Format(time.DateOnly), "rule_version": day.rule,
			"covered_intervals": pairs, "credited_microseconds": count, "remainder": remainder})
	}
	if len(days) > 0 {
		batch.Queue(`INSERT INTO activity_workout_days (owner_id,game_date,rule_version,covered_intervals,credited_microseconds,remainder)
			SELECT $1,r.game_date,r.rule_version,r.covered_intervals,r.credited_microseconds,r.remainder
			FROM jsonb_to_recordset($2::jsonb) r(game_date date,rule_version text,covered_intervals jsonb,credited_microseconds bigint,remainder jsonb)
			ON CONFLICT(owner_id,game_date) DO UPDATE SET covered_intervals=excluded.covered_intervals,
			credited_microseconds=excluded.credited_microseconds,remainder=excluded.remainder`, owner, days)
	}
	if len(p.imports) > 0 {
		batch.Queue(`INSERT INTO activity_workouts (owner_id,workout_id,accepted_at,payload,outcome)
			SELECT $1,r.workout_id,$3,r.payload,r.outcome
			FROM jsonb_to_recordset($2::jsonb) r(workout_id uuid,payload jsonb,outcome text)`, owner, p.imports, at)
	}
	if batch.Len() == 0 {
		return nil
	}
	return tx.SendBatch(ctx, &batch).Close()
}
