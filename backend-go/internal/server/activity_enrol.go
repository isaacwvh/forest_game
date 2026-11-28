package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

const enrollmentOperation = "activity_enrolment"

var quantityDistance = regexp.MustCompile(`^[0-9]{1,9}(\.[0-9]{1,3})?$`)
var quantityEnergy = regexp.MustCompile(`^[0-9]{1,7}(\.[0-9]{1,3})?$`)

type enrollment struct {
	key, installation uuid.UUID
	expected          *uuid.UUID
	observed          time.Time
	steps             *int64
	metrics           map[string]int64
	workouts          bool
	digest            string
}

func parseEnrollment(r *http.Request) (enrollment, error) {
	v := enrollment{metrics: make(map[string]int64)}
	fields, err := readBody(r, "requestId", "installationId", "expectedDeviceId", "observedAt", "steps",
		"walkingRunningDistanceMetres", "activeEnergyKcal", "flightsClimbed", "workoutsAvailable")
	if err != nil {
		return v, err
	}
	if v.key, err = requestID(fields); err != nil {
		return v, err
	}
	installation, err := stringField(fields, "installationId")
	if err != nil {
		return v, err
	}
	if v.installation, err = uuid.Parse(installation); err != nil {
		return v, invalid
	}
	observed, err := stringField(fields, "observedAt")
	if err != nil {
		return v, err
	}
	v.observed, err = time.Parse(time.RFC3339Nano, observed)
	if err != nil {
		return v, invalid
	}
	v.observed = v.observed.Truncate(time.Microsecond)
	if field, ok := fields["expectedDeviceId"]; ok {
		err = json.Unmarshal(field, &v.expected)
		if err != nil {
			return v, invalid
		}
	}
	if field, ok := fields["steps"]; ok {
		if err := json.Unmarshal(field, &v.steps); err != nil || v.steps != nil && (*v.steps < 0 || *v.steps > 1_000_000_000) {
			return v, invalid
		}
	}
	payload := map[string]any{"installationId": v.installation, "expectedDeviceId": v.expected, "steps": v.steps,
		"observedAt": normalizedObservation(v.observed)}
	v.metrics, err = readDailyMeasurements(fields, payload)
	if err != nil {
		return v, err
	}
	if field, ok := fields["workoutsAvailable"]; ok {
		if err := json.Unmarshal(field, &v.workouts); err != nil || string(field) == "null" {
			return v, invalid
		}
		if v.workouts {
			payload["workoutsAvailable"] = true
		}
	}
	v.digest, err = requestDigest(enrollmentOperation, payload)
	return v, err
}

func readDailyMeasurements(fields map[string]json.RawMessage, payload map[string]any) (map[string]int64, error) {
	metrics := make(map[string]int64)
	for _, item := range []struct {
		field, metric string
		pattern       *regexp.Regexp
	}{
		{"walkingRunningDistanceMetres", "walking_running_distance_km", quantityDistance},
		{"activeEnergyKcal", "active_energy_kcal", quantityEnergy},
	} {
		if entry, ok := fields[item.field]; ok {
			var raw *string
			if err := json.Unmarshal(entry, &raw); err != nil {
				return nil, invalid
			}
			if raw == nil {
				continue
			}
			if !item.pattern.MatchString(*raw) {
				return nil, invalid
			}
			parts := strings.SplitN(*raw, ".", 2)
			whole, _ := strconv.ParseInt(parts[0], 10, 64)
			var fractional int64
			if len(parts) > 1 {
				fractional, _ = strconv.ParseInt((parts[1] + "000")[:3], 10, 64)
			}
			metrics[item.metric] = whole*1000 + fractional
			payload[item.field] = *raw
		}
	}
	if field, ok := fields["flightsClimbed"]; ok {
		var flights *int64
		if err := json.Unmarshal(field, &flights); err != nil || flights != nil && (*flights < 0 || *flights > 1_000_000) {
			return nil, invalid
		}
		if flights != nil {
			metrics["flights_climbed"] = *flights
			payload["flightsClimbed"] = *flights
		}
	}
	return metrics, nil
}

func normalizedObservation(at time.Time) string {
	if at.Nanosecond() == 0 {
		return at.Format(time.RFC3339)
	}
	return at.Format("2006-01-02T15:04:05.000000Z07:00")
}

