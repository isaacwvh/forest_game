package server

import (
	"context"
	"encoding/json"
	"math"
	"math/big"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type milestoneFacts map[string]json.RawMessage

func (f milestoneFacts) set(key string, value any) {
	// All callers pass validated integers, exact strings, or event day records.
	f[key], _ = json.Marshal(value)
}

func (f milestoneFacts) counter(key string) (int64, error) {
	raw, ok := f[key]
	if !ok {
		return 0, nil
	}
	var value int64
	if json.Unmarshal(raw, &value) != nil || value < 0 {
		return 0, milestonesUnavailable
	}
	return value, nil
}

func (f milestoneFacts) raise(key string, value int64) error {
	old, err := f.counter(key)
	if err != nil {
		return err
	}
	f.set(key, max(old, value))
	return nil
}

func (f milestoneFacts) raiseFraction(key string, value *big.Rat) error {
	var old string
	if raw, ok := f[key]; ok {
		if json.Unmarshal(raw, &old) != nil {
			return milestonesUnavailable
		}
		fact, err := milestoneFraction(old)
		if err != nil {
			return err
		}
		if fact.Cmp(value) > 0 {
			value = fact
		}
	}
	f.set(key, value.RatString())
	return nil
}

func milestoneFraction(value string) (*big.Rat, error) {
	if value == "" {
		return new(big.Rat), nil
	}
	r, ok := new(big.Rat).SetString(value)
	if !ok || r.Sign() < 0 {
		return nil, milestonesUnavailable
	}
	return r, nil
}

type milestoneWorkout struct {
	input    workoutInput
	earliest time.Time
	uncapped *big.Rat
}

func (f milestoneFacts) recordWorkout(evidence milestoneWorkout, effective time.Time) error {
	w := evidence.input
	if w.start.Before(maxTime(effective, evidence.earliest)) || evidence.uncapped.Sign() <= 0 {
		return nil
	}
	if err := f.raiseFraction("workout_minutes", evidence.uncapped); err != nil {
		return err
	}
	if w.kind != 37 || w.distance == nil {
		return nil
	}
	segments := []workoutSegment{w.workoutSegment}
	if w.hasSegments {
		segments = w.segments
	}
	var millis int64
	for _, segment := range segments {
		if segment.kind != 37 {
			return nil
		}
		millis += segment.milliseconds
	}
	if millis == 0 || evidence.uncapped.Cmp(big.NewRat(millis, 60000)) < 0 {
		return nil
	}
	distance, err := milestoneFraction(*w.distance)
	if err != nil {
		return err
	}
	if err := f.raiseFraction("running_metres", distance); err != nil {
		return err
	}
	for _, goal := range []struct {
		key      string
		distance int64
	}{{"first_run_5", 5000}, {"first_run_10", 10000}} {
		if _, exists := f[goal.key]; !exists && distance.Cmp(big.NewRat(goal.distance, 1)) >= 0 {
			f.set(goal.key, w.id.String())
		}
	}
	return nil
}

type milestoneDay struct {
	Date     time.Time `json:"-"`
	GameDate string    `json:"game_date"`
	Steps    int64     `json:"steps"`
	Minutes  string    `json:"workout_minutes"`
	Active   bool      `json:"active"`
}

func syncMilestoneMinutes(day syncDay) *big.Rat {
	sum := new(big.Rat)
	for metric, value := range day.newMetrics {
		if strings.HasPrefix(metric, "workout_minutes.") {
			sum.Add(sum, value)
		}
	}
	return sum
}

func milestoneAddDay(steps *int64, minutes *string, delta int64, extra *big.Rat) (bool, error) {
	if *steps > math.MaxInt64-delta {
		return false, amountOverflow
	}
	total, err := milestoneFraction(*minutes)
	if err != nil {
		return false, err
	}
	*steps += delta
	total.Add(total, extra)
	*minutes = total.RatString()
	return *steps >= 1000 || total.Cmp(big.NewRat(10, 1)) >= 0, nil
}

func observeMilestoneActivity(ctx context.Context, tx pgx.Tx, owner Profile, policy milestonePolicy, at time.Time,
	days []syncDay, workouts []milestoneWorkout, growth growthResult) error {
	if err := refreshMilestoneEntitlements(ctx, tx, owner.ID, at); err != nil {
		return err
	}
	var enrolled time.Time
	var facts milestoneFacts
	if err := tx.QueryRow(ctx, "SELECT enrolled_at,progress FROM milestone_state WHERE owner_id=$1", owner.ID).Scan(&enrolled, &facts); err != nil {
		return err
	}
	zone, err := time.LoadLocation(owner.Timezone)
	if err != nil {
		return err
	}
	for _, w := range workouts {
		if err := facts.recordWorkout(w, policy.effective); err != nil {
			return err
		}
	}
	if err := recordMilestoneDays(ctx, tx, owner.ID, calendarDate(enrolled, zone), facts, days); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "UPDATE milestone_state SET progress=$2::jsonb WHERE owner_id=$1", owner.ID, facts); err != nil {
		return err
	}
	grew := slices.ContainsFunc(growth.plants, func(p activityPlant) bool {
		return p.growth > p.before && p.stage(p.before) == "sprout"
	})
	if err := observeMilestoneActivityEvents(ctx, tx, owner.ID, at, zone, days, grew); err != nil {
		return err
	}
	return refreshMilestoneEntitlements(ctx, tx, owner.ID, at)
}

