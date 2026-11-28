package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
)

type workoutSegment struct {
	kind         int
	start, end   time.Time
	milliseconds int64
}

type workoutInput struct {
	workoutSegment
	id          uuid.UUID
	source      string
	manual      bool
	hasSegments bool
	segments    []workoutSegment
	distance    *string
	payload     map[string]any
}

func parseWorkouts(raws []json.RawMessage) ([]workoutInput, []map[string]any, error) {
	inputs := make([]workoutInput, 0, len(raws))
	payloads := make([]map[string]any, 0, len(raws))
	seen := make(map[uuid.UUID]bool, len(raws))
	totalSegments := 0
	for _, raw := range raws {
		fields, err := readBody(&http.Request{Body: io.NopCloser(bytes.NewReader(raw))},
			"workoutId", "originalType", "start", "end", "durationMilliseconds", "distanceMetres",
			"sourceBundleIdentifier", "wasUserEntered", "hasSegments", "segments")
		if err != nil {
			return nil, nil, err
		}
		id, err := syncUUID(fields, "workoutId")
		if err != nil || seen[id] {
			return nil, nil, invalid
		}
		seen[id] = true
		parent, err := parseWorkoutSegment(fields)
		if err != nil {
			return nil, nil, err
		}
		source, err := stringField(fields, "sourceBundleIdentifier")
		if err != nil || source == "" || utf8.RuneCountInString(source) > 255 {
			return nil, nil, invalid
		}
		item := workoutInput{workoutSegment: parent, id: id, source: source}
		var manual *bool
		if raw := fields["wasUserEntered"]; raw != nil && json.Unmarshal(raw, &manual) != nil {
			return nil, nil, invalid
		}
		item.manual = manual != nil && *manual
		if raw := fields["hasSegments"]; raw != nil &&
			(json.Unmarshal(raw, &item.hasSegments) != nil || string(raw) == "null") {
			return nil, nil, invalid
		}
		var distance *string
		if raw := fields["distanceMetres"]; raw != nil &&
			(json.Unmarshal(raw, &distance) != nil || distance != nil && !quantityDistance.MatchString(*distance)) {
			return nil, nil, invalid
		}
		item.distance = distance
		var segments []json.RawMessage
		if raw := fields["segments"]; raw != nil && (json.Unmarshal(raw, &segments) != nil || segments == nil || len(segments) > 256) {
			return nil, nil, invalid
		}
		totalSegments += len(segments)
		if totalSegments > 2000 || len(segments) > 0 && !item.hasSegments {
			return nil, nil, invalid
		}
		segmentDocs := make([]map[string]any, 0, len(segments))
		var duration int64
		for _, raw := range segments {
			fields, err := readBody(&http.Request{Body: io.NopCloser(bytes.NewReader(raw))}, "originalType", "start", "end", "durationMilliseconds")
			if err != nil {
				return nil, nil, err
			}
			seg, err := parseWorkoutSegment(fields)
			if err != nil || seg.start.Before(parent.start) || seg.end.After(parent.end) {
				return nil, nil, invalid
			}
			duration += seg.milliseconds
			item.segments = append(item.segments, seg)
			segmentDocs = append(segmentDocs, seg.document())
		}
		if duration > parent.milliseconds {
			return nil, nil, invalid
		}
		doc := parent.document()
		doc["workoutId"], doc["sourceBundleIdentifier"] = id, source
		doc["wasUserEntered"], doc["distanceMetres"] = manual, distance
		doc["hasSegments"], doc["segments"] = item.hasSegments, segmentDocs
		item.payload = doc
		inputs = append(inputs, item)
		payloads = append(payloads, doc)
	}
	return inputs, payloads, nil
}

func parseWorkoutSegment(fields map[string]json.RawMessage) (workoutSegment, error) {
	var s workoutSegment
	if json.Unmarshal(fields["originalType"], &s.kind) != nil || string(fields["originalType"]) == "null" || s.kind < 0 || s.kind > 10000 ||
		json.Unmarshal(fields["durationMilliseconds"], &s.milliseconds) != nil || string(fields["durationMilliseconds"]) == "null" ||
		s.milliseconds < 0 || s.milliseconds > 86_400_000 {
		return s, invalid
	}
	start, err := stringField(fields, "start")
	if err != nil {
		return s, err
	}
	end, err := stringField(fields, "end")
	if err != nil {
		return s, err
	}
	if s.start, err = time.Parse(time.RFC3339Nano, start); err != nil {
		return s, invalid
	}
	if s.end, err = time.Parse(time.RFC3339Nano, end); err != nil {
		return s, invalid
	}
	s.start, s.end = s.start.Truncate(time.Microsecond), s.end.Truncate(time.Microsecond)
	if s.start.Year() < 1 || s.end.Year() < 1 || !s.end.After(s.start) || s.milliseconds*1000 > workoutMicros(s.start, s.end) {
		return s, invalid
	}
	return s, nil
}

func (s workoutSegment) document() map[string]any {
	return map[string]any{"originalType": s.kind, "start": normalizedObservation(s.start), "end": normalizedObservation(s.end),
		"durationMilliseconds": s.milliseconds}
}

// Subtract epoch microseconds rather than saturating time.Duration for old imports.
func workoutMicros(start, end time.Time) int64 { return end.UnixMicro() - start.UnixMicro() }
