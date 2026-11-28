package server

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type expeditionDayEvidence struct {
	Date             time.Time `json:"date"`
	Start            time.Time `json:"starts_at"`
	Through          time.Time `json:"through"`
	Steps            *int64    `json:"steps"`
	WorkoutsComplete bool      `json:"workouts_complete"`
}

type expeditionEvidence struct {
	request, device, installation uuid.UUID
	observed                      time.Time
	days                          []expeditionDayEvidence
	workouts                      []workoutInput
	digest                        string
}

func expeditionWireTime(fields map[string]json.RawMessage, key string) (time.Time, error) {
	text, err := stringField(fields, key)
	if err != nil {
		return time.Time{}, err
	}
	t, err := time.Parse(time.RFC3339Nano, text)
	if err != nil || t.Year() < 1 {
		return time.Time{}, invalid
	}
	return t.Truncate(time.Microsecond), nil
}

func parseExpeditionEvidence(r *http.Request, operation string) (expeditionEvidence, error) {
	var result expeditionEvidence
	fields, err := readBodySized(r, 4*1024*1024, "schemaVersion", "requestId", "deviceId", "installationId", "observedAt", "days", "workouts")
	if err != nil {
		return result, err
	}
	if result.request, err = requestID(fields); err != nil {
		return result, err
	}
	if result.device, err = syncUUID(fields, "deviceId"); err != nil {
		return result, err
	}
	if result.installation, err = syncUUID(fields, "installationId"); err != nil {
		return result, err
	}
	if result.observed, err = expeditionWireTime(fields, "observedAt"); err != nil {
		return result, err
	}
	if raw := fields["schemaVersion"]; raw != nil {
		var version int
		if json.Unmarshal(raw, &version) != nil || version != 1 {
			return result, invalid
		}
	}
	var days []json.RawMessage
	if json.Unmarshal(fields["days"], &days) != nil || len(days) < 1 || len(days) > 7 {
		return result, invalid
	}
	seen := make(map[time.Time]bool, len(days))
	docs := make([]map[string]any, 0, len(days))
	for _, raw := range days {
		day, err := readBody(&http.Request{Body: io.NopCloser(bytes.NewReader(raw))}, "gameDate", "startsAt", "through", "steps", "workoutsComplete")
		if err != nil {
			return result, err
		}
		text, err := stringField(day, "gameDate")
		if err != nil {
			return result, err
		}
		d := expeditionDayEvidence{}
		d.Date, err = time.Parse(time.DateOnly, text)
		if err != nil || d.Date.Year() < 1 || seen[d.Date] {
			return result, invalid
		}
		seen[d.Date] = true
		if d.Start, err = expeditionWireTime(day, "startsAt"); err != nil {
			return result, err
		}
		if d.Through, err = expeditionWireTime(day, "through"); err != nil {
			return result, err
		}
		if raw := day["steps"]; raw != nil && (json.Unmarshal(raw, &d.Steps) != nil || d.Steps != nil && (*d.Steps < 0 || *d.Steps > 1_000_000_000)) {
			return result, invalid
		}
		if raw := day["workoutsComplete"]; raw != nil && (json.Unmarshal(raw, &d.WorkoutsComplete) != nil || string(raw) == "null") {
			return result, invalid
		}
		docs = append(docs, map[string]any{"gameDate": text, "startsAt": normalizedObservation(d.Start),
			"through": normalizedObservation(d.Through), "steps": d.Steps, "workoutsComplete": d.WorkoutsComplete})
		result.days = append(result.days, d)
	}
	var workouts []json.RawMessage
	if raw := fields["workouts"]; raw != nil && (json.Unmarshal(raw, &workouts) != nil || workouts == nil || len(workouts) > 500) {
		return result, invalid
	}
	var workoutDocs []map[string]any
	result.workouts, workoutDocs, err = parseWorkouts(workouts)
	if err != nil {
		return result, err
	}
	result.digest, err = requestDigest(operation, map[string]any{"schemaVersion": 1, "deviceId": result.device,
		"installationId": result.installation, "observedAt": normalizedObservation(result.observed), "days": docs, "workouts": workoutDocs})
	return result, err
}

