"""B1 B2 ownership and catalogue foundation

Revision ID: 0001_b1_b2
Revises:
"""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0001_b1_b2"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "attraction_profiles",
        sa.Column("id", sa.String(length=100), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("stage_attraction", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("gameplay_tags", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.CheckConstraint(
            "jsonb_typeof(gameplay_tags) = 'array'", name=op.f("ck_attraction_profiles_tags_array")
        ),
        sa.CheckConstraint(
            "jsonb_typeof(stage_attraction) = 'object'",
            name=op.f("ck_attraction_profiles_stages_object"),
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_attraction_profiles_version")),
        sa.PrimaryKeyConstraint("id", "version", name=op.f("pk_attraction_profiles")),
    )
    op.create_table(
        "growth_profiles",
        sa.Column("id", sa.String(length=100), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("thresholds", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("maximum_growth_micro_units", sa.BigInteger(), nullable=False),
        sa.CheckConstraint(
            "jsonb_typeof(thresholds) = 'object'", name=op.f("ck_growth_profiles_thresholds_object")
        ),
        sa.CheckConstraint(
            "maximum_growth_micro_units > 0", name=op.f("ck_growth_profiles_maximum")
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_growth_profiles_version")),
        sa.PrimaryKeyConstraint("id", "version", name=op.f("pk_growth_profiles")),
    )
    op.create_table(
        "growth_rule_profiles",
        sa.Column("id", sa.String(length=100), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("rules", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.CheckConstraint(
            "jsonb_typeof(rules) = 'object'", name=op.f("ck_growth_rule_profiles_rules_object")
        ),
        sa.CheckConstraint("version > 0", name=op.f("ck_growth_rule_profiles_version")),
        sa.PrimaryKeyConstraint("id", "version", name=op.f("pk_growth_rule_profiles")),
    )
    op.create_table(
        "users",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("auth_issuer", sa.Text(), nullable=False),
        sa.Column("auth_subject", sa.String(length=255), nullable=False),
        sa.Column("username", sa.String(length=32), nullable=False),
        sa.Column("display_name", sa.String(length=64), nullable=False),
        sa.Column("game_timezone", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=16), server_default="active", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("status IN ('active', 'disabled')", name=op.f("ck_users_status")),
        sa.CheckConstraint("username ~ '^[a-z0-9_]{3,32}$'", name=op.f("ck_users_username_format")),
        sa.CheckConstraint(
            "char_length(btrim(display_name)) BETWEEN 1 AND 64", name=op.f("ck_users_display_name")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_users")),
        sa.UniqueConstraint("auth_issuer", "auth_subject", name=op.f("uq_users_auth_issuer")),
    )
    op.create_index(
        "uq_users_username_normalized", "users", [sa.literal_column("lower(username)")], unique=True
    )
    op.create_table(
        "api_requests",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("operation", sa.String(length=100), nullable=False),
        sa.Column("payload_hash", sa.String(length=64), nullable=False),
        sa.Column("response", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_api_requests_user_id_users")
        ),
        sa.PrimaryKeyConstraint("user_id", "request_id", name=op.f("pk_api_requests")),
    )
    op.create_table(
        "gardens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.Uuid(), nullable=False),
        sa.Column("width", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("depth", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("visibility", sa.String(length=16), server_default="friends", nullable=False),
        sa.Column("layout_version", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column("state_version", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("depth > 0 AND depth <> 'NaN'::numeric", name=op.f("ck_gardens_depth")),
        sa.CheckConstraint(
            "visibility IN ('friends', 'private')", name=op.f("ck_gardens_visibility")
        ),
        sa.CheckConstraint("width > 0 AND width <> 'NaN'::numeric", name=op.f("ck_gardens_width")),
        sa.CheckConstraint(
            "layout_version >= 0 AND state_version >= 0", name=op.f("ck_gardens_versions")
        ),
        sa.ForeignKeyConstraint(["owner_id"], ["users.id"], name=op.f("fk_gardens_owner_id_users")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_gardens")),
        sa.UniqueConstraint("id", "owner_id", name=op.f("uq_gardens_id")),
        sa.UniqueConstraint("owner_id", name=op.f("uq_gardens_owner_id")),
    )
    op.create_table(
        "plant_species",
        sa.Column("id", sa.String(length=100), nullable=False),
        sa.Column("display_name", sa.String(length=100), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("clearance_radius", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("growth_profile_id", sa.String(length=100), nullable=False),
        sa.Column("growth_profile_version", sa.Integer(), nullable=False),
        sa.Column("behaviour_profile_id", sa.String(length=100), nullable=False),
        sa.Column("behaviour_profile_version", sa.Integer(), nullable=False),
        sa.Column("attraction_profile_id", sa.String(length=100), nullable=False),
        sa.Column("attraction_profile_version", sa.Integer(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("is_fixture", sa.Boolean(), server_default="false", nullable=False),
        sa.Column(
            "properties",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="{}",
            nullable=False,
        ),
        sa.CheckConstraint(
            "clearance_radius > 0 AND clearance_radius <> 'NaN'::numeric",
            name=op.f("ck_plant_species_clearance_radius"),
        ),
        sa.ForeignKeyConstraint(
            ["attraction_profile_id", "attraction_profile_version"],
            ["attraction_profiles.id", "attraction_profiles.version"],
            name=op.f("fk_plant_species_attraction_profile_id_attraction_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["behaviour_profile_id", "behaviour_profile_version"],
            ["growth_rule_profiles.id", "growth_rule_profiles.version"],
            name=op.f("fk_plant_species_behaviour_profile_id_growth_rule_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["growth_profile_id", "growth_profile_version"],
            ["growth_profiles.id", "growth_profiles.version"],
            name=op.f("fk_plant_species_growth_profile_id_growth_profiles"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_plant_species")),
    )
    op.create_table(
        "plant_variants",
        sa.Column("species_id", sa.String(length=100), nullable=False),
        sa.Column("variant_id", sa.String(length=100), nullable=False),
        sa.Column("display_name", sa.String(length=100), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("rarity", sa.String(length=32), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("asset_catalog_key", sa.Text(), nullable=False),
        sa.Column("asset_catalog_version", sa.String(length=100), nullable=False),
        sa.Column("growth_profile_id", sa.String(length=100), nullable=True),
        sa.Column("growth_profile_version", sa.Integer(), nullable=True),
        sa.Column("behaviour_profile_id", sa.String(length=100), nullable=True),
        sa.Column("behaviour_profile_version", sa.Integer(), nullable=True),
        sa.Column("attraction_profile_id", sa.String(length=100), nullable=True),
        sa.Column("attraction_profile_version", sa.Integer(), nullable=True),
        sa.CheckConstraint(
            "(attraction_profile_id IS NULL) = (attraction_profile_version IS NULL)",
            name=op.f("ck_plant_variants_attraction_override_pair"),
        ),
        sa.CheckConstraint(
            "(behaviour_profile_id IS NULL) = (behaviour_profile_version IS NULL)",
            name=op.f("ck_plant_variants_behaviour_override_pair"),
        ),
        sa.CheckConstraint(
            "(growth_profile_id IS NULL) = (growth_profile_version IS NULL)",
            name=op.f("ck_plant_variants_growth_override_pair"),
        ),
        sa.ForeignKeyConstraint(
            ["attraction_profile_id", "attraction_profile_version"],
            ["attraction_profiles.id", "attraction_profiles.version"],
            name=op.f("fk_plant_variants_attraction_profile_id_attraction_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["behaviour_profile_id", "behaviour_profile_version"],
            ["growth_rule_profiles.id", "growth_rule_profiles.version"],
            name=op.f("fk_plant_variants_behaviour_profile_id_growth_rule_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["growth_profile_id", "growth_profile_version"],
            ["growth_profiles.id", "growth_profiles.version"],
            name=op.f("fk_plant_variants_growth_profile_id_growth_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["species_id"],
            ["plant_species.id"],
            name=op.f("fk_plant_variants_species_id_plant_species"),
        ),
        sa.PrimaryKeyConstraint("species_id", "variant_id", name=op.f("pk_plant_variants")),
    )
    op.create_table(
        "game_catalogue",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("version", sa.String(length=100), nullable=False),
        sa.Column("is_fixture", sa.Boolean(), nullable=False),
        sa.Column("unit_metres", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("board_width", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("board_depth", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("starter_species_id", sa.String(length=100), nullable=False),
        sa.Column("starter_variant_id", sa.String(length=100), nullable=False),
        sa.CheckConstraint(
            "board_depth > 0 AND board_depth <> 'NaN'::numeric",
            name=op.f("ck_game_catalogue_board_depth"),
        ),
        sa.CheckConstraint(
            "board_width > 0 AND board_width <> 'NaN'::numeric",
            name=op.f("ck_game_catalogue_board_width"),
        ),
        sa.CheckConstraint(
            "unit_metres > 0 AND unit_metres <> 'NaN'::numeric",
            name=op.f("ck_game_catalogue_unit_metres"),
        ),
        sa.CheckConstraint("id = 1", name=op.f("ck_game_catalogue_singleton")),
        sa.ForeignKeyConstraint(
            ["starter_species_id", "starter_variant_id"],
            ["plant_variants.species_id", "plant_variants.variant_id"],
            name=op.f("fk_game_catalogue_starter_species_id_plant_variants"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_game_catalogue")),
    )
    op.create_table(
        "owned_plants",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.Uuid(), nullable=False),
        sa.Column("species_id", sa.String(length=100), nullable=False),
        sa.Column("variant_id", sa.String(length=100), nullable=False),
        sa.Column("growth_profile_id", sa.String(length=100), nullable=False),
        sa.Column("growth_profile_version", sa.Integer(), nullable=False),
        sa.Column("behaviour_profile_id", sa.String(length=100), nullable=False),
        sa.Column("behaviour_profile_version", sa.Integer(), nullable=False),
        sa.Column("attraction_profile_id", sa.String(length=100), nullable=False),
        sa.Column("attraction_profile_version", sa.Integer(), nullable=False),
        sa.Column("growth_micro_units", sa.BigInteger(), server_default="0", nullable=False),
        sa.Column(
            "fractional_state",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default="{}",
            nullable=False,
        ),
        sa.Column("acquisition_source", sa.String(length=64), nullable=False),
        sa.Column("acquisition_reference", sa.String(length=255), nullable=False),
        sa.Column("first_matured_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "jsonb_typeof(fractional_state) = 'object'",
            name=op.f("ck_owned_plants_fractional_object"),
        ),
        sa.CheckConstraint("growth_micro_units >= 0", name=op.f("ck_owned_plants_growth")),
        sa.ForeignKeyConstraint(
            ["attraction_profile_id", "attraction_profile_version"],
            ["attraction_profiles.id", "attraction_profiles.version"],
            name=op.f("fk_owned_plants_attraction_profile_id_attraction_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["behaviour_profile_id", "behaviour_profile_version"],
            ["growth_rule_profiles.id", "growth_rule_profiles.version"],
            name=op.f("fk_owned_plants_behaviour_profile_id_growth_rule_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["growth_profile_id", "growth_profile_version"],
            ["growth_profiles.id", "growth_profiles.version"],
            name=op.f("fk_owned_plants_growth_profile_id_growth_profiles"),
        ),
        sa.ForeignKeyConstraint(
            ["owner_id"], ["users.id"], name=op.f("fk_owned_plants_owner_id_users")
        ),
        sa.ForeignKeyConstraint(
            ["species_id", "variant_id"],
            ["plant_variants.species_id", "plant_variants.variant_id"],
            name=op.f("fk_owned_plants_species_id_plant_variants"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_owned_plants")),
        sa.UniqueConstraint("id", "owner_id", name=op.f("uq_owned_plants_id")),
        sa.UniqueConstraint(
            "owner_id",
            "acquisition_source",
            "acquisition_reference",
            name=op.f("uq_owned_plants_owner_id"),
        ),
    )
    op.create_index(op.f("ix_owned_plants_owner_id"), "owned_plants", ["owner_id"], unique=False)
    op.create_table(
        "plant_stages",
        sa.Column("species_id", sa.String(length=100), nullable=False),
        sa.Column("variant_id", sa.String(length=100), nullable=False),
        sa.Column("stage", sa.String(length=16), nullable=False),
        sa.Column("model_key", sa.Text(), nullable=False),
        sa.Column("thumbnail_key", sa.Text(), nullable=False),
        sa.CheckConstraint(
            "stage IN ('sprout', 'seedling', 'young', 'adult')", name=op.f("ck_plant_stages_stage")
        ),
        sa.ForeignKeyConstraint(
            ["species_id", "variant_id"],
            ["plant_variants.species_id", "plant_variants.variant_id"],
            name=op.f("fk_plant_stages_species_id_plant_variants"),
        ),
        sa.PrimaryKeyConstraint("species_id", "variant_id", "stage", name=op.f("pk_plant_stages")),
    )
    op.create_table(
        "garden_placements",
        sa.Column("plant_id", sa.Uuid(), nullable=False),
        sa.Column("owner_id", sa.Uuid(), nullable=False),
        sa.Column("garden_id", sa.Uuid(), nullable=False),
        sa.Column("x", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("y", sa.Numeric(precision=9, scale=3), nullable=False),
        sa.Column("rotation_degrees", sa.Numeric(precision=5, scale=2), nullable=False),
        sa.CheckConstraint("x >= 0 AND x <> 'NaN'::numeric", name=op.f("ck_garden_placements_x")),
        sa.CheckConstraint("y >= 0 AND y <> 'NaN'::numeric", name=op.f("ck_garden_placements_y")),
        sa.CheckConstraint(
            "rotation_degrees >= 0 AND rotation_degrees < 360",
            name=op.f("ck_garden_placements_rotation"),
        ),
        sa.ForeignKeyConstraint(
            ["garden_id", "owner_id"],
            ["gardens.id", "gardens.owner_id"],
            name=op.f("fk_garden_placements_garden_id_gardens"),
        ),
        sa.ForeignKeyConstraint(
            ["plant_id", "owner_id"],
            ["owned_plants.id", "owned_plants.owner_id"],
            name=op.f("fk_garden_placements_plant_id_owned_plants"),
        ),
        sa.PrimaryKeyConstraint("plant_id", name=op.f("pk_garden_placements")),
    )
    op.create_index(
        op.f("ix_garden_placements_garden_id"), "garden_placements", ["garden_id"], unique=False
    )
    op.execute("""
        CREATE FUNCTION forest_immutable_profile() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
            RAISE EXCEPTION 'Profile versions are immutable; insert a new version'
                USING ERRCODE = '23514';
        END $$
    """)
    op.execute("""
        CREATE FUNCTION forest_validate_stage_profile() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
            data jsonb;
            stage text;
            amount bigint;
            previous bigint := -1;
        BEGIN
            IF TG_TABLE_NAME = 'growth_profiles' THEN
                data := to_jsonb(NEW)->'thresholds';
            ELSE
                data := to_jsonb(NEW)->'stage_attraction';
            END IF;
            IF jsonb_typeof(data) IS DISTINCT FROM 'object'
               OR NOT data ?& ARRAY['sprout', 'seedling', 'young', 'adult']
               OR (SELECT count(*) FROM jsonb_object_keys(data)) <> 4 THEN
                RAISE EXCEPTION 'Exactly four stage values are required' USING ERRCODE = '23514';
            END IF;
            FOREACH stage IN ARRAY ARRAY['sprout', 'seedling', 'young', 'adult'] LOOP
                IF jsonb_typeof(data->stage) IS DISTINCT FROM 'number'
                   OR (data->>stage) !~ '^(0|[1-9][0-9]*)$' THEN
                    RAISE EXCEPTION 'Stage values must be nonnegative integers'
                        USING ERRCODE = '23514';
                END IF;
                amount := (data->>stage)::bigint;
                IF amount <= previous THEN
                    RAISE EXCEPTION 'Stage values must strictly increase' USING ERRCODE = '23514';
                END IF;
                previous := amount;
            END LOOP;
            IF TG_TABLE_NAME = 'growth_profiles' THEN
                IF data->>'sprout' <> '0'
                   OR (to_jsonb(NEW)->>'maximum_growth_micro_units')::bigint < previous THEN
                    RAISE EXCEPTION 'Invalid growth start or maturity maximum'
                        USING ERRCODE = '23514';
                END IF;
            END IF;
            RETURN NEW;
        END $$
    """)
    op.execute("""
        CREATE FUNCTION forest_validate_behaviour_profile() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE
            metric record;
        BEGIN
            IF NEW.rules->'schemaVersion' IS DISTINCT FROM '1'::jsonb
               OR jsonb_typeof(NEW.rules->'metricMultipliers') IS DISTINCT FROM 'object'
               OR NEW.rules->'conditionalModifiers' IS DISTINCT FROM '[]'::jsonb
               OR NEW.rules->'gardenEffects' IS DISTINCT FROM '[]'::jsonb
               OR NEW.rules - ARRAY['schemaVersion', 'metricMultipliers',
                                   'conditionalModifiers', 'gardenEffects'] <> '{}'::jsonb THEN
                RAISE EXCEPTION 'Unsupported behaviour definition; B2 supports neutral effects only'
                    USING ERRCODE = '23514';
            END IF;
            FOR metric IN SELECT * FROM jsonb_each(NEW.rules->'metricMultipliers') LOOP
                IF metric.key NOT IN ('steps', 'walking_running_distance_km',
                                      'active_energy_kcal', 'flights_climbed')
                   AND metric.key !~ '^workout_minutes\\.[a-z][a-z_]{0,63}$' THEN
                    RAISE EXCEPTION 'Unknown metric' USING ERRCODE = '23514';
                END IF;
                IF jsonb_typeof(metric.value) IS DISTINCT FROM 'number'
                   OR metric.value::text::numeric < 0 THEN
                    RAISE EXCEPTION 'Invalid multiplier' USING ERRCODE = '23514';
                END IF;
            END LOOP;
            RETURN NEW;
        END $$
    """)
    for table in ("growth_profiles", "attraction_profiles", "growth_rule_profiles"):
        op.execute(f"""
            CREATE TRIGGER immutable_profile BEFORE UPDATE OR DELETE ON {table}
            FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()
        """)
        validator = (
            "forest_validate_behaviour_profile"
            if table == "growth_rule_profiles"
            else "forest_validate_stage_profile"
        )
        op.execute(f"""
            CREATE TRIGGER validate_profile BEFORE INSERT ON {table}
            FOR EACH ROW EXECUTE FUNCTION {validator}()
        """)


def downgrade() -> None:
    op.drop_index(op.f("ix_garden_placements_garden_id"), table_name="garden_placements")
    op.drop_table("garden_placements")
    op.drop_table("plant_stages")
    op.drop_index(op.f("ix_owned_plants_owner_id"), table_name="owned_plants")
    op.drop_table("owned_plants")
    op.drop_table("game_catalogue")
    op.drop_table("plant_variants")
    op.drop_table("plant_species")
    op.drop_table("gardens")
    op.drop_table("api_requests")
    op.drop_index("uq_users_username_normalized", table_name="users")
    op.drop_table("users")
    op.drop_table("growth_rule_profiles")
    op.drop_table("growth_profiles")
    op.drop_table("attraction_profiles")
    op.execute("DROP FUNCTION forest_validate_behaviour_profile()")
    op.execute("DROP FUNCTION forest_validate_stage_profile()")
    op.execute("DROP FUNCTION forest_immutable_profile()")
