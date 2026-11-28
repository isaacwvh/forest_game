package server

import (
	"context"
	"errors"
	"math"
	"math/big"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type visitorState struct {
	garden, context      string
	at                   time.Time
	whole, slot, version int64
	gap                  int
	issued               bool
	remainder            *big.Rat
}

type visitorSession struct {
	ID           string    `json:"sessionId"`
	Installation string    `json:"installationId"`
	Expires      time.Time `json:"leaseExpiresAt"`
	protocol     int
}

type visitorRuntime struct {
	state     visitorState
	config    visitorContext
	active    *visitorSession
	at        time.Time
	legacyDue bool
}

func (s *Server) visitor(r *http.Request, tx pgx.Tx, id Identity) (any, error) {
	ctx := r.Context()
	owner, err := lookupProfile(ctx, tx, id, true)
	if err != nil {
		return nil, err
	}
	if _, err := s.catalogueState(ctx, tx); err != nil {
		return nil, err
	}
	runtime, err := s.settleVisitors(ctx, tx, owner, false)
	if err != nil {
		return nil, err
	}
	if err := runtime.persist(ctx, tx); err != nil {
		return nil, err
	}
	return s.visitorSummary(ctx, tx, owner.ID, runtime)
}

func (s *Server) settleVisitors(ctx context.Context, tx pgx.Tx, owner Profile, heartbeat bool) (*visitorRuntime, error) {
	at, err := s.gardenNow(ctx, tx)
	if err != nil {
		return nil, err
	}
	g := gardenRecord{owner: owner.ID}
	var dueVersion *int64
	// Return the state version only when a placed harp may have reached a new local date.
	err = tx.QueryRow(ctx, `SELECT g.id::text, CASE WHEN NOT EXISTS (
		SELECT 1 FROM daily_item_state d WHERE d.garden_id=g.id
		AND (d.settled_at AT TIME ZONE $3::text)::date>=($2::timestamptz AT TIME ZONE $3::text)::date
	) AND `+placedDailyWater+` THEN g.state_version END
	FROM gardens g WHERE g.owner_id=$1 FOR UPDATE`, owner.ID, at, owner.Timezone).Scan(&g.id, &dueVersion)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, &apiError{503, "garden_unavailable", "Account garden is unavailable"}
	}
	if err != nil {
		return nil, err
	}
	if err := throttle(ctx, tx, owner.ID, at); err != nil {
		return nil, err
	}
	if dueVersion != nil {
		g.state, g.dailySource = *dueVersion, true
		if err := s.settleGardenDaily(ctx, tx, &g, at, owner.Timezone); err != nil {
			return nil, err
		}
	}
	return s.settleVisitorState(ctx, tx, g.id, g.owner, at, heartbeat)
}

