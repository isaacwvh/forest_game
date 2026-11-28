package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const activitySyncOperation = "activity_sync"

type syncEntry struct {
	date    time.Time
	steps   *int64
	metrics map[string]int64
}

type syncInput struct {
	key, device, installation uuid.UUID
	observed                  time.Time
	days                      []syncEntry
	workoutsAvailable         bool
	workouts                  []workoutInput
	digest                    string
}

func parseActivitySync(r *http.Request) (syncInput, error) {
	var input syncInput
	const activityBodyLimit = 4 * 1024 * 1024
	fields, err := readBodySized(r, activityBodyLimit, "requestId", "deviceId", "installationId", "observedAt", "days", "workoutsAvailable", "workouts")
	if err != nil {
		return input, err
	}
	if input.key, err = requestID(fields); err != nil {
		return input, err
	}
	if input.device, err = syncUUID(fields, "deviceId"); err != nil {
		return input, err
	}
	if input.installation, err = syncUUID(fields, "installationId"); err != nil {
		return input, err
	}
	observed, err := stringField(fields, "observedAt")
	if err != nil {
		return input, err
	}
	if input.observed, err = time.Parse(time.RFC3339Nano, observed); err != nil {
		return input, invalid
	}
	input.observed = input.observed.Truncate(time.Microsecond)
	if raw := fields["workoutsAvailable"]; raw != nil &&
		(json.Unmarshal(raw, &input.workoutsAvailable) != nil || string(raw) == "null") {
		return input, invalid
	}
	var workouts []json.RawMessage
	if raw := fields["workouts"]; raw != nil && (json.Unmarshal(raw, &workouts) != nil || workouts == nil || len(workouts) > 500) {
		return input, invalid
	}
	if len(workouts) > 0 && !input.workoutsAvailable {
		return input, invalid
	}

	var days []json.RawMessage
	if json.Unmarshal(fields["days"], &days) != nil || len(days) < 1 || len(days) > 7 {
		return input, invalid
	}
	payloadDays := make([]map[string]any, 0, len(days))
	seen := make(map[time.Time]bool, len(days))
	for _, raw := range days {
		nested := &http.Request{Body: io.NopCloser(bytes.NewReader(raw))}
		day, err := readBody(nested, "gameDate", "steps", "walkingRunningDistanceMetres", "activeEnergyKcal", "flightsClimbed")
		if err != nil {
			return input, invalid
		}
		text, err := stringField(day, "gameDate")
		if err != nil {
			return input, invalid
		}
		date, err := time.Parse(time.DateOnly, text)
		if err != nil || date.Year() < 1 || seen[date] {
			return input, invalid
		}
		seen[date] = true
		entry := syncEntry{date: date}
		if json.Unmarshal(day["steps"], &entry.steps) != nil || entry.steps != nil && (*entry.steps < 0 || *entry.steps > 1_000_000_000) {
			return input, invalid
		}
		payload := map[string]any{"gameDate": text, "steps": entry.steps}
		entry.metrics, err = readDailyMeasurements(day, payload)
		if err != nil {
			return input, err
		}
		input.days = append(input.days, entry)
		payloadDays = append(payloadDays, payload)
	}
	payload := map[string]any{"installationId": input.installation, "deviceId": input.device,
		"observedAt": normalizedObservation(input.observed), "days": payloadDays}
	if input.workoutsAvailable {
		payload["workoutsAvailable"] = true
	}
	if len(workouts) > 0 {
		var documents []map[string]any
		input.workouts, documents, err = parseWorkouts(workouts)
		if err != nil {
			return input, err
		}
		payload["workouts"] = documents
	}
	input.digest, err = requestDigest(activitySyncOperation, payload)
	slices.SortFunc(input.days, func(a, b syncEntry) int { return a.date.Compare(b.date) })
	return input, err
}

func syncUUID(fields map[string]json.RawMessage, name string) (uuid.UUID, error) {
	text, err := stringField(fields, name)
	if err != nil {
		return uuid.Nil, err
	}
	id, err := uuid.Parse(text)
	if err != nil {
		return uuid.Nil, invalid
	}
	return id, nil
}

