"""Woodland capabilities; publication and account upgrades remain explicit."""

import sqlalchemy as sa
from alembic import op

revision = "0015_woodland_release"
down_revision = "0014_level_benefits"
branch_labels = None
depends_on = None


def behaviour_validator(extended):
    sql = op.get_bind().scalar(
        sa.text("SELECT pg_get_functiondef('forest_validate_behaviour_profile()'::regprocedure)")
    )
    old = "NEW.rules->'schemaVersion' IS DISTINCT FROM '2'::jsonb)"
    new = (
        "NEW.rules->'schemaVersion' IS DISTINCT FROM '2'::jsonb AND "
        "NEW.rules->'schemaVersion' IS DISTINCT FROM '3'::jsonb)"
    )
    old_keys = "'conditionalModifiers','gardenEffects']"
    new_keys = "'conditionalModifiers','gardenEffects','conversionRates']"
    sql = (
        sql.replace(old, new).replace(old_keys, new_keys)
        if extended
        else (sql.replace(new, old).replace(new_keys, old_keys))
    )
    op.execute(sql)


def upgrade():
    op.add_column("owned_plants", sa.Column("clearance_radius", sa.Numeric(9, 3)))
    op.execute(
        "UPDATE owned_plants p SET clearance_radius=s.clearance_radius "
        "FROM plant_species s WHERE s.id=p.species_id"
    )
    op.alter_column("owned_plants", "clearance_radius", nullable=False)
    op.create_check_constraint(
        "radius", "owned_plants", "clearance_radius > 0 AND clearance_radius <> 'NaN'::numeric"
    )
    op.execute("""
        CREATE FUNCTION forest_pin_radius() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.clearance_radius IS NULL THEN
            SELECT clearance_radius INTO NEW.clearance_radius
            FROM plant_species WHERE id=NEW.species_id;
          END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER owned_plant_radius BEFORE INSERT ON owned_plants
        FOR EACH ROW EXECUTE FUNCTION forest_pin_radius();
    """)
    op.add_column(
        "exchange_offers",
        sa.Column("currency", sa.String(10), nullable=False, server_default="tokens"),
    )
    op.create_check_constraint("currency", "exchange_offers", "currency IN ('tokens','gems')")
    op.add_column(
        "collection_events",
        sa.Column("gem_delta", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.create_check_constraint(
        "gem_delta", "collection_events", "gem_delta <= 0 AND (token_delta = 0 OR gem_delta = 0)"
    )
    op.create_table(
        "daily_skill_activity",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("game_date", sa.Date(), primary_key=True),
        sa.Column("flights", sa.BigInteger(), nullable=False),
        sa.CheckConstraint("flights >= 0", name="flights"),
    )
    op.execute("ALTER FUNCTION forest_skill_effect(jsonb) RENAME TO forest_skill_effect_v1")
    op.execute("""
        CREATE FUNCTION forest_skill_effect(value jsonb) RETURNS boolean
        LANGUAGE plpgsql IMMUTABLE AS $$
        DECLARE normalized jsonb; magnitude jsonb; kind text;
        BEGIN
          IF COALESCE(value->'componentVersion','1') = '1' THEN
            RETURN forest_skill_effect_v1(value);
          END IF;
          IF value->'componentVersion' IS DISTINCT FROM '2'::jsonb THEN RETURN false; END IF;
          normalized := jsonb_set(value - 'stepBand', '{componentVersion}', '1');
          IF value ? 'stepBand' AND (
             value->>'stepBand' NOT IN ('first_2000','after_2000') OR
             value->>'scope' <> 'activity' OR value->>'metric' <> 'steps')
          THEN RETURN false; END IF;
          magnitude := value->'magnitude';
          kind := magnitude->>'type';
          IF kind IN ('per_species','daily_flights') THEN
            IF kind='daily_flights' THEN
              IF value->>'scope' <> 'attraction_garden' OR
                 COALESCE(magnitude->'selector','null') <> 'null'::jsonb
              THEN RETURN false; END IF;
              magnitude := jsonb_set(magnitude, '{selector}', '{}');
            END IF;
            magnitude := jsonb_set(magnitude, '{type}', '"per_copy"');
            normalized := jsonb_set(normalized, '{magnitude}', magnitude);
          END IF;
          RETURN forest_skill_effect_v1(normalized);
        END $$;
    """)
    behaviour_validator(True)
    op.execute("""
        CREATE FUNCTION forest_validate_woodland_conversion() RETURNS trigger
        LANGUAGE plpgsql AS $$
        DECLARE item record; rate jsonb; effect jsonb;
        BEGIN
          IF NEW.rules->>'schemaVersion' <> '3' THEN
            IF NEW.rules ? 'conversionRates' THEN
              RAISE EXCEPTION 'Pinned conversions require schema 3' USING ERRCODE='23514';
            END IF;
            FOR effect IN SELECT * FROM jsonb_array_elements(NEW.rules->'gardenEffects') LOOP
              IF COALESCE(effect->>'componentVersion','1') <> '1' THEN
                RAISE EXCEPTION 'Extended effects require schema 3' USING ERRCODE='23514';
              END IF;
            END LOOP;
            RETURN NEW;
          END IF;
          IF jsonb_typeof(NEW.rules->'conversionRates') IS DISTINCT FROM 'object' THEN
            RAISE EXCEPTION 'Invalid pinned conversions' USING ERRCODE='23514';
          END IF;
          FOR item IN SELECT * FROM jsonb_each(NEW.rules->'conversionRates') LOOP
            rate := item.value;
            IF NOT (NEW.rules->'metricMultipliers' ? item.key) OR
               jsonb_typeof(rate) <> 'object' OR
               rate - ARRAY['normalisation','water_micro_units','daily_cap'] <> '{}'::jsonb OR
               NOT forest_skill_decimal(rate->'normalisation') OR
               (rate->>'normalisation')::numeric <= 0 OR
               jsonb_typeof(rate->'water_micro_units') IS DISTINCT FROM 'number' OR
               (rate->>'water_micro_units') !~ '^[0-9]{1,19}$' OR
               (rate->>'water_micro_units')::numeric > 9223372036854775807 OR
               (COALESCE(rate->'daily_cap','null') <> 'null'::jsonb AND (
                   jsonb_typeof(rate->'daily_cap') <> 'number' OR
                   (rate->>'daily_cap') !~ '^[0-9]{1,10}$' OR
                   (rate->>'daily_cap')::numeric > 1000000000))
            THEN RAISE EXCEPTION 'Invalid pinned conversion' USING ERRCODE='23514'; END IF;
          END LOOP;
          RETURN NEW;
        END $$;
        CREATE TRIGGER woodland_conversion_validation BEFORE INSERT ON growth_rule_profiles
        FOR EACH ROW EXECUTE FUNCTION forest_validate_woodland_conversion();
    """)
    # Approve only explicitly published Woodland variants; existing identities stay frozen.
    sql = op.get_bind().scalar(
        sa.text("SELECT pg_get_functiondef('forest_record_plant_identity()'::regprocedure)")
    )
    sql = sql.replace(
        "ELSE NULL END\n          FROM plant_species",
        "WHEN s.properties->>'release' = 'woodland-v1' "
        "THEN 10000 ELSE NULL END\n          FROM plant_species",
    )
    op.execute(sql)


def downgrade():
    if op.get_bind().scalar(
        sa.text(
            "SELECT EXISTS(SELECT 1 FROM growth_rule_profiles WHERE rules->>'schemaVersion'='3') "
            "OR EXISTS(SELECT 1 FROM collection_events WHERE gem_delta<>0)"
        )
    ):
        raise RuntimeError("Cannot downgrade published Woodland data; restore a pre-release backup")
    behaviour_validator(False)
    op.execute("DROP TRIGGER woodland_conversion_validation ON growth_rule_profiles")
    op.execute("DROP FUNCTION forest_validate_woodland_conversion()")
    op.execute("DROP FUNCTION forest_skill_effect(jsonb)")
    op.execute("ALTER FUNCTION forest_skill_effect_v1(jsonb) RENAME TO forest_skill_effect")
    sql = op.get_bind().scalar(
        sa.text("SELECT pg_get_functiondef('forest_record_plant_identity()'::regprocedure)")
    )
    sql = sql.replace("WHEN s.properties->>'release' = 'woodland-v1' THEN 10000 ", "")
    op.execute(sql)
    op.drop_table("daily_skill_activity")
    op.drop_constraint("gem_delta", "collection_events", type_="check")
    op.drop_column("collection_events", "gem_delta")
    op.drop_constraint("currency", "exchange_offers", type_="check")
    op.drop_column("exchange_offers", "currency")
    op.execute("DROP TRIGGER owned_plant_radius ON owned_plants")
    op.execute("DROP FUNCTION forest_pin_radius()")
    op.drop_constraint("radius", "owned_plants", type_="check")
    op.drop_column("owned_plants", "clearance_radius")