func (s *Server) settleVisitorState(ctx context.Context, tx pgx.Tx, garden, owner string, at time.Time, heartbeat bool) (*visitorRuntime, error) {
	runtime := visitorRuntime{state: visitorState{garden: garden}, at: at}
	state := &runtime.state
	var remainder visitorFraction
	err := tx.QueryRow(ctx, `SELECT context_id::text,settled_at,stored_whole,remainder,last_slot,gap_slots,version,ever_issued
	FROM garden_visitor_state WHERE garden_id=$1`, state.garden).
		Scan(&state.context, &state.at, &state.whole, &remainder, &state.slot, &state.gap, &state.version, &state.issued)
	if errors.Is(err, pgx.ErrNoRows) {
		if state.context, err = s.createGardenContext(ctx, tx, state.garden, owner, runtime.at); err != nil {
			return nil, err
		}
		state.at = runtime.at
		state.slot = runtime.at.Unix() / 30
		_, err = tx.Exec(ctx, `INSERT INTO garden_visitor_state
			(garden_id,settled_at,context_id,stored_whole,remainder,last_slot,gap_slots,version)
			VALUES ($1,$2,$3,0,'{}',$4,0,0)`, state.garden, state.at, state.context, state.slot)
	}
	if err != nil {
		return nil, err
	}
	state.remainder, err = remainder.rat()
	if err != nil {
		return nil, err
	}
	runtime.at = maxTime(runtime.at, state.at).UTC()
	runtime.config, err = s.cachedVisitorContext(ctx, tx, state.context)
	if err != nil {
		return nil, err
	}
	var policyChanges []time.Time
	err = tx.QueryRow(ctx, `SELECT array_agg(effective_at ORDER BY effective_at) FROM visitor_rules
		WHERE effective_at>$1 AND effective_at<=$2`, state.at, runtime.at).Scan(&policyChanges)
	if err != nil {
		return nil, err
	}
	if err := expireVisitorOpportunities(ctx, tx, state.garden, runtime.at, false); err != nil {
		return nil, err
	}
	active := new(visitorSession)
	err = tx.QueryRow(ctx, `SELECT id::text,installation_id::text,lease_expires_at,arrival_protocol
		FROM visitor_sessions WHERE garden_id=$1 AND ended_at IS NULL`, state.garden).
		Scan(&active.ID, &active.Installation, &active.Expires, &active.protocol)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if err == nil {
		runtime.active = active
		runtime.legacyDue = heartbeat && runtime.at.Before(active.Expires) && runtime.at.Unix()/30 > state.slot
	}
	// Settle the old context up to each publication or daily skill boundary.
	// Opportunities already visible at the boundary keep their original context.
	for {
		var change time.Time
		if len(policyChanges) > 0 {
			change = policyChanges[0]
		}
		if expires := runtime.config.expiry; expires != nil && !expires.After(runtime.at) &&
			(change.IsZero() || expires.Before(change)) {
			change = *expires
		}
		if change.IsZero() {
			break
		}
		for len(policyChanges) > 0 && !policyChanges[0].After(change) {
			policyChanges = policyChanges[1:]
		}
		boundary := maxTime(state.at, change)
		if err := runtime.settleTo(ctx, tx, boundary); err != nil {
			return nil, err
		}
		if err := pauseSchedule(ctx, tx, garden, boundary); err != nil {
			return nil, err
		}
		id, err := s.createGardenContext(ctx, tx, garden, owner, boundary)
		if err != nil {
			return nil, err
		}
		runtime.config, err = s.cachedVisitorContext(ctx, tx, id)
		if err != nil {
			return nil, err
		}
		state.context = id
		if runtime.config.expiry != nil && !runtime.config.expiry.After(boundary) {
			return nil, visitorContextUnavailable
		}
	}
	if err := runtime.settleTo(ctx, tx, runtime.at); err != nil {
		return nil, err
	}
	return &runtime, nil
}

func (v *visitorRuntime) settleTo(ctx context.Context, tx pgx.Tx, boundary time.Time) error {
	state := &v.state
	if v.active != nil {
		expiry := v.active.Expires
		end := boundary
		if expiry.Before(end) {
			end = expiry
		}
		if state.at.Before(end) {
			if err := v.settleInterval(ctx, tx, end, true); err != nil {
				return err
			}
		}
		if !boundary.Before(expiry) {
			if err := v.close(ctx, tx, expiry); err != nil {
				return err
			}
		}
	}
	if state.at.Before(boundary) {
		return v.settleInterval(ctx, tx, boundary, false)
	}
	return nil
}

func maxTime(a, b time.Time) time.Time {
	if a.After(b) {
		return a
	}
	return b
}

func (v *visitorRuntime) persist(ctx context.Context, tx pgx.Tx) error {
	state := &v.state
	_, err := tx.Exec(ctx, `UPDATE garden_visitor_state SET settled_at=$2,stored_whole=$3,remainder=$4::jsonb,
	last_slot=$5,gap_slots=$6,version=$7,ever_issued=$8,context_id=$9 WHERE garden_id=$1`, state.garden, state.at, state.whole,
		visitorAmount(state.remainder), state.slot, state.gap, state.version, state.issued, state.context)
	return err
}

