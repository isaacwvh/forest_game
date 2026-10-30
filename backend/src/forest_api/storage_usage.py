"""Read-only physical storage inventory and explicit game-table ownership."""

from sqlalchemy import text

from forest_api.models import Base

GROUPS = {
    "current_state": {
        "users",
        "gardens",
        "owned_plants",
        "garden_placements",
        "player_progress",
        "catalog_discovery_state",
        "catalog_stage_discoveries",
        "garden_visitor_state",
        "visitor_storage_lots",
        "visitor_wallets",
        "visitor_throttles",
        "visitor_schedules",
        "visitor_controls",
    },
    "durable_recovery": {
        "visitor_day_summaries",
        "growth_day_summaries",
        "api_requests",
        "activity_devices",
        "activity_days",
        "activity_metric_days",
        "activity_workouts",
        "activity_workout_days",
        "milestone_claims",
        "collection_events",
        "owned_packs",
        "pack_openings",
        "visitor_reward_events",
        "visitor_wallet_entries",
        "visitor_economy_conversions",
    },
    "history_requires_replacement": {
        "growth_provenance",
        "activity_credits",
        "plant_growth_credits",
        "reward_events",
        "reward_recaps",
        "visitor_contexts",
        "visitor_sessions",
        "visitor_settlements",
        "visitor_opportunities",
    },
    "shared_configuration": {
        "alembic_version",
        "game_catalogue",
        "growth_profiles",
        "growth_rule_profiles",
        "attraction_profiles",
        "plant_species",
        "plant_variants",
        "plant_stages",
        "economy_configs",
        "skill_policies",
        "visitor_rules",
        "pack_definitions",
        "exchange_offers",
        "pack_members",
    },
}


def category(schema, table):
    if schema != "public":
        return "platform_shared"
    return next((name for name, tables in GROUPS.items() if table in tables), "unclassified")


def report(session, *, exact=False):
    with session.begin():
        session.execute(text("SET TRANSACTION READ ONLY"))
        rows = (
            session.execute(
                text("""
            SELECT n.nspname AS schema, c.relname AS name,
                   greatest(c.reltuples, 0)::bigint AS estimated_rows,
                   pg_relation_size(c.oid) AS heap_bytes,
                   pg_table_size(c.oid) - pg_relation_size(c.oid) AS toast_aux_bytes,
                   pg_indexes_size(c.oid) AS index_bytes,
                   pg_total_relation_size(c.oid) AS total_bytes
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND n.nspname NOT LIKE 'pg_toast%' AND n.nspname NOT LIKE 'pg_temp%'
            ORDER BY pg_total_relation_size(c.oid) DESC, n.nspname, c.relname
        """)
            )
            .mappings()
            .all()
        )
        tables = []
        for row in rows:
            item = dict(row)
            item["category"] = category(row["schema"], row["name"])
            item["referencedBy"] = sorted(
                {
                    table.name
                    for table in Base.metadata.tables.values()
                    for key in table.foreign_keys
                    if key.column.table.name == row["name"] and row["schema"] == "public"
                }
            )
            if exact:
                # Identifiers come from pg_catalog and are quoted by the dialect.
                quote = session.bind.dialect.identifier_preparer.quote
                qualified = f"{quote(row['schema'])}.{quote(row['name'])}"
                item["exact_rows"] = session.scalar(text(f"SELECT count(*) FROM {qualified}"))
            tables.append(item)
        return {
            "version": 1,
            "readOnly": True,
            "rowCounts": "exact" if exact else "estimates",
            "databaseBytes": session.scalar(text("SELECT pg_database_size(current_database())")),
            "tables": tables,
        }
