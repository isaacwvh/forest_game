"""Validated profile components and immutable cap policy; no player data rewrite."""

import json

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0006_garden_skills"
down_revision = "0005_species_draws"
branch_labels = None
depends_on = None

CAPS = {
    "schemaVersion": 1,
    "activityBonus": "1.5",
    "waterBonus": "1.5",
    "plantAttractionBonus": "0.5",
    "gardenAttractionBonus": "0.5",
    "totalAttractionBonus": "1",
    "flatAttractionPoints": "10",
    "flatAttractionBaseFraction": "0.25",
    "capacityBonus": "2",
    "flatCapacity": 10,
}


def upgrade():
    op.create_table(
        "skill_policies",
        sa.Column("version", sa.String(100), primary_key=True),
        sa.Column("rules", postgresql.JSONB(), nullable=False),
        sa.CheckConstraint("jsonb_typeof(rules) = 'object'", name="rules_object"),
    )
    op.execute(
        sa.text(
            "INSERT INTO skill_policies VALUES ('b8-caps-v1', CAST(:rules AS jsonb))"
        ).bindparams(rules=json.dumps(CAPS))
    )
    op.execute(
        "CREATE TRIGGER immutable_skill_policy BEFORE UPDATE OR DELETE ON skill_policies "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )
    op.execute(r"""
    CREATE FUNCTION forest_skill_decimal(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE AS $$
    BEGIN
        IF jsonb_typeof(value) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
        IF (value #>> '{}') !~ '^[0-9]{1,7}(\.[0-9]{1,6})?$' THEN RETURN false; END IF;
        RETURN (value #>> '{}')::numeric BETWEEN 0 AND 1000000;
    END $$;
    CREATE FUNCTION forest_skill_selector(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE item record; member jsonb;
    BEGIN
        IF jsonb_typeof(value) IS DISTINCT FROM 'object' OR
           value - ARRAY['species','variants','stages','tags'] <> '{}'::jsonb
        THEN RETURN false; END IF;
        FOR item IN SELECT * FROM jsonb_each(value) LOOP
            IF jsonb_typeof(item.value) IS DISTINCT FROM 'array' THEN RETURN false; END IF;
            IF jsonb_array_length(item.value) > (CASE WHEN item.key='stages' THEN 4 ELSE 64 END)
            THEN RETURN false; END IF;
            FOR member IN SELECT * FROM jsonb_array_elements(item.value) LOOP
                IF jsonb_typeof(member) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
                IF item.key='stages' AND member #>> '{}'
                    NOT IN ('sprout','seedling','young','adult')
                THEN RETURN false; END IF;
            END LOOP;
        END LOOP;
        RETURN true;
    END $$;
    CREATE FUNCTION forest_skill_effect(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE AS $$
    DECLARE magnitude jsonb; cond jsonb; name text; scope text; target text;
    BEGIN
        IF jsonb_typeof(value) IS DISTINCT FROM 'object' OR NOT value ?& ARRAY[
            'id','name','description','system','scope','target','magnitude','stackingGroup'] OR
            value - ARRAY['componentVersion','id','name','description','system','scope','metric',
            'target','recipients','minimumStage','condition','operation','magnitude',
            'stackingGroup','stackingRule'] <> '{}'::jsonb THEN RETURN false; END IF;
        FOREACH name IN ARRAY ARRAY[
            'id','name','description','system','scope','target','stackingGroup'] LOOP
            IF jsonb_typeof(value->name) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
        END LOOP;
        IF value->>'id' !~ '^[a-z][a-z0-9_]{0,99}$' OR
           value->>'stackingGroup' !~ '^[a-z][a-z0-9_]{0,99}$' OR
           length(value->>'name') NOT BETWEEN 1 AND 80 OR
           length(value->>'description') NOT BETWEEN 1 AND 500 OR
           COALESCE(value->'componentVersion','1'::jsonb) <> '1'::jsonb OR
           COALESCE(value->'minimumStage','"adult"'::jsonb) <> '"adult"'::jsonb OR
           COALESCE(value->'stackingRule','"strongest"'::jsonb) <> '"strongest"'::jsonb OR
           COALESCE(value->'operation','"percent"'::jsonb)
               NOT IN ('"percent"'::jsonb,'"flat"'::jsonb)
        THEN RETURN false; END IF;
        scope := value->>'scope'; target := value->>'target';
        IF scope NOT IN (
            'activity','water','attraction_plant','attraction_garden','offline_capacity')
        OR value->>'system' <>
            (CASE WHEN scope IN ('activity','water') THEN 'growth' ELSE 'visitors' END)
        OR target NOT IN ('all_planted_plants','selected_plants','garden')
        OR (scope IN ('activity','water','attraction_plant')) <> (target <> 'garden')
        OR (target = 'selected_plants') <> (COALESCE(value->'recipients','null') <> 'null'::jsonb)
        THEN RETURN false; END IF;
        IF target='selected_plants' AND NOT forest_skill_selector(value->'recipients')
        THEN RETURN false; END IF;
        IF scope='activity' THEN
            IF jsonb_typeof(value->'metric') IS DISTINCT FROM 'string' OR NOT (
                value->>'metric' IN (
                    'steps','walking_running_distance_km','active_energy_kcal','flights_climbed')
                OR value->>'metric' ~ '^workout_minutes\.[a-z][a-z_]{0,63}$')
            THEN RETURN false; END IF;
        ELSIF COALESCE(value->'metric','null') <> 'null'::jsonb THEN RETURN false;
        END IF;
        IF scope IN ('activity','water') AND value->>'operation'='flat' THEN RETURN false; END IF;
        magnitude := value->'magnitude';
        IF jsonb_typeof(magnitude) IS DISTINCT FROM 'object' OR
           magnitude - ARRAY['type','value','selector','maximum'] <> '{}'::jsonb OR
           NOT forest_skill_decimal(magnitude->'value') THEN RETURN false; END IF;
        IF COALESCE(magnitude->'type','"fixed"'::jsonb)
            NOT IN ('"fixed"'::jsonb,'"per_copy"'::jsonb) THEN RETURN false; END IF;
        IF COALESCE(magnitude->>'type','fixed')='per_copy' THEN
            IF NOT forest_skill_selector(magnitude->'selector') OR
               NOT forest_skill_decimal(magnitude->'maximum') THEN RETURN false; END IF;
        ELSIF COALESCE(magnitude->>'type','fixed') <> 'fixed' OR
              COALESCE(magnitude->'selector','null') <> 'null'::jsonb OR
              COALESCE(magnitude->'maximum','null') <> 'null'::jsonb THEN RETURN false;
        END IF;
        cond := value->'condition';
        IF cond IS NOT NULL AND cond <> 'null'::jsonb THEN
            IF jsonb_typeof(cond) IS DISTINCT FROM 'object' OR
               cond - ARRAY['type','selector','minimum'] <> '{}'::jsonb OR
               COALESCE(cond->'type','"placed_count"') <> '"placed_count"'::jsonb OR
               NOT forest_skill_selector(cond->'selector') THEN RETURN false; END IF;
            IF cond ? 'minimum' THEN
                IF jsonb_typeof(cond->'minimum') IS DISTINCT FROM 'number' OR
                   (cond->>'minimum') !~ '^[0-9]{1,5}$' THEN RETURN false; END IF;
                IF (cond->>'minimum')::int NOT BETWEEN 1 AND 10000 THEN RETURN false; END IF;
            END IF;
        END IF;
        RETURN true;
    END $$;
    CREATE OR REPLACE FUNCTION forest_validate_behaviour_profile()
    RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE metric record; effect jsonb; ids text[] := '{}'; units jsonb := '{}'; group_key text;
    BEGIN
        IF (NEW.rules->'schemaVersion' IS DISTINCT FROM '1'::jsonb AND
            NEW.rules->'schemaVersion' IS DISTINCT FROM '2'::jsonb) OR
           jsonb_typeof(NEW.rules->'metricMultipliers') IS DISTINCT FROM 'object' OR
           NEW.rules->'conditionalModifiers' IS DISTINCT FROM '[]'::jsonb OR
           jsonb_typeof(NEW.rules->'gardenEffects') IS DISTINCT FROM 'array' OR
           NEW.rules - ARRAY['schemaVersion','metricMultipliers',
                             'conditionalModifiers','gardenEffects'] <> '{}'::jsonb
        THEN RAISE EXCEPTION 'Unsupported behaviour definition' USING ERRCODE='23514'; END IF;
        IF jsonb_array_length(NEW.rules->'gardenEffects') > 64 OR
           (NEW.rules->'schemaVersion'='1' AND NEW.rules->'gardenEffects' <> '[]')
        THEN RAISE EXCEPTION 'Unsupported effects version' USING ERRCODE='23514'; END IF;
        FOR metric IN SELECT * FROM jsonb_each(NEW.rules->'metricMultipliers') LOOP
            IF metric.key NOT IN ('steps','walking_running_distance_km',
                'active_energy_kcal','flights_climbed','workout_minutes.*')
               AND metric.key !~ '^workout_minutes\.[a-z][a-z_]{0,63}$'
            THEN RAISE EXCEPTION 'Unknown metric' USING ERRCODE='23514'; END IF;
            IF jsonb_typeof(metric.value) IS DISTINCT FROM 'number' THEN
                RAISE EXCEPTION 'Invalid multiplier' USING ERRCODE='23514'; END IF;
            IF metric.value::text::numeric NOT BETWEEN 0 AND 1000000 OR
               trunc(metric.value::text::numeric,6) <> metric.value::text::numeric
            THEN RAISE EXCEPTION 'Invalid multiplier' USING ERRCODE='23514'; END IF;
        END LOOP;
        FOR effect IN SELECT * FROM jsonb_array_elements(NEW.rules->'gardenEffects') LOOP
            IF NOT forest_skill_effect(effect) OR effect->>'id'=ANY(ids)
            THEN RAISE EXCEPTION 'Invalid skill component' USING ERRCODE='23514'; END IF;
            ids := array_append(ids, effect->>'id');
            group_key := (effect->>'system') || '|' || (effect->>'scope') || '|' ||
                COALESCE(effect->>'metric','') || '|' || (effect->>'stackingGroup');
            IF units ? group_key AND units->>group_key <> COALESCE(effect->>'operation','percent')
            THEN RAISE EXCEPTION 'Mixed stacking-group units' USING ERRCODE='23514'; END IF;
            units := units || jsonb_build_object(
                group_key,COALESCE(effect->>'operation','percent'));
        END LOOP;
        RETURN NEW;
    END $$;
    """)