func (v *visitorRuntime) settleInterval(ctx context.Context, tx pgx.Tx, end time.Time, active bool) error {
	state := &v.state
	mode := "active"
	var detail any
	if active {
		if v.config.protocol == 2 {
			detail = map[string]bool{"scheduledArrivals": true}
		} else {
			last := end.Unix() / 30
			if end.Nanosecond() == 0 && end.Unix()%30 == 0 {
				last--
			}
			detail = map[string]any{"firstSlot": max(state.slot+1, state.at.Unix()/30+1), "lastSlot": last, "issued": nil}
			state.slot = max(state.slot, last)
		}
	} else {
		mode = "inactive"
		before := new(big.Rat).Add(big.NewRat(state.whole, 1), state.remainder)
		generated := new(big.Rat).Mul(visitorDuration(state.at, end), v.config.offline)
		after := new(big.Rat).Set(before)
		capacity := big.NewRat(v.config.capacity, 1)
		if before.Cmp(capacity) < 0 {
			after.Add(after, generated)
			if after.Cmp(capacity) > 0 {
				after.Set(capacity)
			}
		}
		whole := new(big.Int).Quo(after.Num(), after.Denom()).Int64()
		if earned := whole - state.whole; earned > 0 {
			_, err := tx.Exec(ctx, `INSERT INTO visitor_storage_lots (garden_id,rule_version,visits,tokens_per_visit)
				VALUES ($1,$2,$3,$4) ON CONFLICT (garden_id,rule_version)
				DO UPDATE SET visits=visitor_storage_lots.visits+excluded.visits`,
				state.garden, v.config.rule, earned, v.config.tokens)
			if err != nil {
				return err
			}
		}
		discarded := new(big.Rat).Sub(generated, new(big.Rat).Sub(after, before))
		detail = map[string]visitorFraction{"before": visitorAmount(before), "after": visitorAmount(after),
			"generated": visitorAmount(generated), "discarded": visitorAmount(discarded)}
		state.whole = whole
		state.remainder = new(big.Rat).Sub(after, big.NewRat(whole, 1))
	}
	if state.version == math.MaxInt64 {
		return visitorContextUnavailable
	}
	_, err := tx.Exec(ctx, `INSERT INTO visitor_settlements (id,garden_id,context_id,start_at,end_at,mode,detail)
		VALUES ($1,$2,$3,$4,$5,$6,$7::jsonb)`, uuid.New(), state.garden, state.context, state.at, end, mode, detail)
	if err == nil {
		state.at = end
		state.version++
	}
	return err
}

func visitorDuration(start, end time.Time) *big.Rat {
	seconds := new(big.Rat).SetInt64(end.Unix() - start.Unix())
	return seconds.Add(seconds, big.NewRat(int64(end.Nanosecond()-start.Nanosecond()), 1_000_000_000))
}

func (v *visitorRuntime) close(ctx context.Context, tx pgx.Tx, at time.Time) error {
	if v.active == nil {
		return nil
	}
	if v.active.protocol == 2 {
		if err := pauseSchedule(ctx, tx, v.state.garden, at); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, "UPDATE visitor_sessions SET ended_at=$2 WHERE id=$1", v.active.ID, at); err != nil {
		return err
	}
	v.active = nil
	return expireVisitorOpportunities(ctx, tx, v.state.garden, at, true)
}

