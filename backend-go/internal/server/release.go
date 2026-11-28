package server

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed release/woodland.json
var releaseContent []byte

const (
	woodlandRelease    = "woodland-v1"
	developmentRelease = "development-woodland-v2"
)

type ReleaseOptions struct {
	Command  string
	Apply    bool
	Month    time.Time
	StartNow bool
	Week     time.Time
	Subject  string
}

type releaseBundle map[string]map[string][]map[string]any

type releaseTable struct {
	name   string
	key    string
	update string // Only these columns may move forward from development fixtures.
}

// The order matches the foreign key dependencies of the published definitions.
var releaseTables = map[string][]releaseTable{
	"woodland": {
		{name: "skill_policies", key: "version"},
		{name: "economy_configs", key: "version"},
		{name: "visitor_rules", key: "version"},
		{name: "growth_profiles", key: "id version"},
		{name: "growth_rule_profiles", key: "id version"},
		{name: "attraction_profiles", key: "id version"},
		{name: "plant_species", key: "id", update: "display_name rarity description clearance_radius enabled is_fixture properties growth_profile_id growth_profile_version behaviour_profile_id behaviour_profile_version attraction_profile_id attraction_profile_version"},
		{name: "plant_variants", key: "species_id variant_id", update: "display_name description rarity enabled asset_catalog_key asset_catalog_version growth_profile_id growth_profile_version behaviour_profile_id behaviour_profile_version attraction_profile_id attraction_profile_version"},
		{name: "plant_stages", key: "species_id variant_id stage"},
		{name: "game_catalogue", key: "id", update: "version is_fixture"},
		{name: "pack_definitions", key: "id version"},
		{name: "pack_members", key: "pack_id pack_version species_id variant_id"},
		{name: "exchange_offers", key: "id version"},
	},
	"items": {
		{name: "item_definitions", key: "id version"},
		{name: "item_value_definitions", key: "item_id item_version"},
		{name: "item_skill_profiles", key: "id version"},
		{name: "item_skill_bindings", key: "item_id item_version"},
		{name: "item_shop_offers", key: "id version"},
		{name: "shop_releases", key: "version"},
	},
	"milestones": {{name: "milestone_policies", key: "version"}},
	"expedition": {
		{name: "item_definitions", key: "id version"},
		{name: "item_value_definitions", key: "item_id item_version"},
		{name: "expedition_templates", key: "version"},
	},
}

// RunLocalRelease exercises the same writes and constraints for preview and
// apply. Its inputs are pinned release fixtures for local databases only.
func RunLocalRelease(ctx context.Context, pool *pgxpool.Pool, options ReleaseOptions) (map[string]any, error) {
	var bundle releaseBundle
	decoder := json.NewDecoder(bytes.NewReader(releaseContent))
	decoder.UseNumber()
	if err := decoder.Decode(&bundle); err != nil {
		return nil, fmt.Errorf("read embedded release: %w", err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(context.WithoutCancel(ctx))
	if options.Command == "preview-shop" {
		var plan json.RawMessage
		err := tx.QueryRow(ctx, "SELECT plan FROM public.shop_weeks WHERE week_start=$1::date", options.Week).Scan(&plan)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, errors.New("prepare the requested Shop week before previewing it")
		}
		return map[string]any{"week": options.Week.Format(time.DateOnly), "plan": plan}, err
	}
	// Drain local gameplay first. Publication can update the catalogue and set a
	// visitor-rule boundary while preserving the existing gardens and receipts.
	if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", maintenanceLock); err != nil {
		return nil, err
	}
	var now time.Time
	if err := tx.QueryRow(ctx, "SELECT clock_timestamp()").Scan(&now); err != nil {
		return nil, err
	}
	now = now.UTC()
	report := map[string]any{"applied": options.Apply}
	if err := publishRelease(ctx, tx, bundle, options, now, report); err != nil {
		return nil, err
	}
	if options.Apply {
		if err := tx.Commit(ctx); err != nil {
			return nil, err
		}
	}
	return report, nil
}