func (s *Server) activityEnrol(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	input, err := parseEnrollment(r)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if saved, err := replay(ctx, tx, owner.ID, input.key, enrollmentOperation, input.digest,
		r.Header.Get("X-Forest-Recovery") == "1"); err != nil || saved != nil {
		return saved, err
	}
	var garden string
	if err := tx.QueryRow(ctx, "SELECT id::text FROM gardens WHERE owner_id=$1 FOR UPDATE", owner.ID).Scan(&garden); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, &apiError{503, "garden_unavailable", "Account garden is unavailable"}
		}
		return nil, err
	}
	var now time.Time
	var deviceID, installation *uuid.UUID
	err = tx.QueryRow(ctx, `SELECT clock_timestamp(),
		(SELECT id FROM activity_devices WHERE owner_id=$1 AND revoked_at IS NULL),
		(SELECT installation_id FROM activity_devices WHERE owner_id=$1 AND revoked_at IS NULL)`, owner.ID).
		Scan(&now, &deviceID, &installation)
	if err != nil {
		return nil, err
	}
	now = now.UTC()
	if input.observed.After(now.Add(5 * time.Minute)) {
		return nil, &apiError{422, "future_observation", "Observation is in the future"}
	}
	if now.Sub(input.observed) > 5*time.Minute {
		return nil, &apiError{422, "observation_expired", "Take a fresh activity observation"}
	}
	sameDevice := installation != nil && *installation == input.installation
	stale := input.expected != nil && (deviceID == nil || *deviceID != *input.expected)
	if stale || !sameDevice && input.expected == nil && deviceID != nil {
		message := "Explicit device replacement required"
		if sameDevice {
			message = "Refresh activity device status"
		}
		return nil, &apiError{409, "stale_activity_device", message}
	}
	if !sameDevice {
		key, err := s.createActivityDevice(ctx, tx, owner, now, input, deviceID)
		if err != nil {
			return nil, err
		}
		deviceID = &key
	}
	var device json.RawMessage
	err = tx.QueryRow(ctx, `SELECT jsonb_build_object('deviceId',id,'installationId',installation_id,'enrolledAt',enrolled_at,
		'baselineDate',baseline_date,'baselineObservedAt',baseline_observed_at,
		'baselineSteps',baseline_steps,'ready',baseline_date IS NOT NULL,'metricBaselines',metric_baselines)
		FROM activity_devices WHERE owner_id=$1 AND id=$2`, owner.ID, deviceID).Scan(&device)
	if err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": input.key, "device": device}
	return result, saveSmallRecoveryReceipt(r, tx, owner.ID, input.key, enrollmentOperation, input.digest, result)
}

func (s *Server) createActivityDevice(ctx context.Context, tx pgx.Tx, owner Profile, now time.Time, input enrollment, old *uuid.UUID) (uuid.UUID, error) {
	key := uuid.New()
	var rule string
	var fixture bool
	err := tx.QueryRow(ctx, `SELECT version,is_fixture FROM economy_configs WHERE effective_at<=$1 ORDER BY effective_at DESC LIMIT 1`, now).Scan(&rule, &fixture)
	if errors.Is(err, pgx.ErrNoRows) {
		return key, &apiError{503, "activity_rules_unavailable", "Activity rules are unavailable"}
	}
	if err != nil {
		return key, err
	}
	if fixture && s.Environment != "local" && s.Environment != "test" {
		return key, &apiError{503, "fixture_economy_disabled", "Development activity rules are disabled"}
	}
	zone, err := time.LoadLocation(owner.Timezone)
	if err != nil {
		return key, err
	}
	day := now.In(zone)
	date := day.Format(time.DateOnly)
	if (input.steps != nil || len(input.metrics) > 0) && input.observed.In(zone).Format(time.DateOnly) != date {
		return key, &apiError{422, "baseline_date_mismatch", "Take a fresh current-day observation"}
	}
	base := map[string]any{}
	var baseline, observed *time.Time
	var baselineDate *string
	var steps *int64
	if input.steps != nil || len(input.metrics) > 0 || input.workouts {
		baseline, observed, baselineDate, steps = &now, &now, &date, new(int64)
		base["steps"] = map[string]bool{"ready": input.steps != nil}
		if input.steps != nil {
			steps, observed = input.steps, &input.observed
		}
	}
	for metric := range input.metrics {
		base[metric] = map[string]string{"date": date, "at": now.Format(time.RFC3339Nano)}
	}
	if input.workouts {
		base["workouts"] = map[string]string{"at": now.Format(time.RFC3339Nano)}
	}
	var batch pgx.Batch
	if old != nil {
		batch.Queue("UPDATE activity_devices SET revoked_at=$2 WHERE id=$1", old, now)
	}
	var dateValue *time.Time
	if baselineDate != nil {
		d := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, time.UTC)
		dateValue = &d
	}
	batch.Queue(`INSERT INTO activity_devices (id,owner_id,installation_id,enrolled_at,baseline_at,
		baseline_observed_at,baseline_date,baseline_steps,metric_baselines) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb)`,
		key, owner.ID, input.installation, now, baseline, observed, dateValue, steps, base)
	if input.steps != nil {
		dayStart := time.Date(day.Year(), day.Month(), day.Day(), 0, 0, 0, 0, zone)
		batch.Queue(`INSERT INTO activity_days (owner_id,game_date,game_timezone,bucket_start,bucket_end,device_id,
			rule_version,baseline_steps,baseline_credit_steps,observed_steps,observed_at,is_available,credited_steps)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,0,$8,$9,true,0)
			ON CONFLICT (owner_id,game_date) DO UPDATE SET device_id=excluded.device_id,
			baseline_steps=excluded.baseline_steps,baseline_credit_steps=activity_days.credited_steps,
			observed_steps=excluded.observed_steps,observed_at=excluded.observed_at,is_available=true`,
			owner.ID, dateValue, owner.Timezone, dayStart, dayStart.AddDate(0, 0, 1), key, rule, input.steps, input.observed)
	}
	for metric, value := range input.metrics {
		batch.Queue(`INSERT INTO activity_metric_days (owner_id,game_date,metric,device_id,rule_version,baseline,
			baseline_credit,credited,observed,observed_at) VALUES ($1,$2,$3,$4,$5,$6,0,0,$6,$7)
			ON CONFLICT (owner_id,game_date,metric) DO UPDATE SET device_id=excluded.device_id,baseline=excluded.baseline,
			baseline_credit=activity_metric_days.credited,
			observed=CASE WHEN excluded.observed_at>=activity_metric_days.observed_at THEN excluded.observed ELSE activity_metric_days.observed END,
			observed_at=GREATEST(activity_metric_days.observed_at,excluded.observed_at)`,
			owner.ID, dateValue, metric, key, rule, value, input.observed)
	}
	return key, tx.SendBatch(ctx, &batch).Close()
}
