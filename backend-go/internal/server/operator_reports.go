package server

import (
	"context"
	"strings"

	"github.com/jackc/pgx/v5"
)

type storageTable struct {
	Schema    string   `json:"schema"`
	Name      string   `json:"name"`
	Estimated int64    `json:"estimated_rows"`
	Heap      int64    `json:"heap_bytes"`
	TOAST     int64    `json:"toast_aux_bytes"`
	Indexes   int64    `json:"index_bytes"`
	Total     int64    `json:"total_bytes"`
	Category  string   `json:"category"`
	Referrers []string `json:"referencedBy"`
	Exact     *int64   `json:"exact_rows,omitempty"`
}

var storageCategories = func() map[string]string {
	groups := map[string]string{
		"current_state": `item_step_state daily_item_state owned_items item_placements daily_skill_activity
			account_level_state users gardens owned_plants garden_placements player_progress catalog_discovery_state
			catalog_stage_discoveries garden_visitor_state visitor_storage_lots visitor_wallets visitor_throttles
			visitor_schedules visitor_controls`,
		"durable_recovery": `expedition_runs expedition_days expedition_workouts expedition_entitlements expedition_claims
			expedition_bonus_grants item_step_grants shop_allowances daily_item_grants item_valuations item_sales
			item_identities milestone_state milestone_days milestone_species milestone_entitlements milestone_bonus_grants
			milestone_event_state level_up_notices gem_grants plant_identities plant_sales visitor_day_summaries
			growth_day_summaries api_requests activity_devices activity_days activity_metric_days activity_workouts
			activity_workout_days milestone_claims collection_events owned_packs pack_openings visitor_reward_events
			visitor_wallet_entries visitor_economy_conversions`,
		"history_requires_replacement": `growth_provenance activity_credits plant_growth_credits reward_events reward_recaps
			visitor_contexts visitor_sessions visitor_settlements visitor_opportunities`,
		"shared_configuration": `runtime_control expedition_templates expedition_schedule expedition_launches
			item_skill_profiles item_skill_bindings shop_releases shop_weeks shop_days shop_offer_windows
			item_value_definitions item_shop_offers item_definitions milestone_policies milestone_events
			level_benefits_policy alembic_version schema_migrations game_catalogue growth_profiles growth_rule_profiles
			attraction_profiles plant_species plant_variants plant_stages economy_configs skill_policies visitor_rules
			pack_definitions exchange_offers pack_members`,
	}
	result := make(map[string]string)
	for category, tables := range groups {
		for _, table := range strings.Fields(tables) {
			result[table] = category
		}
	}
	return result
}()

func storageReport(ctx context.Context, tx pgx.Tx, exact bool) (any, error) {
	rows, err := tx.Query(ctx, `SELECT n.nspname,c.relname,greatest(c.reltuples,0)::bigint,
		pg_relation_size(c.oid),pg_table_size(c.oid)-pg_relation_size(c.oid),pg_indexes_size(c.oid),pg_total_relation_size(c.oid),
		ARRAY(SELECT DISTINCT r.relname FROM pg_constraint f JOIN pg_class r ON r.oid=f.conrelid
			WHERE f.contype='f' AND f.confrelid=c.oid ORDER BY r.relname)
		FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
		WHERE c.relkind='r' AND n.nspname NOT IN ('pg_catalog','information_schema')
			AND NOT starts_with(n.nspname,'pg_toast') AND NOT starts_with(n.nspname,'pg_temp')
		ORDER BY pg_total_relation_size(c.oid) DESC,n.nspname,c.relname`)
	if err != nil {
		return nil, err
	}
	tables, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (storageTable, error) {
		var table storageTable
		err := row.Scan(&table.Schema, &table.Name, &table.Estimated, &table.Heap, &table.TOAST,
			&table.Indexes, &table.Total, &table.Referrers)
		table.Category = "platform_shared"
		if table.Schema == "public" {
			table.Category = storageCategories[table.Name]
			if table.Category == "" {
				table.Category = "unclassified"
			}
		}
		return table, err
	})
	if err != nil {
		return nil, err
	}
	counts := "estimates"
	if exact {
		counts = "exact"
		for i, table := range tables {
			identifier := pgx.Identifier{table.Schema, table.Name}.Sanitize()
			if err := tx.QueryRow(ctx, "SELECT count(*) FROM "+identifier).Scan(&tables[i].Exact); err != nil {
				return nil, err
			}
		}
	}
	var bytes int64
	err = tx.QueryRow(ctx, "SELECT pg_database_size(current_database())").Scan(&bytes)
	return map[string]any{"version": 1, "readOnly": true, "rowCounts": counts, "databaseBytes": bytes, "tables": tables}, err
}

func readHistoryBacklog(ctx context.Context, tx pgx.Tx) (any, error) {
	// These are counts by age or receipt state. The worker still verifies each
	// candidate's durable replacement and may retain it.
	var receipts, expired, settlements, opportunities, recaps, growth int64
	err := tx.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM api_requests WHERE response IS NOT NULL AND completion IS NULL),
		(SELECT count(*) FROM api_requests WHERE response IS NOT NULL AND recovery_version=1 AND response_expires_at<=now()),
		(SELECT count(*) FROM visitor_settlements WHERE end_at<=now()-interval '7 days'),
		(SELECT count(*) FROM visitor_opportunities WHERE expires_at<=now()-interval '7 days'),
		(SELECT count(*) FROM reward_recaps WHERE acknowledged_at<=now()-interval '7 days' AND NOT (payload ? 'compacted')),
		(SELECT count(*) FROM reward_events WHERE accepted_at<=now()-interval '30 days' AND NOT (payload ? 'compacted'))`).
		Scan(&receipts, &expired, &settlements, &opportunities, &recaps, &growth)
	return map[string]any{"readOnly": true, "receiptsWithoutCompletion": receipts, "expiredRecoveryResponses": expired,
		"agedVisitorSettlements": settlements, "agedVisitorOpportunities": opportunities,
		"agedAcknowledgedRecaps": recaps, "agedGrowthEvents": growth}, err
}