type syncDevice struct {
	id, installation                           uuid.UUID
	enrolled                                   time.Time
	baselineAt, baselineObserved, baselineDate *time.Time
	baselineSteps                              *int64
	metrics                                    map[string]json.RawMessage
	dirty                                      bool
}

func readSyncDevice(ctx context.Context, tx pgx.Tx, owner string, input syncInput) (syncDevice, error) {
	var d syncDevice
	err := tx.QueryRow(ctx, `SELECT id,installation_id,enrolled_at,baseline_at,baseline_observed_at,baseline_date,baseline_steps,metric_baselines
		FROM activity_devices WHERE owner_id=$1 AND revoked_at IS NULL`, owner).
		Scan(&d.id, &d.installation, &d.enrolled, &d.baselineAt, &d.baselineObserved, &d.baselineDate, &d.baselineSteps, &d.metrics)
	if errors.Is(err, pgx.ErrNoRows) || err == nil && (d.id != input.device || d.installation != input.installation) {
		return d, &apiError{409, "inactive_activity_device", "Enrol the active reporting device"}
	}
	return d, err
}

func (d syncDevice) document() map[string]any {
	var date any
	if d.baselineDate != nil {
		date = d.baselineDate.Format(time.DateOnly)
	}
	return map[string]any{"deviceId": d.id, "installationId": d.installation, "enrolledAt": d.enrolled,
		"baselineDate": date, "baselineObservedAt": d.baselineObserved, "baselineSteps": d.baselineSteps,
		"ready": date != nil, "metricBaselines": d.metrics}
}

func (d *syncDevice) stepReady() bool {
	if raw := d.metrics["steps"]; raw != nil {
		var value struct{ Ready *bool }
		if json.Unmarshal(raw, &value) == nil && value.Ready != nil {
			return *value.Ready
		}
	}
	return d.baselineDate != nil
}

func (d *syncDevice) setBaseline(metric string, value any) {
	// The caller only supplies maps containing booleans or clock-generated strings.
	raw, _ := json.Marshal(value)
	if d.metrics == nil {
		d.metrics = make(map[string]json.RawMessage)
	}
	d.metrics[metric] = raw
	d.dirty = true
}

func (d *syncDevice) markReady(boundary, today time.Time) {
	if d.baselineDate == nil {
		d.baselineAt, d.baselineObserved, d.baselineDate, d.baselineSteps = &boundary, &boundary, &today, new(int64)
		d.setBaseline("steps", map[string]bool{"ready": false})
	}
}

func (d *syncDevice) establishSteps(steps int64, boundary, today, observed time.Time) {
	d.baselineAt, d.baselineObserved, d.baselineDate, d.baselineSteps = &boundary, &observed, &today, &steps
	d.setBaseline("steps", map[string]bool{"ready": true})
}

func calendarDate(at time.Time, zone *time.Location) time.Time {
	day := at.In(zone)
	return time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
}

func activityDayStart(date time.Time, zone *time.Location) time.Time {
	return time.Date(date.Year(), date.Month(), date.Day(), 0, 0, 0, 0, zone)
}

func validateActivityWindow(input syncInput, d syncDevice, boundary time.Time, zone *time.Location) error {
	if err := checkActivityObservation(input.observed, boundary, 30*24*time.Hour); err != nil {
		return err
	}
	if d.baselineObserved != nil && input.observed.Before(*d.baselineObserved) {
		return &apiError{422, "before_activity_baseline", "Observation predates device baseline"}
	}
	today, observed := calendarDate(boundary, zone), calendarDate(input.observed, zone)
	for _, entry := range input.days {
		if entry.date.After(today) || entry.date.After(observed) {
			return &apiError{422, "future_game_date", "Game date is in the future"}
		}
		if entry.date.Before(observed.AddDate(0, 0, -6)) {
			return &apiError{422, "activity_day_expired", "Game date is outside reconciliation"}
		}
		minimum := today
		if d.baselineDate != nil {
			minimum = *d.baselineDate
		}
		if entry.date.Before(minimum) {
			return &apiError{422, "before_activity_baseline", "Game date predates baseline"}
		}
		if d.baselineDate == nil && !entry.date.Equal(today) {
			return &apiError{409, "activity_baseline_required", "Observe today's steps first"}
		}
	}
	return nil
}

