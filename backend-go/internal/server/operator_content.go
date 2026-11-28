package server

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

type MilestoneEventPublication struct {
	ID          string    `json:"event_id"`
	Name        string    `json:"name"`
	Starts      time.Time `json:"starts_at"`
	Ends        time.Time `json:"ends_at"`
	ClaimUntil  time.Time `json:"claim_until"`
	Attribution string    `json:"attribution"`
}

var milestoneEventID = regexp.MustCompile("^[a-z][a-z0-9_]{0,31}$")

func publishMilestoneEvent(ctx context.Context, tx pgx.Tx, event MilestoneEventPublication, at time.Time) (map[string]any, error) {
	if !milestoneEventID.MatchString(event.ID) || strings.TrimSpace(event.Name) == "" || utf8.RuneCountInString(event.Name) > 100 {
		return nil, errors.New("use a stable event ID and a name of at most 100 characters")
	}
	event.Starts, event.Ends, event.ClaimUntil = event.Starts.Truncate(time.Microsecond),
		event.Ends.Truncate(time.Microsecond), event.ClaimUntil.Truncate(time.Microsecond)
	if event.Starts.IsZero() || !event.Starts.Before(event.Ends) || event.Ends.After(event.ClaimUntil) ||
		event.Ends.Sub(event.Starts) > 90*24*time.Hour {
		return nil, errors.New("events require start < end <= claim deadline and at most 90 earning days")
	}
	if event.Attribution != "collection_time" {
		return nil, errors.New("explicit collection_time attribution is required")
	}
	policy, err := readMilestonePolicy(ctx, tx)
	if err != nil {
		return nil, err
	}
	if !policy.valid || at.Before(policy.effective) {
		return nil, errors.New("activate a valid milestone policy first")
	}
	definition := eventMilestoneDefinition(event.ID, event.Attribution)
	var matches bool
	err = tx.QueryRow(ctx, `SELECT (name,starts_at,ends_at,claim_until,policy_version,definition)
		=($2,$3,$4,$5,$6,$7::jsonb) FROM milestone_events WHERE event_id=$1`,
		event.ID, event.Name, event.Starts, event.Ends, event.ClaimUntil, policy.version, definition).Scan(&matches)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	published := err == nil
	if published && !matches {
		return nil, errors.New("published event instances are immutable; use a new ID")
	}
	if !published {
		var valid bool
		err := tx.QueryRow(ctx, `SELECT $1>=clock_timestamp()
			AND EXISTS(SELECT 1 FROM pack_definitions WHERE id='woodland' AND version=20)`, event.Starts).Scan(&valid)
		if err != nil {
			return nil, err
		}
		if !valid {
			return nil, errors.New("schedule events before they start and publish Woodland pack v20 first")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO milestone_events(event_id,policy_version,name,starts_at,ends_at,claim_until,definition)
			VALUES ($1,$2,$3,$4,$5,$6,$7)`, event.ID, policy.version, event.Name, event.Starts, event.Ends, event.ClaimUntil, definition); err != nil {
			return nil, err
		}
	}
	return map[string]any{"eventId": event.ID, "alreadyPublished": published, "visitorAttribution": event.Attribution,
		"includesPreEventStoredVisits": true}, nil
}

func eventMilestoneDefinition(id, attribution string) map[string]any {
	rules := []struct {
		suffix, metric, title, tokens string
		threshold                     int
	}{
		{"growth", "growth", "Earn growth on a planted sprout", "300", 1},
		{"butterflies", "butterflies", "Welcome or collect 50 butterflies", "300", 50},
		{"days_3", "activity_days", "Complete 3 activity days", "600", 3},
		{"days_5", "activity_days", "Complete 5 activity days", "0", 5},
	}
	quests := make([]map[string]any, 0, len(rules))
	for order, rule := range rules {
		packs := []map[string]any{}
		if rule.suffix == "days_5" {
			packs = append(packs, map[string]any{"packId": "woodland", "version": 20, "quantity": 1, "displayName": "Standard Woodland"})
		}
		quests = append(quests, map[string]any{"milestoneId": "event_" + id + "_" + rule.suffix,
			"track": "event", "category": nil, "metric": rule.metric, "title": rule.title, "threshold": rule.threshold,
			"rewardTokens": rule.tokens, "rewardGems": "0", "rewardPacks": packs, "order": order, "scope": "event", "eventId": id})
	}
	return map[string]any{"quests": quests, "visitorAttribution": attribution}
}

func retireExchangeOffer(ctx context.Context, tx pgx.Tx, offer string, version int) (map[string]any, error) {
	if !packIdentifier.MatchString(offer) || version < 1 || version > 2_147_483_647 {
		return nil, errors.New("specify a valid offer identifier and version")
	}
	var active bool
	err := tx.QueryRow(ctx, "SELECT active FROM exchange_offers WHERE id=$1 AND version=$2 FOR UPDATE", offer, version).Scan(&active)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errors.New("offer version not found")
	}
	if err != nil {
		return nil, err
	}
	if active {
		if _, err := tx.Exec(ctx, "UPDATE exchange_offers SET active=false WHERE id=$1 AND version=$2", offer, version); err != nil {
			return nil, err
		}
	}
	return map[string]any{"offerId": offer, "offerVersion": version, "alreadyRetired": !active}, nil
}