func recordMilestoneDays(ctx context.Context, tx pgx.Tx, owner string, start time.Time, facts milestoneFacts, days []syncDay) error {
	var dates []time.Time
	for _, day := range days {
		if !day.date.Before(start) {
			dates = append(dates, day.date)
		}
	}
	if len(dates) == 0 {
		return nil
	}
	rows, err := tx.Query(ctx, `SELECT game_date,steps,workout_minutes,active FROM milestone_days WHERE owner_id=$1
		AND game_date BETWEEN $2 AND $3 AND (active OR game_date=ANY($4::date[]))`,
		owner, dates[0].AddDate(0, 0, -13), dates[len(dates)-1].AddDate(0, 0, 13), dates)
	if err != nil {
		return err
	}
	prior, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (milestoneDay, error) {
		var d milestoneDay
		err := row.Scan(&d.Date, &d.Steps, &d.Minutes, &d.Active)
		return d, err
	})
	if err != nil {
		return err
	}
	factsByDate := make(map[time.Time]milestoneDay, len(prior)+len(dates))
	for _, day := range prior {
		factsByDate[day.Date] = day
	}
	activeDays, err := facts.counter("activity_days")
	if err != nil {
		return err
	}
	var updates []milestoneDay
	for _, day := range days {
		if day.date.Before(start) {
			continue
		}
		d := factsByDate[day.date]
		d.Date, d.GameDate = day.date, day.date.Format(time.DateOnly)
		active, err := milestoneAddDay(&d.Steps, &d.Minutes, day.NewlyEligible, syncMilestoneMinutes(day))
		if err != nil {
			return err
		}
		if active && !d.Active {
			if activeDays == math.MaxInt64 {
				return amountOverflow
			}
			activeDays++
			d.Active = true
		}
		if err := facts.raise("daily_steps", d.Steps); err != nil {
			return err
		}
		factsByDate[day.date] = d
		updates = append(updates, d)
	}
	facts.set("activity_days", activeDays)
	var active []time.Time
	for date, day := range factsByDate {
		if day.Active {
			active = append(active, date)
		}
	}
	slices.SortFunc(active, time.Time.Compare)
	for _, date := range dates {
		if err := facts.raise("rolling_days", milestoneRollingWindow(active, date)); err != nil {
			return err
		}
	}
	_, err = tx.Exec(ctx, `INSERT INTO milestone_days(owner_id,game_date,steps,workout_minutes,active)
		SELECT $1,d.game_date,d.steps,d.workout_minutes,d.active
		FROM jsonb_to_recordset($2::jsonb) d(game_date date,steps bigint,workout_minutes text,active bool)
		ON CONFLICT(owner_id,game_date) DO UPDATE SET steps=excluded.steps,workout_minutes=excluded.workout_minutes,active=excluded.active`,
		owner, updates)
	return err
}

func milestoneRollingWindow(active []time.Time, date time.Time) int64 {
	var best int64
	from, through := date.AddDate(0, 0, -13), date.AddDate(0, 0, 13)
	end := 0
	for start, day := range active {
		if day.Before(from) {
			continue
		}
		if day.After(through) {
			break
		}
		end = max(end, start)
		for end < len(active) && !active[end].After(through) && active[end].Before(day.AddDate(0, 0, 14)) {
			end++
		}
		best = max(best, int64(end-start))
	}
	return best
}
