package server

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	mathrand "math/rand/v2"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const shopLock int64 = 591417020

type shopItem struct {
	ID        string `json:"id"`
	Rarity    string `json:"rarity"`
	Version   int    `json:"version"`
	Weight    int64  `json:"weight"`
	TokenCost int64  `json:"tokenCost"`
}

type shopSlot struct {
	Name     string    `json:"slot"`
	Item     *shopItem `json:"item"`
	Reason   *string   `json:"reason"`
	Fallback string    `json:"fallback,omitempty"`
}

type shopDay struct {
	Slots    []shopSlot `json:"slots"`
	Adjusted bool       `json:"commonTrioAdjusted"`
}

type shopPlan struct {
	RareDays []int      `json:"rareDays"`
	EpicDays []int      `json:"epicDays"`
	Days     [7]shopDay `json:"days"`
}

func targetWeek(now time.Time, upcoming bool) time.Time {
	now = now.UTC()
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	offset := (int(day.Weekday()) + 6) % 7
	if upcoming && day.Weekday() == time.Sunday {
		return day.AddDate(0, 0, 1)
	}
	return day.AddDate(0, 0, -offset)
}

func planShop(items []shopItem, yesterday map[string]bool, seed [32]byte) (shopPlan, error) {
	rng := mathrand.New(mathrand.NewChaCha8(seed))
	pools := map[string][]shopItem{"common": {}, "rare": {}, "epic": {}}
	unique := map[string]bool{}
	var total int64
	for _, item := range items {
		if unique[item.ID] || item.ID == "" || item.Weight <= 0 || item.Weight > math.MaxInt64-total || item.Version < 1 || item.TokenCost < 4 {
			return shopPlan{}, errors.New("invalid shop catalogue item")
		}
		unique[item.ID] = true
		total += item.Weight
		if pool, ok := pools[item.Rarity]; ok {
			pools[item.Rarity] = append(pool, item)
		}
	}
	for _, pool := range pools {
		slices.SortFunc(pool, func(a, b shopItem) int { return strings.Compare(a.ID, b.ID) })
	}
	draw := func(pool []shopItem) int {
		var weight int64
		for _, item := range pool {
			weight += item.Weight
		}
		roll := rng.Int64N(weight)
		for i, item := range pool {
			if roll < item.Weight {
				return i
			}
			roll -= item.Weight
		}
		panic("empty weighted draw")
	}
	plan := shopPlan{RareDays: rng.Perm(7)[:3], EpicDays: rng.Perm(7)[:2]}
	slices.Sort(plan.RareDays)
	slices.Sort(plan.EpicDays)
	used := map[string]bool{}
	for d := range plan.Days {
		day := &plan.Days[d]
		pool := slices.Clone(pools["common"])
		selected := make([]shopItem, 0, 3)
		for len(pool) > 0 && len(selected) < 3 {
			i := draw(pool)
			selected = append(selected, pool[i])
			pool = slices.Delete(pool, i, i+1)
		}
		same := len(selected) == 3 && len(pool) > 0
		for _, item := range selected {
			same = same && yesterday[item.ID]
		}
		if same {
			selected[rng.IntN(3)] = pool[draw(pool)]
			day.Adjusted = true
		}
		today := map[string]bool{}
		for i := range 3 {
			slot := shopSlot{Name: fmt.Sprintf("common_%d", i+1)}
			if i < len(selected) {
				slot.Item = &selected[i]
				today[slot.Item.ID] = true
			} else {
				reason := "no_eligible_common"
				slot.Reason = &reason
			}
			day.Slots = append(day.Slots, slot)
		}
		for _, featured := range []struct {
			kind string
			days []int
		}{{"rare", plan.RareDays}, {"epic", plan.EpicDays}} {
			if !slices.Contains(featured.days, d) {
				continue
			}
			slot := shopSlot{Name: featured.kind, Fallback: "none"}
			var allowed, unused, notYesterday, preferred []shopItem
			for _, item := range pools[featured.kind] {
				if today[item.ID] {
					continue
				}
				allowed = append(allowed, item)
				if !used[item.ID] {
					unused = append(unused, item)
				}
				if !yesterday[item.ID] {
					notYesterday = append(notYesterday, item)
					if !used[item.ID] {
						preferred = append(preferred, item)
					}
				}
			}
			if len(preferred) == 0 {
				preferred, slot.Fallback = unused, "allow_yesterday"
			}
			if len(preferred) == 0 {
				preferred, slot.Fallback = notYesterday, "allow_week_repeat"
				if len(preferred) == 0 {
					preferred = allowed
				}
			}
			if len(preferred) > 0 {
				slot.Item = &preferred[draw(preferred)]
				used[slot.Item.ID], today[slot.Item.ID] = true, true
			} else {
				reason := "no_eligible_" + featured.kind
				slot.Reason = &reason
			}
			day.Slots = append(day.Slots, slot)
		}
		yesterday = today
	}
	return plan, nil
}