func (s *Server) visitorSummary(ctx context.Context, tx pgx.Tx, owner string, v *visitorRuntime) (map[string]any, error) {
	var sequence, economy, tokens, active, offline int64
	err := tx.QueryRow(ctx, `
SELECT COALESCE((SELECT sequence FROM visitor_controls WHERE owner_id=$1),0),
	w.economy_version,w.tokens,w.hosted_active,w.hosted_offline
FROM visitor_wallets w WHERE w.owner_id=$1`, owner).Scan(&sequence, &economy, &tokens, &active, &offline)
	if err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, `SELECT id,session_id,slot,issued_at,expires_at,tokens
		FROM visitor_opportunities WHERE garden_id=$1 AND status='issued' AND expires_at>$2
		ORDER BY issued_at,id`, v.state.garden, v.at)
	if err != nil {
		return nil, err
	}
	opportunities, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (map[string]any, error) {
		var id, session uuid.UUID
		var slot, amount int64
		var issued, expires time.Time
		if err := row.Scan(&id, &session, &slot, &issued, &expires, &amount); err != nil {
			return nil, err
		}
		lane := int64(0)
		if slot < 0 {
			lane = (-slot-1)%12 + 1
		}
		return map[string]any{"opportunityId": id, "sessionId": session, "lane": lane, "issuedAt": issued.UTC(),
			"expiresAt": expires.UTC(), "visualKey": "forest-butterfly-v1", "tokens": numberString(amount)}, nil
	})
	if err != nil {
		return nil, err
	}
	if opportunities == nil {
		opportunities = []map[string]any{}
	}
	sources, err := s.contextSources(ctx, tx, v.state.context)
	if err != nil {
		return nil, err
	}
	stored := new(big.Rat).Add(big.NewRat(v.state.whole, 1), v.state.remainder)
	micro := new(big.Rat).Mul(stored, big.NewRat(1_000_000, 1))
	microUnits := new(big.Int).Quo(micro.Num(), micro.Denom()).String()
	var untilFull *int64
	capacity := big.NewRat(v.config.capacity, 1)
	switch {
	case capacity.Cmp(stored) <= 0:
		zero := int64(0)
		untilFull = &zero
	case v.active == nil && v.config.offline.Sign() > 0:
		wait := new(big.Rat).Quo(new(big.Rat).Sub(capacity, stored), v.config.offline)
		if seconds := ceilRat(wait); seconds.IsInt64() {
			value := seconds.Int64()
			untilFull = &value
		}
	}
	return map[string]any{
		"controlProtocol": 1, "controlSequence": sequence, "arrivalProtocol": v.config.protocol,
		"gardenId": v.state.garden, "serverTime": v.at, "version": v.state.version,
		"contextId": v.config.id, "ruleVersion": v.config.rule, "isFixture": v.config.fixture,
		"totalAttractionMicroUnits": v.config.attraction, "sources": sources,
		"storedVisitsMicroUnits": microUnits, "claimableVisits": numberString(v.state.whole),
		"capacity": v.config.capacity, "activeVisitsPerHour": hourly(v.config.active),
		"offlineVisitsPerHour": hourly(v.config.offline), "secondsUntilFull": untilFull,
		"tokenBalance": numberString(tokens), "economyVersion": economy, "hostedActive": numberString(active),
		"hostedOffline": numberString(offline), "hostedTotal": new(big.Int).Add(big.NewInt(active), big.NewInt(offline)).String(),
		"heartbeatSeconds": v.config.heartbeat, "session": v.active, "opportunities": opportunities,
	}, nil
}

func hourly(rate *big.Rat) string {
	number, _ := new(big.Rat).Mul(rate, big.NewRat(3600, 1)).Float64()
	return strconv.FormatFloat(number, 'g', -1, 64)
}

func ceilRat(value *big.Rat) *big.Int {
	n := new(big.Int).Add(value.Num(), new(big.Int).Sub(value.Denom(), big.NewInt(1)))
	return n.Quo(n, value.Denom())
}

func throttle(ctx context.Context, tx pgx.Tx, owner string, boundary time.Time) error {
	var requests int
	err := tx.QueryRow(ctx, `INSERT INTO visitor_throttles (owner_id,window_at,requests) VALUES ($1,$2,1)
	ON CONFLICT (owner_id) DO UPDATE SET
		window_at=CASE WHEN excluded.window_at >= visitor_throttles.window_at+interval '1 minute'
			THEN excluded.window_at ELSE visitor_throttles.window_at END,
		requests=CASE WHEN excluded.window_at >= visitor_throttles.window_at+interval '1 minute'
			THEN 1 ELSE visitor_throttles.requests+1 END RETURNING requests`, owner, boundary).Scan(&requests)
	if err != nil {
		return err
	}
	if requests > 90 {
		return &apiError{429, "visitor_rate_limited", "Wait a minute before trying visitors again"}
	}

	return nil
}
