package server

import (
	"context"
	"math"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestAccountJSONPreservesLegacyDigest(t *testing.T) {
	raw, err := canonicalJSON([]any{"update_profile", map[string]any{"username": nil, "displayName": "🌲 É <"}})
	if err != nil {
		t.Fatal(err)
	}
	const want = `["update_profile",{"displayName":"\ud83c\udf32 \u00c9 <","username":null}]`
	if string(raw) != want {
		t.Fatalf("canonical form = %s", raw)
	}
}

func TestAccountJSONRejectsAmbiguousRequests(t *testing.T) {
	for _, input := range []string{
		`{"requestId":"first","requestId":"second"}`,
		`{"username":"a"}`, `{"requestId":"a"} {}`, `[]`,
	} {
		request := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(input))
		if _, err := readBody(request, "requestId"); err != invalid {
			t.Fatalf("input %q accepted: %v", input, err)
		}
	}
}

func TestDevelopmentAuthCannotBeUsedInProduction(t *testing.T) {
	const key = "a-local-test-signing-secret-at-least-32-bytes"
	if _, err := DevelopmentVerifier("production", key); err == nil {
		t.Fatal("accepted development mode in production")
	}
	dev, err := DevelopmentVerifier("test", key)
	if err != nil {
		t.Fatal(err)
	}
	token, err := dev.IssueDevelopmentToken("test-account")
	if err != nil {
		t.Fatal(err)
	}
	id, err := dev.Verify(context.Background(), token)
	if err != nil || id.Subject != "test-account" || id.Issuer != DevIssuer {
		t.Fatalf("verify: %v", err)
	}
	if _, err := dev.Verify(context.Background(), "x"+token); err != invalidToken {
		t.Fatal("accepted a tampered token")
	}
}

func TestLevelBoundaries(t *testing.T) {
	for _, tc := range []struct{ steps, level int64 }{{0, 1}, {4999, 1}, {5000, 2}, {12499, 2}, {12500, 3}, {35000, 5}} {
		if got := levelForSteps(tc.steps); got != tc.level {
			t.Errorf("level(%d) = %d, want %d", tc.steps, got, tc.level)
		}
	}
	highest := levelForSteps(math.MaxInt64)
	if xpThreshold(highest) > math.MaxInt64/100 || xpThreshold(highest+1) <= math.MaxInt64/100 {
		t.Fatal("incorrect level at bigint boundary")
	}
}

func TestShopPlanRespectsDailyAndWeeklyRules(t *testing.T) {
	var items []shopItem
	for _, v := range []struct {
		rarity string
		names  string
	}{{"common", "abcd"}, {"rare", "efg"}, {"epic", "hi"}} {
		for _, name := range v.names {
			items = append(items, shopItem{string(name), v.rarity, 1, 1, 4})
		}
	}
	for iteration := range 64 {
		seed := [32]byte{byte(iteration)}
		plan, err := planShop(items, map[string]bool{"a": true, "b": true, "c": true}, seed)
		if err != nil {
			t.Fatal(err)
		}
		if len(plan.RareDays) != 3 || len(plan.EpicDays) != 2 {
			t.Fatal("wrong featured days")
		}
		previous := []string{"a", "b", "c"}
		for i, day := range plan.Days {
			today := map[string]bool{}
			var common []string
			for _, slot := range day.Slots {
				if slot.Item == nil || today[slot.Item.ID] {
					t.Fatal("missing or duplicated item")
				}
				today[slot.Item.ID] = true
				if slot.Item.Rarity == "common" {
					common = append(common, slot.Item.ID)
				}
			}
			slices.Sort(common)
			if len(common) != 3 || slices.Equal(common, previous) {
				t.Fatal("common trio failed cooldown")
			}
			previous = common
			if len(day.Slots) != 3+btoi(slices.Contains(plan.RareDays, i))+btoi(slices.Contains(plan.EpicDays, i)) {
				t.Fatal("featured slots do not match schedule")
			}
		}
	}
}

func btoi(value bool) int {
	if value {
		return 1
	}
	return 0
}

func TestSundayPreparationUsesUTC(t *testing.T) {
	now := time.Date(2026, 11, 29, 17, 0, 0, 0, time.UTC)
	if got := targetWeek(now, true).Format(time.DateOnly); got != "2026-11-30" {
		t.Fatal(got)
	}
	if got := targetWeek(now, false).Format(time.DateOnly); got != "2026-11-23" {
		t.Fatal(got)
	}
}