func shopTick(ctx context.Context, tx pgx.Tx) (string, error) {
	return prepareShop(ctx, tx, true)
}

func prepareShop(ctx context.Context, tx pgx.Tx, upcoming bool) (string, error) {
	var now time.Time
	var launch *time.Time
	if err := tx.QueryRow(ctx, `SELECT clock_timestamp(), (SELECT min(effective_week) FROM shop_releases)`).Scan(&now, &launch); err != nil {
		return "", err
	}
	target := targetWeek(now, upcoming)
	if launch == nil || launch.After(target) {
		return "ready", nil
	}
	var exists bool
	if err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM shop_weeks WHERE week_start=$1::date)", target).Scan(&exists); err != nil {
		return "", err
	}
	if exists {
		return "ready", nil
	}

	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", shopLock); err != nil {
		return "", err
	}
	var last *time.Time
	if err := tx.QueryRow(ctx, `SELECT clock_timestamp(), (SELECT max(week_start) FROM shop_weeks),
		(SELECT min(effective_week) FROM shop_releases)`).Scan(&now, &last, &launch); err != nil {
		return "", err
	}
	target = targetWeek(now, upcoming)
	if launch == nil {
		return "ready", nil
	}
	week := *launch
	if last != nil {
		week = last.AddDate(0, 0, 7)
	}
	previous := map[string]bool{}
	if last != nil && !week.After(target) {
		var ids []string
		err := tx.QueryRow(ctx, `SELECT ARRAY(SELECT slot->'item'->>'id'
			FROM jsonb_array_elements(plan->'days'->6->'slots') AS slot
			WHERE slot->'item'->>'id' IS NOT NULL) FROM shop_weeks WHERE week_start=$1::date`, *last).Scan(&ids)
		if err != nil {
			return "", err
		}
		for _, id := range ids {
			previous[id] = true
		}
	}
	for count := 0; count < 8 && !week.After(target); count++ {
		var release string
		var algorithm, limit int
		var items []shopItem
		err := tx.QueryRow(ctx, `SELECT version,(policy->>'algorithm')::int,(policy->>'featuredLimit')::int,catalogue
			FROM shop_releases WHERE effective_week<=$1::date ORDER BY effective_week DESC LIMIT 1`, week).
			Scan(&release, &algorithm, &limit, &items)
		if err != nil {
			return "", err
		}
		if algorithm != 1 || limit < 1 {
			return "", errors.New("unsupported shop policy")
		}
		var seed [32]byte
		// Keep a 64-character opaque seed in the existing database shape.
		if _, err := rand.Read(seed[:]); err != nil {
			return "", err
		}
		plan, err := planShop(items, previous, seed)
		if err != nil {
			return "", err
		}
		if err := saveShopWeek(ctx, tx, week, release, hex.EncodeToString(seed[:]), limit, plan); err != nil {
			return "", err
		}
		previous = map[string]bool{}
		for _, slot := range plan.Days[6].Slots {
			if slot.Item != nil {
				previous[slot.Item.ID] = true
			}
		}
		week = week.AddDate(0, 0, 7)
	}
	if !week.After(target) {
		return "catching_up", nil
	}
	return "ready", nil
}

func saveShopWeek(ctx context.Context, tx pgx.Tx, week time.Time, release, seed string, limit int, plan shopPlan) error {
	var batch pgx.Batch
	batch.Queue("INSERT INTO shop_weeks (week_start,release_version,seed,plan) VALUES ($1,$2,$3,$4::jsonb)", week, release, seed, plan)
	for i, day := range plan.Days {
		start := week.AddDate(0, 0, i)
		end := start.AddDate(0, 0, 1)
		batch.Queue("INSERT INTO shop_days (shop_date,week_start,starts_at,ends_at) VALUES ($1::date,$2,$1::date::timestamp AT TIME ZONE 'UTC',$3)", start, week, end)
		for _, slot := range day.Slots {
			if slot.Item == nil {
				continue
			}
			offer := "garden/" + start.Format(time.DateOnly) + "/" + slot.Name
			var maximum *int
			if !strings.HasPrefix(slot.Name, "common_") {
				maximum = &limit
			}
			batch.Queue("INSERT INTO item_shop_offers (id,version,item_id,item_version,token_cost) VALUES ($1,1,$2,$3,$4)", offer, slot.Item.ID, slot.Item.Version, slot.Item.TokenCost)
			batch.Queue(`INSERT INTO shop_offer_windows (offer_id,offer_version,shop_date,slot,starts_at,ends_at,purchase_limit)
				VALUES ($1,1,$2::date,$3,$2::date::timestamp AT TIME ZONE 'UTC',$4,$5)`, offer, start, slot.Name, end, maximum)
		}
	}
	return tx.SendBatch(ctx, &batch).Close()
}