func (s *Server) uploadExpeditionEvidence(r *http.Request, tx pgx.Tx, identity Identity) (any, error) {
	if r.Header.Get("X-Forest-Expeditions") != "1" {
		return nil, expeditionClientUpdate
	}
	id, err := uuid.Parse(r.PathValue("run"))
	if err != nil {
		return nil, invalid
	}
	op := "expedition_evidence:" + id.String()
	input, err := parseExpeditionEvidence(r, op)
	if err != nil {
		return nil, err
	}
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, identity, true)
	if err != nil {
		return nil, err
	}
	if saved, err := replayRecoverableMutation(r, tx, owner.ID, input.request, op, input.digest); err != nil || saved != nil {
		return saved, err
	}
	run, err := readExpeditionRun(ctx, tx, owner.ID, id)
	if err != nil {
		return nil, err
	}
	now, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	if !now.Before(run.evidenceUntil) {
		return nil, &apiError{409, "expedition_evidence_expired", "This expedition's evidence deadline has passed"}
	}
	if input.observed.After(now.Add(5*time.Minute)) || input.observed.Before(run.start) || now.Sub(input.observed) > 39*24*time.Hour {
		return nil, &apiError{422, "invalid_observation", "Take a fresh expedition observation"}
	}
	var created, workoutBaseline, baseline time.Time
	err = tx.QueryRow(ctx, `SELECT u.created_at,d.baseline_at,
		COALESCE((d.metric_baselines#>>'{workouts,at}')::timestamptz,d.enrolled_at)
		FROM users u JOIN activity_devices d ON d.owner_id=u.id
		WHERE u.id=$1 AND d.id=$2 AND d.installation_id=$3 AND d.revoked_at IS NULL AND d.baseline_at IS NOT NULL`,
		owner.ID, input.device, input.installation).Scan(&created, &baseline, &workoutBaseline)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{409, "inactive_activity_device", "Refresh the enrolled activity device"}
	}
	if err != nil {
		return nil, err
	}
	earliest := expeditionEligibility(created, baseline, run.start)
	for _, day := range input.days {
		end := day.Date.AddDate(0, 0, 1)
		through := minExpeditionTime(end, run.end, input.observed, now)
		if !day.Date.Before(run.end) || !end.After(run.start) || !day.Start.Equal(maxTime(day.Date, earliest)) ||
			!day.Start.Before(day.Through) || day.Through.After(through) {
			return nil, &apiError{422, "invalid_expedition_interval", "Evidence must use the eligible UTC date interval"}
		}
	}
	workouts, err := recordExpeditionWorkouts(ctx, tx, run, input, now, maxTime(earliest, workoutBaseline))
	if err != nil {
		return nil, err
	}
	_, err = tx.Exec(ctx, `INSERT INTO expedition_days(run_id,device_id,game_date,starts_at,steps,steps_through,workouts_through)
		SELECT $1,$2,d.date,d.starts_at,COALESCE(d.steps,0),CASE WHEN d.steps IS NOT NULL THEN d.through END,
			CASE WHEN d.workouts_complete THEN d.through END
		FROM jsonb_to_recordset($3::jsonb) d(date date,starts_at timestamptz,through timestamptz,steps bigint,workouts_complete bool)
		ON CONFLICT(run_id,device_id,game_date) DO UPDATE SET steps=greatest(expedition_days.steps,excluded.steps),
		steps_through=greatest(expedition_days.steps_through,excluded.steps_through),
		workouts_through=greatest(expedition_days.workouts_through,excluded.workouts_through)`, id, input.device, input.days)
	if err != nil {
		return nil, err
	}
	var days, steps int64
	err = tx.QueryRow(ctx, `SELECT count(*) FILTER(WHERE total>=5000),least(COALESCE(sum(total),0),9223372036854775807)::bigint
		FROM (SELECT sum(steps) AS total FROM expedition_days WHERE run_id=$1 GROUP BY game_date) d`, id).Scan(&days, &steps)
	if err != nil {
		return nil, err
	}
	updates := []expeditionUpdate{expeditionCount("steps_days_3", days), expeditionCount("monthly_steps_30000", steps)}
	if len(workouts) > 0 {
		updates = append(updates, expeditionUpdate{Key: "run_walk_sessions_3", Identities: workouts})
	}
	if err := setExpeditionProgress(ctx, tx, id, nil, now, updates); err != nil {
		return nil, err
	}
	var version int64
	if err := tx.QueryRow(ctx, "SELECT progress_version FROM expedition_runs WHERE id=$1", id).Scan(&version); err != nil {
		return nil, err
	}
	result := map[string]any{"requestId": input.request, "runId": id, "progressVersion": version, "acceptedAt": now}
	return result, saveSmallRecoveryReceipt(r, tx, owner.ID, input.request, op, input.digest, result)
}

