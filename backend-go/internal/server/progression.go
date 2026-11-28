package server

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/jackc/pgx/v5"
)

type progression struct {
	Rules     string     `json:"rulesVersion"`
	Version   int64      `json:"version"`
	Steps     string     `json:"lifetimeRecordedSteps"`
	XP        string     `json:"stepXp"`
	TotalXP   string     `json:"totalXp"`
	Level     int64      `json:"level"`
	IntoLevel string     `json:"xpIntoLevel"`
	NextLevel string     `json:"xpForNextLevel"`
	IntoGem   int64      `json:"stepsIntoNextGem"`
	PerGem    int64      `json:"stepsPerGem"`
	ToGem     int64      `json:"stepsToNextGem"`
	Matured   string     `json:"plantsGrownToAdulthood"`
	SyncAt    *time.Time `json:"lastSyncAt"`
}

func xpThreshold(level int64) int64 { return ((level - 1) * (level + 2) / 2) * 25 }

func levelForSteps(steps int64) int64 {
	// One hundred million is above the greatest level attainable from a signed bigint
	// steps balance. Keep the predicate below the largest product safe in int64.
	low, high := int64(1), int64(100_000_000)
	for high-low > 1 {
		middle := (low + high) / 2
		if xpThreshold(middle) <= steps/100 {
			low = middle
		} else {
			high = middle
		}
	}
	return low
}

func progressionFor(steps, matured, version int64, syncAt *time.Time) progression {
	level, xp := levelForSteps(steps), steps/100
	remainder := steps % 10_000
	return progression{"step-progression-v1", version, numberString(steps), numberString(xp), numberString(xp),
		level, numberString(xp - xpThreshold(level)), numberString(50 + 25*(level-1)),
		remainder, 10_000, 10_000 - remainder, numberString(matured), syncAt}
}

type economyFacts struct {
	steps, matured, version int64
	lastSync                *time.Time
	metrics                 json.RawMessage
	wallet                  json.RawMessage
}

func readEconomy(ctx context.Context, tx pgx.Tx, owner string) (economyFacts, error) {
	var f economyFacts
	err := tx.QueryRow(ctx, `
	SELECT COALESCE(p.activity_steps,0),COALESCE(p.first_maturity_count,0),
		COALESCE(p.progression_version,0),p.last_sync_at,COALESCE(p.activity_metrics,'{}'),
		jsonb_build_object('economyVersion',COALESCE(w.economy_version,0),
		'tokenBalance',COALESCE(w.tokens,0)::text,'gemBalance',COALESCE(w.gems,0)::text,
		'lifetimeGemsEarned',COALESCE(w.lifetime_gems_earned,0)::text,'stepGemsEarned',COALESCE(w.step_gems_earned,0)::text,
		'bonusGemsEarned',COALESCE(w.lifetime_gems_earned-w.step_gems_earned,0)::text,
		'initialized',COALESCE(w.progression_initialized,false),
		'hostedActive',COALESCE(w.hosted_active,0)::text,'hostedOffline',COALESCE(w.hosted_offline,0)::text,
		'hostedTotal',(COALESCE(w.hosted_active,0)::numeric+COALESCE(w.hosted_offline,0))::text)
	FROM (VALUES ($1::uuid)) AS owner(id)
	LEFT JOIN player_progress p ON p.owner_id=owner.id
	LEFT JOIN visitor_wallets w ON w.owner_id=owner.id`, owner).
		Scan(&f.steps, &f.matured, &f.version, &f.lastSync, &f.metrics, &f.wallet)
	return f, err
}

func (s *Server) activityStatus(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	ctx := r.Context()
	p, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	f, err := readEconomy(ctx, tx, p.ID)
	if err != nil {
		return nil, err
	}
	var now time.Time
	var device json.RawMessage
	err = tx.QueryRow(ctx, `SELECT clock_timestamp(), (
		SELECT jsonb_build_object('deviceId',id,'installationId',installation_id,'enrolledAt',enrolled_at,
			'baselineDate',baseline_date,'baselineObservedAt',baseline_observed_at,
			'baselineSteps',baseline_steps,'ready',baseline_date IS NOT NULL,'metricBaselines',metric_baselines)
		FROM activity_devices WHERE owner_id=$1 AND revoked_at IS NULL)`, p.ID).Scan(&now, &device)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"serverTime": now.UTC(), "gameTimezone": p.Timezone,
		"supportedMetrics": []string{"steps", "walking_running_distance_km", "active_energy_kcal", "flights_climbed",
			"workout_minutes.cycling", "workout_minutes.hiking", "workout_minutes.running",
			"workout_minutes.strength_training", "workout_minutes.swimming", "workout_minutes.walking", "workout_minutes.yoga"},
		"reconciliationDays": 7, "queuedUploadMaxAgeDays": 30, "device": device, "activitySteps": numberString(f.steps),
		"firstMaturityCount": f.matured, "lastSyncAt": f.lastSync, "activityMetrics": f.metrics,
		"progression": progressionFor(f.steps, f.matured, f.version, f.lastSync), "wallet": f.wallet,
	}, nil
}