func publishRelease(ctx context.Context, tx pgx.Tx, bundle releaseBundle, options ReleaseOptions, now time.Time, report map[string]any) error {
	var groups []string
	switch options.Command {
	case "publish-release":
		groups = []string{"woodland", "items", "milestones", "expedition"}
		options.Month, options.StartNow = expeditionMonth(now), true
	case "publish-woodland":
		groups = []string{"woodland"}
	case "publish-item-catalogue":
		groups = []string{"items"}
	case "activate-milestones":
		groups = []string{"milestones"}
	case "publish-expedition":
		groups = []string{"expedition"}
	case "prepare-shop":
	case "fund-release-test":
		return fundReleaseAccount(ctx, tx, options.Subject, report)
	default:
		return errors.New("unknown release command")
	}
	for _, group := range groups {
		updated, err := publishReleaseGroup(ctx, tx, bundle[group], group, now)
		if err != nil {
			return fmt.Errorf("publish %s: %w", group, err)
		}
		report[group] = updated
		if group == "expedition" {
			if err := assignReleaseExpedition(ctx, tx, bundle[group], options, now, report); err != nil {
				return err
			}
		}
	}
	if options.Command == "publish-release" || options.Command == "prepare-shop" {
		var release bool
		if err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM public.shop_releases)").Scan(&release); err != nil {
			return err
		}
		if !release {
			return errors.New("publish the item catalogue before preparing Shop weeks")
		}
		status, err := prepareShop(ctx, tx, true)
		if err != nil {
			return fmt.Errorf("prepare Shop: %w", err)
		}
		report["shop"] = status
	}
	return nil
}

func publishReleaseGroup(ctx context.Context, tx pgx.Tx, tables map[string][]map[string]any, group string, now time.Time) (map[string]int64, error) {
	var catalogue string
	if err := tx.QueryRow(ctx, "SELECT COALESCE((SELECT version FROM public.game_catalogue WHERE id=1),'')").Scan(&catalogue); err != nil {
		return nil, err
	}
	if catalogue != woodlandRelease && (group != "woodland" || catalogue != "" && catalogue != developmentRelease) {
		return nil, errors.New("start with the local Woodland publication on an empty database or the Go development fixture")
	}
	upgrading := group == "woodland" && catalogue != woodlandRelease
	if upgrading {
		// Retire development offers before publishing replacements. Older packs and
		// their odds remain accessible through ownership and opening history.
		if _, err := tx.Exec(ctx, `UPDATE public.exchange_offers SET active=false WHERE active AND version<20`); err != nil {
			return nil, err
		}
	}
	if group == "milestones" {
		var ready bool
		err := tx.QueryRow(ctx, `SELECT NOT EXISTS (SELECT 1 FROM public.users u LEFT JOIN public.visitor_wallets w
			ON w.owner_id=u.id WHERE w.progression_initialized IS DISTINCT FROM true)
			AND (SELECT count(*) FROM public.pack_definitions WHERE version=20 AND NOT is_fixture
			AND id IN ('woodland','select-woodland','premium-woodland'))=3`).Scan(&ready)
		if err != nil {
			return nil, err
		}
		if !ready {
			return nil, errors.New("milestones need published reward packs and initialized progression")
		}
	}
	counts := make(map[string]int64, len(tables))
	for _, table := range releaseTables[group] {
		rows := tables[table.name]
		if len(rows) == 0 {
			return nil, fmt.Errorf("release has no %s rows", table.name)
		}
		volatile := dateReleaseRows(table.name, rows, now)
		count, err := publishReleaseRows(ctx, tx, table, rows, volatile, upgrading)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", table.name, err)
		}
		counts[table.name] = count
	}
	if upgrading {
		// Bump snapshot state so a client reconnecting from the fixture refreshes
		// its catalogue. Existing visitor contexts settle across the new boundary
		// when gameplay resumes, using the rule times inserted above.
		if _, err := tx.Exec(ctx, `INSERT INTO public.runtime_control (id) VALUES (1) ON CONFLICT DO NOTHING;
			UPDATE public.gardens SET state_version=state_version+1`); err != nil {
			return nil, err
		}
	}
	return counts, nil
}