func minExpeditionTime(first time.Time, rest ...time.Time) time.Time {
	for _, t := range rest {
		if t.Before(first) {
			first = t
		}
	}
	return first
}

type expeditionWorkoutRow struct {
	ID        uuid.UUID      `json:"id"`
	Payload   map[string]any `json:"payload"`
	Intervals [][2]time.Time `json:"intervals"`
	Outcome   string         `json:"outcome"`
}

type expeditionWorkoutWindow struct {
	ID    uuid.UUID `json:"id"`
	Start time.Time `json:"starts_at"`
	End   time.Time `json:"ends_at"`
}

func recordExpeditionWorkouts(ctx context.Context, tx pgx.Tx, run expeditionRun, input expeditionEvidence, now, cutoff time.Time) ([]string, error) {
	if len(input.workouts) == 0 {
		return nil, nil
	}
	windows := make([]expeditionWorkoutWindow, len(input.workouts))
	for i, w := range input.workouts {
		windows[i] = expeditionWorkoutWindow{w.id, w.start, w.end}
	}
	var seen []uuid.UUID
	var saved [][2]time.Time
	// Fetch only prior intervals overlapping a new workout in this upload.
	err := tx.QueryRow(ctx, `WITH incoming AS MATERIALIZED (
		SELECT * FROM jsonb_to_recordset($2::jsonb) w(id uuid,starts_at timestamptz,ends_at timestamptz)
	), seen AS MATERIALIZED (
		SELECT i.id FROM incoming i JOIN expedition_workouts w ON w.run_id=$1 AND w.workout_id=i.id
	), wanted AS (
		SELECT range_agg(tstzrange(i.starts_at,i.ends_at,'[)')) AS spans FROM incoming i
		WHERE NOT EXISTS(SELECT 1 FROM seen s WHERE s.id=i.id)
	), covered AS (
		SELECT range_agg(prior.span) AS spans FROM expedition_workouts w
		CROSS JOIN LATERAL jsonb_array_elements(w.intervals) entry
		CROSS JOIN LATERAL (SELECT tstzrange((entry->>0)::timestamptz,(entry->>1)::timestamptz,'[)') AS span) prior
		CROSS JOIN wanted
		WHERE w.run_id=$1 AND prior.span && wanted.spans
	) SELECT ARRAY(SELECT id FROM seen),
		COALESCE((SELECT jsonb_agg(jsonb_build_array(lower(r),upper(r)) ORDER BY lower(r))
			FROM unnest((SELECT covered.spans*wanted.spans FROM covered,wanted)) r),'[]'::jsonb)`, run.id, windows).Scan(&seen, &saved)
	if err != nil {
		return nil, err
	}
	covered := make([]workoutInterval, 0, len(saved))
	for _, pair := range saved {
		covered = append(covered, workoutInterval{pair[0], pair[1]})
	}
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
	var qualified []string
	var records []expeditionWorkoutRow
	for _, w := range workouts {
		if slices.Contains(seen, w.id) {
			continue
		}
		row := expeditionWorkoutRow{ID: w.id, Payload: w.payload, Intervals: [][2]time.Time{}}
		row.Outcome, covered = qualifyExpeditionWorkout(w, input.days, run, cutoff, minExpeditionTime(input.observed, now), &row, covered)
		if row.Outcome == "qualified" {
			qualified = append(qualified, w.id.String())
		}
		records = append(records, row)
	}
	if len(records) == 0 {
		return nil, nil
	}
	_, err = tx.Exec(ctx, `INSERT INTO expedition_workouts(run_id,workout_id,payload,intervals,outcome)
		SELECT $1,w.id,w.payload,w.intervals,w.outcome
		FROM jsonb_to_recordset($2::jsonb) w(id uuid,payload jsonb,intervals jsonb,outcome text)`, run.id, records)
	return qualified, err
}