func checkActivityObservation(observed, boundary time.Time, maximumAge time.Duration) error {
	if observed.After(boundary.Add(5 * time.Minute)) {
		return &apiError{422, "future_observation", "Observation is in the future"}
	}
	if boundary.Sub(observed) > maximumAge {
		return &apiError{422, "observation_expired", "Take a fresh activity observation"}
	}
	return nil
}

var dailySyncMetrics = [...]struct {
	name    string
	divisor int64
}{
	{"walking_running_distance_km", 1_000_000},
	{"active_energy_kcal", 1000},
	{"flights_climbed", 1},
}

type activityRate struct {
	Normalisation string `json:"normalisation"`
	Water         int64  `json:"water_micro_units"`
	Cap           *int64 `json:"daily_cap"`
}

type activityRule struct {
	version           string
	metrics           map[string]activityRate
	workoutCapSeconds int64
}

type syncRules struct {
	byVersion     map[string]activityRule
	byEffectiveAt map[time.Time]string
	allowFixture  bool
}

var invalidActivityRules = &apiError{503, "invalid_activity_rules", "Activity rules require maintenance"}

func (c *syncRules) effective(ctx context.Context, tx pgx.Tx, at time.Time) (activityRule, error) {
	at = at.UTC()
	if v := c.byEffectiveAt[at]; v != "" {
		return c.byVersion[v], nil
	}
	rule, err := c.load(ctx, tx, "", at)
	if err == nil {
		c.byEffectiveAt[at] = rule.version
	}
	return rule, err
}

func (c *syncRules) pinned(ctx context.Context, tx pgx.Tx, version string) (activityRule, error) {
	if rule, ok := c.byVersion[version]; ok {
		return rule, nil
	}
	return c.load(ctx, tx, version, time.Time{})
}

func (c *syncRules) load(ctx context.Context, tx pgx.Tx, version string, at time.Time) (activityRule, error) {
	var rule activityRule
	var fixture bool
	var rows pgx.Row
	const selection = `SELECT version,is_fixture,rules->'metrics',
		COALESCE((rules->>'workout_daily_cap_seconds')::bigint,7200) FROM economy_configs`
	if version == "" {
		rows = tx.QueryRow(ctx, selection+` WHERE effective_at<=$1 ORDER BY effective_at DESC LIMIT 1`, at)
	} else {
		rows = tx.QueryRow(ctx, selection+` WHERE version=$1`, version)
	}
	err := rows.Scan(&rule.version, &fixture, &rule.metrics, &rule.workoutCapSeconds)
	if errors.Is(err, pgx.ErrNoRows) {
		return rule, &apiError{503, "activity_rules_unavailable", "Activity rules are unavailable"}
	}
	if err != nil {
		return rule, err
	}
	if fixture && !c.allowFixture {
		return rule, &apiError{503, "fixture_rules_disabled", "Development rules are disabled"}
	}
	if _, ok := rule.metrics["steps"]; !ok || rule.workoutCapSeconds < 0 || rule.workoutCapSeconds > 86400 {
		return rule, invalidActivityRules
	}
	for _, rate := range rule.metrics {
		if !rate.valid() {
			return rule, invalidActivityRules
		}
	}
	c.byVersion[rule.version] = rule
	return rule, nil
}

func (r activityRate) valid() bool {
	normal, err := activityCoefficient(r.Normalisation)
	return err == nil && normal > 0 && r.Water >= 0 && (r.Cap == nil || *r.Cap >= 0 && *r.Cap <= 1_000_000_000)
}

func activityCoefficient(text string) (int64, error) {
	return gardenUnits(strings.TrimSpace(text), 1_000_000, 1_000_000_000_000)
}
