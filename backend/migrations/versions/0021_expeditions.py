"""Recurring UTC expeditions and independently accounted item step triggers."""

from alembic import op

revision = "0021_expeditions"
down_revision = "0020_item_rotations"
branch_labels = None
depends_on = None

TABLES = (
    "expedition_templates",
    "expedition_schedule",
    "expedition_runs",
    "expedition_days",
    "expedition_workouts",
    "expedition_entitlements",
    "expedition_claims",
    "expedition_bonus_grants",
    "item_step_state",
    "item_step_grants",
)
IMMUTABLE = (
    "expedition_templates",
    "expedition_schedule",
    "expedition_workouts",
    "expedition_entitlements",
    "expedition_claims",
    "expedition_bonus_grants",
    "item_step_grants",
)


def upgrade():
    from forest_api import expedition_models  # noqa: F401
    from forest_api.models import Base

    for name in TABLES:
        Base.metadata.tables[name].create(op.get_bind())
    for name in IMMUTABLE:
        op.execute(
            f"CREATE TRIGGER immutable_{name} BEFORE UPDATE OR DELETE ON {name} "
            "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
        )
    # Preserve the existing validator, including all old percentage-effect checks.
    op.execute(
        "ALTER FUNCTION forest_validate_item_skill() RENAME TO forest_validate_item_skill_v1"
    )
    op.get_bind().exec_driver_sql("""
      CREATE FUNCTION forest_validate_item_skill() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE effect jsonb; normalized jsonb;
      BEGIN
        IF NEW.version <= 0 OR jsonb_typeof(NEW.rules) IS DISTINCT FROM 'object' THEN
          RAISE EXCEPTION 'Invalid item skill profile';
        END IF;
        IF NEW.rules ? 'triggeredGrants' THEN
          IF NEW.rules - ARRAY['effects','triggeredGrants'] <> '{}'::jsonb
             OR NEW.rules->'effects' IS DISTINCT FROM '[]'::jsonb
             OR NEW.rules->'triggeredGrants' IS DISTINCT FROM '[
                {"type":"daily_placed_steps_flat_water","family":"alignment_of_worlds",
                 "name":"Alignment of Worlds","tiers":[{"steps":2000,"water":"3"},
                   {"steps":4000,"water":"4"},{"steps":6000,"water":"5"}]}]'::jsonb THEN
            RAISE EXCEPTION 'Unsupported triggered item grant';
          END IF;
        ELSE
          IF NEW.version <= 0 OR jsonb_typeof(NEW.rules) IS DISTINCT FROM 'object'
             OR NEW.rules - ARRAY['effects','dailyGrant'] <> '{}'::jsonb
             OR jsonb_typeof(NEW.rules->'effects') IS DISTINCT FROM 'array'
             OR jsonb_array_length(NEW.rules->'effects') > 64 THEN
            RAISE EXCEPTION 'Invalid item skill profile';
          END IF;
          IF NEW.rules ? 'dailyGrant' AND NEW.rules->'dailyGrant' IS DISTINCT FROM
             '{"family":"morning_rain","water":"2.5"}'::jsonb THEN
            RAISE EXCEPTION 'Unsupported daily item grant';
          END IF;
          FOR effect IN SELECT * FROM jsonb_array_elements(NEW.rules->'effects') LOOP
            normalized := effect;
            IF effect->>'scope' = 'welcome_duration' THEN
              IF effect->>'operation' = 'flat' THEN
                RAISE EXCEPTION 'Welcome duration requires a percentage';
              END IF;
              normalized := jsonb_set(normalized, '{scope}', '"attraction_garden"');
            END IF;
            IF effect->>'metric' = 'workouts' THEN
              normalized := jsonb_set(normalized, '{metric}', '"workout_minutes.walking"');
            END IF;
            IF NOT forest_skill_effect(normalized) THEN
              RAISE EXCEPTION 'Unsupported item effect';
            END IF;
          END LOOP;
        END IF;
        RETURN NEW;
      END $$;
      DROP TRIGGER validate_item_skill ON item_skill_profiles;
      CREATE TRIGGER validate_item_skill BEFORE INSERT ON item_skill_profiles
        FOR EACH ROW EXECUTE FUNCTION forest_validate_item_skill();
    """)


def downgrade():
    import sqlalchemy as sa

    for name in TABLES:
        if op.get_bind().scalar(sa.text(f"SELECT EXISTS (SELECT 1 FROM {name})")):
            raise ValueError(
                "Retain expedition and item-trigger facts; restore a pre-release backup"
            )
    if op.get_bind().scalar(
        sa.text("SELECT EXISTS (SELECT 1 FROM item_skill_profiles WHERE rules ? 'triggeredGrants')")
    ):
        raise ValueError("Retain published triggered skills")
    op.execute("DROP TRIGGER validate_item_skill ON item_skill_profiles")
    op.execute("DROP FUNCTION forest_validate_item_skill()")
    op.execute(
        "ALTER FUNCTION forest_validate_item_skill_v1() RENAME TO forest_validate_item_skill"
    )
    op.execute(
        "CREATE TRIGGER validate_item_skill BEFORE INSERT ON item_skill_profiles "
        "FOR EACH ROW EXECUTE FUNCTION forest_validate_item_skill()"
    )
    for name in reversed(TABLES):
        op.drop_table(name)
