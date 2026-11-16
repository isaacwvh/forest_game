"""Saved global shop rotations, pinned item skills and daily grant identities."""

from alembic import op

revision = "0020_item_rotations"
down_revision = "0019_item_commerce"
branch_labels = None
depends_on = None

TABLES = (
    "item_skill_profiles",
    "item_skill_bindings",
    "shop_releases",
    "shop_weeks",
    "shop_days",
    "shop_offer_windows",
    "shop_allowances",
    "daily_item_state",
    "daily_item_grants",
)
IMMUTABLE = (
    "item_skill_profiles",
    "item_skill_bindings",
    "shop_releases",
    "shop_weeks",
    "shop_days",
    "shop_offer_windows",
    "daily_item_grants",
)


def upgrade():
    from forest_api import item_models  # noqa: F401
    from forest_api.models import Base

    for name in TABLES:
        Base.metadata.tables[name].create(op.get_bind())
    for name in IMMUTABLE:
        op.execute(f"""CREATE TRIGGER immutable_{name} BEFORE UPDATE OR DELETE ON {name}
            FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()""")
    op.execute("""
        CREATE FUNCTION forest_validate_item_skill() RETURNS trigger LANGUAGE plpgsql AS $$
        DECLARE effect jsonb; normalized jsonb;
        BEGIN
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
          RETURN NEW;
        END $$;
        CREATE TRIGGER validate_item_skill BEFORE INSERT ON item_skill_profiles
          FOR EACH ROW EXECUTE FUNCTION forest_validate_item_skill();
    """)


def downgrade():
    import sqlalchemy as sa

    for name in TABLES:
        if op.get_bind().scalar(sa.text(f"SELECT EXISTS (SELECT 1 FROM {name})")):
            raise ValueError("Retain shop and daily-grant facts; restore a pre-release backup")
    for name in reversed(TABLES):
        op.drop_table(name)
    op.execute("DROP FUNCTION forest_validate_item_skill()")