func qualifyExpeditionWorkout(w workoutInput, days []expeditionDayEvidence, run expeditionRun, cutoff, through time.Time,
	row *expeditionWorkoutRow, covered []workoutInterval) (string, []workoutInterval) {
	if w.manual {
		return "manual_excluded", covered
	}
	segments := []workoutSegment{w.workoutSegment}
	if w.hasSegments {
		segments = slices.Clone(w.segments)
	}
	if (w.kind != 37 && w.kind != 52) || len(segments) == 0 || slices.ContainsFunc(segments, func(s workoutSegment) bool { return s.kind != w.kind }) {
		return "unsupported_type", covered
	}
	found := slices.ContainsFunc(days, func(d expeditionDayEvidence) bool { return !w.start.Before(d.Start) && w.start.Before(d.Through) })
	if !found || w.start.Before(cutoff) || !w.end.Before(run.end) || w.end.After(through) {
		return "outside_eligible_interval", covered
	}
	slices.SortStableFunc(segments, func(a, b workoutSegment) int {
		if order := a.start.Compare(b.start); order != 0 {
			return order
		}
		return a.end.Compare(b.end)
	})
	eligible := new(big.Rat)
	var complete int64
	for _, seg := range segments {
		if seg.milliseconds == 0 {
			continue
		}
		complete += seg.milliseconds * 1000
		density := big.NewRat(seg.milliseconds*1000, workoutMicros(seg.start, seg.end))
		for _, part := range freshExpeditionIntervals(workoutInterval{seg.start, seg.end}, covered) {
			eligible.Add(eligible, new(big.Rat).Mul(density, big.NewRat(workoutMicros(part.start, part.end), 1)))
			row.Intervals = append(row.Intervals, [2]time.Time{part.start, part.end})
			covered = addWorkoutCoverage(covered, part)
		}
	}
	ok := false
	if w.kind == 52 {
		ok = eligible.Cmp(big.NewRat(900_000_000, 1)) >= 0
	} else if w.distance != nil && eligible.Sign() > 0 && eligible.Cmp(big.NewRat(complete, 1)) >= 0 {
		distance, valid := new(big.Rat).SetString(*w.distance)
		ok = valid && distance.Cmp(big.NewRat(2000, 1)) >= 0
	}
	if ok {
		return "qualified", covered
	}
	return "below_threshold_or_overlap", covered
}

func freshExpeditionIntervals(interval workoutInterval, covered []workoutInterval) []workoutInterval {
	var result []workoutInterval
	cursor := interval.start
	for _, part := range covered {
		if !part.end.After(cursor) {
			continue
		}
		if !part.start.Before(interval.end) {
			break
		}
		if part.start.After(cursor) {
			result = append(result, workoutInterval{cursor, part.start})
		}
		cursor = maxTime(cursor, part.end)
		if !cursor.Before(interval.end) {
			break
		}
	}
	if cursor.Before(interval.end) {
		result = append(result, workoutInterval{cursor, interval.end})
	}
	return result
}