func dateReleaseRows(table string, rows []map[string]any, now time.Time) []string {
	switch table {
	case "economy_configs", "visitor_rules":
		for i, row := range rows {
			row["effective_at"] = now.Add(time.Duration(i+1) * time.Microsecond)
		}
		return []string{"effective_at"}
	case "milestone_policies":
		rows[0]["effective_at"] = now
		return []string{"effective_at"}
	case "expedition_templates":
		rows[0]["published_at"] = now
		return []string{"published_at"}
	case "shop_releases":
		rows[0]["published_at"], rows[0]["effective_week"] = now, targetWeek(now, false).Format(time.DateOnly)
		return []string{"published_at", "effective_week"}
	default:
		return []string{}
	}
}

func publishReleaseRows(ctx context.Context, tx pgx.Tx, table releaseTable, rows []map[string]any, volatile []string, upgrading bool) (int64, error) {
	data, err := json.Marshal(rows)
	if err != nil {
		return 0, err
	}
	qualified := "public." + table.name
	keys := strings.Join(strings.Fields(table.key), ", ")
	input := "WITH expected AS (SELECT * FROM jsonb_populate_recordset(NULL::" + qualified + ", $1::jsonb)) "
	var changed int64
	if upgrading && table.update != "" {
		var assignments []string
		for _, column := range strings.Fields(table.update) {
			assignments = append(assignments, column+"=expected."+column)
		}
		tag, err := tx.Exec(ctx, input+"UPDATE "+qualified+" AS target SET "+strings.Join(assignments, ", ")+
			" FROM expected WHERE "+releaseKeyMatch(table.key)+" AND target IS DISTINCT FROM expected", data)
		if err != nil {
			return 0, err
		}
		changed += tag.RowsAffected()
	}
	// Filter existing rows before INSERT, since immutable-table triggers can run
	// even for rows which would subsequently hit ON CONFLICT.
	tag, err := tx.Exec(ctx, input+"INSERT INTO "+qualified+" SELECT expected.* FROM expected WHERE NOT EXISTS (SELECT 1 FROM "+
		qualified+" AS target WHERE "+releaseKeyMatch(table.key)+") ORDER BY "+keys, data)
	if err != nil {
		return 0, err
	}
	var matches bool
	err = tx.QueryRow(ctx, input+"SELECT NOT EXISTS (SELECT 1 FROM expected LEFT JOIN "+qualified+" AS target USING ("+keys+
		") WHERE (to_jsonb(expected)-$2::text[]) IS DISTINCT FROM (to_jsonb(target)-$2::text[]))", data, volatile).Scan(&matches)
	if err != nil {
		return 0, err
	}
	if !matches {
		return 0, errors.New("existing definition differs from the pinned release")
	}
	return changed + tag.RowsAffected(), nil
}

func releaseKeyMatch(key string) string {
	var comparisons []string
	for _, column := range strings.Fields(key) {
		comparisons = append(comparisons, "target."+column+"=expected."+column)
	}
	return strings.Join(comparisons, " AND ")
}