def downgrade():
    # Keep existing profile data immutable. Refuse a downgrade that would strand v2 data.
    op.execute("""DO $$ BEGIN IF EXISTS (SELECT 1 FROM growth_rule_profiles
        WHERE rules->'schemaVersion'='2'::jsonb) THEN
        RAISE EXCEPTION 'Remove B8 data explicitly before downgrading skills'; END IF; END $$""")
    op.execute("""CREATE OR REPLACE FUNCTION forest_validate_behaviour_profile()
        RETURNS trigger LANGUAGE plpgsql AS $$ DECLARE metric record; BEGIN
        IF NEW.rules->'schemaVersion' IS DISTINCT FROM '1'::jsonb
        OR jsonb_typeof(NEW.rules->'metricMultipliers') IS DISTINCT FROM 'object'
        OR NEW.rules->'conditionalModifiers' IS DISTINCT FROM '[]'::jsonb
        OR NEW.rules->'gardenEffects' IS DISTINCT FROM '[]'::jsonb
        OR NEW.rules - ARRAY['schemaVersion','metricMultipliers',
                             'conditionalModifiers','gardenEffects'] <> '{}'::jsonb
        THEN RAISE EXCEPTION 'Unsupported behaviour definition' USING ERRCODE='23514'; END IF;
        FOR metric IN SELECT * FROM jsonb_each(NEW.rules->'metricMultipliers') LOOP
        IF metric.key NOT IN ('steps','walking_running_distance_km',
                             'active_energy_kcal','flights_climbed')
        AND metric.key !~ '^workout_minutes\\.[a-z][a-z_]{0,63}$'
        THEN RAISE EXCEPTION 'Unknown metric' USING ERRCODE='23514'; END IF;
        IF jsonb_typeof(metric.value) IS DISTINCT FROM 'number' OR metric.value::text::numeric < 0
        THEN RAISE EXCEPTION 'Invalid multiplier' USING ERRCODE='23514'; END IF;
        END LOOP; RETURN NEW; END $$""")
    op.execute("DROP FUNCTION forest_skill_effect(jsonb)")
    op.execute("DROP FUNCTION forest_skill_selector(jsonb)")
    op.execute("DROP FUNCTION forest_skill_decimal(jsonb)")
    op.drop_table("skill_policies")