func assignReleaseExpedition(ctx context.Context, tx pgx.Tx, tables map[string][]map[string]any, options ReleaseOptions, now time.Time, report map[string]any) error {
	month, current := options.Month, expeditionMonth(now)
	if month.IsZero() || !month.Equal(expeditionMonth(month)) {
		return errors.New("expedition month must be the first day of a UTC month")
	}
	version := tables["expedition_templates"][0]["version"]
	var existing *string
	var starts *time.Time
	err := tx.QueryRow(ctx, `SELECT (SELECT template_version FROM public.expedition_schedule WHERE month=$1::date),
		(SELECT starts_at FROM public.expedition_launches WHERE month=$1::date)`, month).Scan(&existing, &starts)
	if err != nil {
		return err
	}
	if existing != nil && *existing != version {
		return errors.New("expedition month already has a different pinned template")
	}
	if existing == nil {
		if options.StartNow {
			var prior bool
			err := tx.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM public.expedition_schedule WHERE month<$1::date)", month).Scan(&prior)
			if err != nil {
				return err
			}
			if prior && options.Command == "publish-release" {
				// An existing schedule recurs into the current and subsequent months.
				return nil
			}
			if !month.Equal(current) || prior {
				return errors.New("start-now requires the first scheduled expedition in the current UTC month")
			}
		} else if !month.After(now) {
			return errors.New("schedule a future UTC month or use --start-now for the first partial month")
		}
		if _, err := tx.Exec(ctx, `INSERT INTO public.expedition_schedule (month,template_version,published_at)
			VALUES ($1::date,$2,$3)`, month, version, now); err != nil {
			return err
		}
		if options.StartNow {
			launch := now.Add(time.Millisecond - time.Nanosecond).Truncate(time.Millisecond)
			if !launch.Before(month.AddDate(0, 1, 0)) {
				return errors.New("the UTC month ended during publication")
			}
			if _, err := tx.Exec(ctx, `INSERT INTO public.expedition_launches (month,starts_at) VALUES ($1::date,$2)`, month, launch); err != nil {
				return err
			}
			starts = &launch
		}
	} else if options.StartNow && starts == nil && options.Command != "publish-release" {
		return errors.New("cannot change a scheduled calendar month into a partial month")
	}
	report["expeditionMonth"] = month.Format(time.DateOnly)
	report["expeditionPartialStart"] = starts
	return nil
}

func fundReleaseAccount(ctx context.Context, tx pgx.Tx, subject string, report map[string]any) error {
	if !validSubject(subject) {
		return errors.New("an existing development account subject is required")
	}
	var owner uuid.UUID
	err := tx.QueryRow(ctx, `SELECT u.id FROM public.users u JOIN public.visitor_wallets w ON w.owner_id=u.id
		JOIN public.game_catalogue c ON c.id=1 AND c.version=$3
		WHERE u.auth_issuer=$1 AND u.auth_subject=$2 AND u.status='active' FOR UPDATE OF u,w`,
		DevIssuer, subject, woodlandRelease).Scan(&owner)
	if errors.Is(err, pgx.ErrNoRows) {
		return errors.New("publish Woodland and create the local development account first")
	}
	if err != nil {
		return err
	}
	const amount = 20000
	event := uuid.NewSHA1(uuid.NameSpaceURL, []byte("forest/local-release-test-funding/"+owner.String()))
	tag, err := tx.Exec(ctx, `WITH grant_event AS (
			INSERT INTO public.visitor_reward_events (id,owner_id,source_id,kind,created_at,detail)
			VALUES ($1,$2,$1,'release_test_allowance',clock_timestamp(),'{"source":"local release test"}')
			ON CONFLICT (id) DO NOTHING RETURNING id,owner_id,created_at
		), credited AS (
			INSERT INTO public.visitor_wallet_entries (id,owner_id,event_id,amount,created_at)
			SELECT id,owner_id,id,$3,created_at FROM grant_event RETURNING owner_id,amount
		) UPDATE public.visitor_wallets w SET tokens=w.tokens+credited.amount
		FROM credited WHERE credited.owner_id=w.owner_id`, event, owner, amount)
	if err != nil {
		return err
	}
	report["subject"] = subject
	report["tokenGrant"] = tag.RowsAffected() * amount
	return nil
}
