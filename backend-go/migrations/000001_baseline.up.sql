--
-- PostgreSQL database dump
--


-- Dumped from database version 17.12 (Debian 17.12-1.pgdg12+1)
-- Dumped by pg_dump version 17.12 (Debian 17.12-1.pgdg12+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA IF NOT EXISTS public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: forest_compact_growth_event(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_compact_growth_event() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF current_setting('forest.history_compaction', true) = 'on' AND
             (to_jsonb(NEW) - 'payload') = (to_jsonb(OLD) - 'payload') AND
             NEW.payload = jsonb_build_object('compacted', 1, 'kind', 'activity_growth',
                 'creditIds', coalesce(OLD.payload->'creditIds', '[]'::jsonb)) AND
             NOT EXISTS (SELECT 1 FROM reward_recaps
                         WHERE event_id = OLD.id AND acknowledged_at IS NULL)
          THEN RETURN NEW; END IF;
          RAISE EXCEPTION 'Growth events are immutable' USING ERRCODE = '23514';
        END $$;


--
-- Name: forest_immutable_milestone_policy(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_immutable_milestone_policy() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'active') <> (to_jsonb(OLD) - 'active') THEN
            RAISE EXCEPTION 'Milestone policies are immutable; publish a new version';
          END IF;
          RETURN NEW;
        END; $$;


--
-- Name: forest_immutable_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_immutable_profile() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            RAISE EXCEPTION 'Profile versions are immutable; insert a new version'
                USING ERRCODE = '23514';
        END $$;


--
-- Name: forest_item_offer_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_item_offer_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'active') <> (to_jsonb(OLD) - 'active') THEN
            RAISE EXCEPTION 'Item offers are immutable; publish a new version';
          END IF;
          RETURN NEW;
        END; $$;


--
-- Name: forest_no_sold_item(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_no_sold_item() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF EXISTS (SELECT 1 FROM item_sales WHERE owned_item_id = NEW.id) THEN
            RAISE EXCEPTION 'Sold item identities cannot be restored';
          END IF;
          RETURN NEW;
        END; $$;


--
-- Name: forest_offer_immutable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_offer_immutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF (to_jsonb(NEW) - 'active') IS DISTINCT FROM (to_jsonb(OLD) - 'active') THEN
                RAISE EXCEPTION 'Offer terms are immutable; publish a new version'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END; $$;


--
-- Name: forest_opportunity_transition(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_opportunity_transition() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF (to_jsonb(NEW) - 'status' - 'result') IS DISTINCT FROM
               (to_jsonb(OLD) - 'status' - 'result') OR
               (OLD.status <> 'issued' AND NOT
                (OLD.status = 'welcomed' AND NEW.status = 'welcomed' AND
                 OLD.result IS NULL AND NEW.result IS NOT NULL)) THEN
                RAISE EXCEPTION 'Visitor opportunity is immutable after consumption'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END $$;


--
-- Name: forest_pack_asset_retention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_pack_asset_retention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF EXISTS (SELECT 1 FROM pack_members
                       WHERE species_id = OLD.species_id AND variant_id = OLD.variant_id) THEN
                RAISE EXCEPTION 'Published pack stage assets must be retained'
                    USING ERRCODE = '23514';
            END IF;
            IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
            RETURN NEW;
        END; $$;


--
-- Name: forest_pack_manifest_retention(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_pack_manifest_retention() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF (NEW.asset_catalog_key, NEW.asset_catalog_version) IS DISTINCT FROM
               (OLD.asset_catalog_key, OLD.asset_catalog_version)
               AND EXISTS (SELECT 1 FROM pack_members
                           WHERE species_id = OLD.species_id AND variant_id = OLD.variant_id) THEN
                RAISE EXCEPTION 'Published pack manifests must be retained'
                    USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END; $$;


--
-- Name: forest_pin_radius(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_pin_radius() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF NEW.clearance_radius IS NULL THEN
            SELECT clearance_radius INTO NEW.clearance_radius
            FROM plant_species WHERE id=NEW.species_id;
          END IF;
          RETURN NEW;
        END $$;


--
-- Name: forest_recap_ack_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_recap_ack_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF current_setting('forest.history_compaction', true) = 'on' AND
             OLD.acknowledged_at IS NOT NULL AND
             (to_jsonb(NEW) - 'payload') = (to_jsonb(OLD) - 'payload') AND
             NEW.payload = jsonb_build_object('compacted', 1, 'eventId', OLD.event_id::text)
          THEN RETURN NEW; END IF;
          IF NEW.id IS DISTINCT FROM OLD.id OR NEW.owner_id IS DISTINCT FROM OLD.owner_id OR
             NEW.event_id IS DISTINCT FROM OLD.event_id OR
             NEW.created_at IS DISTINCT FROM OLD.created_at OR
             NEW.payload IS DISTINCT FROM OLD.payload OR
             (OLD.acknowledged_at IS NOT NULL AND
              NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at)
          THEN RAISE EXCEPTION 'Recap is immutable' USING ERRCODE = '23514'; END IF;
          RETURN NEW;
        END $$;


--
-- Name: forest_record_plant_identity(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_record_plant_identity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          INSERT INTO plant_identities
            (id, owner_id, acquisition_source, acquisition_reference,
             valuation_version, valuation_rarity, variant_basis_points)
          SELECT NEW.id, NEW.owner_id, NEW.acquisition_source, NEW.acquisition_reference,
            'plant-resale-v1',
            CASE WHEN s.rarity IN ('common','rare','epic','legendary') THEN s.rarity
                 WHEN s.id = 'oak' THEN 'common'
                 WHEN s.id = 'moonwillow' THEN 'epic' ELSE NULL END,
            CASE WHEN NEW.variant_id = 'standard' THEN 10000
                 WHEN NEW.species_id = 'oak' AND NEW.variant_id = 'blue' THEN 12500
                 WHEN NEW.species_id = 'oak' AND NEW.variant_id = 'vined' THEN 15000
                 WHEN NEW.species_id = 'moonwillow' AND NEW.variant_id = 'golden' THEN 15000
                 WHEN s.properties->>'release' = 'woodland-v1' THEN 10000 ELSE NULL END
          FROM plant_species s WHERE s.id = NEW.species_id
          ON CONFLICT (id) DO NOTHING;
          IF EXISTS (SELECT 1 FROM plant_sales WHERE plant_id = NEW.id) THEN
            RAISE EXCEPTION 'A sold plant cannot be reacquired';
          END IF;
          RETURN NEW;
        END $$;


--
-- Name: forest_reward_recovery_metadata(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_reward_recovery_metadata() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
          IF (to_jsonb(NEW) - 'receipt' - 'summarized_at') IS DISTINCT FROM
             (to_jsonb(OLD) - 'receipt' - 'summarized_at') OR
             (OLD.receipt IS NOT NULL AND NEW.receipt IS DISTINCT FROM OLD.receipt) OR
             (NEW.receipt IS NOT DISTINCT FROM OLD.receipt AND
              NEW.summarized_at IS NOT DISTINCT FROM OLD.summarized_at) OR
             (OLD.summarized_at IS NOT NULL AND
              NEW.summarized_at IS DISTINCT FROM OLD.summarized_at)
          THEN RAISE EXCEPTION 'Visitor reward facts are immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END $$;


--
-- Name: forest_skill_decimal(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_skill_decimal(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
    BEGIN
        IF jsonb_typeof(value) IS DISTINCT FROM 'string' THEN RETURN false; END IF;
        IF (value #>> '{}') !~ '^[0-9]{1,7}(\.[0-9]{1,6})?$' THEN RETURN false; END IF;
        RETURN (value #>> '{}')::numeric BETWEEN 0 AND 1000000;
    END $_$;


--
-- Name: forest_skill_effect(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_skill_effect(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
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


--
-- Name: forest_skill_effect_v1(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_skill_effect_v1(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $_$
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
    END $_$;


--
-- Name: forest_skill_selector(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_skill_selector(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE
    AS $$
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


--
-- Name: forest_validate_behaviour_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_validate_behaviour_profile() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
    DECLARE metric record; effect jsonb; ids text[] := '{}'; units jsonb := '{}'; group_key text;
    BEGIN
        IF (NEW.rules->'schemaVersion' IS DISTINCT FROM '1'::jsonb AND
            NEW.rules->'schemaVersion' IS DISTINCT FROM '2'::jsonb AND NEW.rules->'schemaVersion' IS DISTINCT FROM '3'::jsonb) OR
           jsonb_typeof(NEW.rules->'metricMultipliers') IS DISTINCT FROM 'object' OR
           NEW.rules->'conditionalModifiers' IS DISTINCT FROM '[]'::jsonb OR
           jsonb_typeof(NEW.rules->'gardenEffects') IS DISTINCT FROM 'array' OR
           NEW.rules - ARRAY['schemaVersion','metricMultipliers',
                             'conditionalModifiers','gardenEffects','conversionRates'] <> '{}'::jsonb
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
    END $_$;


--
-- Name: forest_validate_item_skill(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_validate_item_skill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: forest_validate_item_skill_v1(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_validate_item_skill_v1() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: forest_validate_stage_profile(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_validate_stage_profile() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
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
        END $_$;


--
-- Name: forest_validate_woodland_conversion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_validate_woodland_conversion() RETURNS trigger
    LANGUAGE plpgsql
    AS $_$
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
        END $_$;


--
-- Name: forest_visitor_rules_forward(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.forest_visitor_rules_forward() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            IF EXISTS (SELECT 1 FROM garden_visitor_state WHERE settled_at >= NEW.effective_at)
            THEN RAISE EXCEPTION 'Visitor rules must take effect after settled history'
                USING ERRCODE = '23514'; END IF;
            RETURN NEW;
        END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: account_level_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.account_level_state (
    owner_id uuid NOT NULL,
    reached_level bigint NOT NULL,
    presented_level bigint NOT NULL,
    CONSTRAINT ck_account_level_state_levels CHECK (((reached_level >= presented_level) AND (presented_level >= 1)))
);


--
-- Name: activity_credits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_credits (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    device_id uuid NOT NULL,
    request_id uuid NOT NULL,
    rule_version character varying(100) NOT NULL,
    start_steps bigint NOT NULL,
    end_steps bigint NOT NULL,
    water_steps bigint NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    metric_quantities jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ck_activity_credits_range CHECK (((start_steps >= 0) AND (end_steps >= start_steps) AND (water_steps >= 0) AND (water_steps <= (end_steps - start_steps)) AND ((end_steps > start_steps) OR (metric_quantities <> '{}'::jsonb))))
);


--
-- Name: activity_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_days (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    game_timezone character varying(64) NOT NULL,
    bucket_start timestamp with time zone NOT NULL,
    bucket_end timestamp with time zone NOT NULL,
    device_id uuid NOT NULL,
    rule_version character varying(100) NOT NULL,
    baseline_steps bigint NOT NULL,
    baseline_credit_steps bigint NOT NULL,
    observed_steps bigint,
    observed_at timestamp with time zone NOT NULL,
    is_available boolean NOT NULL,
    credited_steps bigint NOT NULL,
    CONSTRAINT ck_activity_days_interval CHECK ((bucket_end > bucket_start)),
    CONSTRAINT ck_activity_days_observed CHECK (((observed_steps IS NULL) OR (observed_steps >= 0))),
    CONSTRAINT ck_activity_days_steps CHECK (((credited_steps >= 0) AND (baseline_steps >= 0) AND (baseline_credit_steps >= 0)))
);


--
-- Name: activity_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_devices (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    installation_id uuid NOT NULL,
    enrolled_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    baseline_at timestamp with time zone,
    baseline_observed_at timestamp with time zone,
    baseline_date date,
    baseline_steps bigint,
    metric_baselines jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT ck_activity_devices_baseline CHECK ((((baseline_at IS NULL) AND (baseline_observed_at IS NULL) AND (baseline_date IS NULL) AND (baseline_steps IS NULL)) OR ((baseline_at IS NOT NULL) AND (baseline_observed_at IS NOT NULL) AND (baseline_date IS NOT NULL) AND (baseline_at >= enrolled_at) AND (baseline_steps IS NOT NULL) AND (baseline_steps >= 0)))),
    CONSTRAINT ck_activity_devices_revocation CHECK (((revoked_at IS NULL) OR (revoked_at >= enrolled_at)))
);


--
-- Name: activity_metric_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_metric_days (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    metric character varying(100) NOT NULL,
    device_id uuid NOT NULL,
    rule_version character varying(100) NOT NULL,
    baseline bigint NOT NULL,
    baseline_credit bigint NOT NULL,
    credited bigint NOT NULL,
    observed bigint,
    observed_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_activity_metric_days_observed CHECK (((observed IS NULL) OR (observed >= 0))),
    CONSTRAINT ck_activity_metric_days_quantities CHECK (((baseline >= 0) AND (baseline_credit >= 0) AND (credited >= 0)))
);


--
-- Name: activity_workout_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_workout_days (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    rule_version character varying(100) NOT NULL,
    covered_intervals jsonb NOT NULL,
    credited_microseconds bigint NOT NULL,
    remainder jsonb NOT NULL,
    CONSTRAINT ck_activity_workout_days_quantity CHECK ((credited_microseconds >= 0))
);


--
-- Name: activity_workouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_workouts (
    owner_id uuid NOT NULL,
    workout_id uuid NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    payload jsonb NOT NULL,
    outcome character varying(40) NOT NULL
);


--
-- Name: api_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_requests (
    user_id uuid NOT NULL,
    request_id uuid NOT NULL,
    operation character varying(100) NOT NULL,
    payload_hash character varying(64) NOT NULL,
    response jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completion jsonb,
    response_expires_at timestamp with time zone,
    recovery_version integer DEFAULT 0 NOT NULL,
    CONSTRAINT ck_api_requests_completion_size CHECK ((octet_length((completion)::text) <= 8192)),
    CONSTRAINT ck_api_requests_recoverable CHECK (((response IS NOT NULL) OR (completion IS NOT NULL)))
);


--
-- Name: attraction_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attraction_profiles (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    stage_attraction jsonb NOT NULL,
    gameplay_tags jsonb NOT NULL,
    CONSTRAINT ck_attraction_profiles_stages_object CHECK ((jsonb_typeof(stage_attraction) = 'object'::text)),
    CONSTRAINT ck_attraction_profiles_tags_array CHECK ((jsonb_typeof(gameplay_tags) = 'array'::text)),
    CONSTRAINT ck_attraction_profiles_version CHECK ((version > 0))
);


--
-- Name: catalog_discovery_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_discovery_state (
    owner_id uuid NOT NULL,
    version bigint DEFAULT '0'::bigint NOT NULL,
    CONSTRAINT ck_catalog_discovery_state_version CHECK ((version >= 0))
);


--
-- Name: catalog_stage_discoveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.catalog_stage_discoveries (
    owner_id uuid NOT NULL,
    species_id character varying(100) NOT NULL,
    variant_id character varying(100) NOT NULL,
    stage character varying(16) NOT NULL,
    recorded_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_catalog_stage_discoveries_stage CHECK (((stage)::text = ANY ((ARRAY['sprout'::character varying, 'seedling'::character varying, 'young'::character varying, 'adult'::character varying])::text[])))
);


--
-- Name: collection_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.collection_events (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    request_id uuid NOT NULL,
    operation character varying(100) NOT NULL,
    payload_hash character varying(64) NOT NULL,
    token_delta bigint NOT NULL,
    receipt jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    gem_delta bigint DEFAULT '0'::bigint NOT NULL,
    CONSTRAINT ck_collection_events_gem_delta CHECK (((gem_delta <= 0) AND ((token_delta = 0) OR (gem_delta = 0)))),
    CONSTRAINT ck_collection_events_token_delta CHECK ((token_delta <= 0))
);


--
-- Name: daily_item_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_item_grants (
    owner_id uuid NOT NULL,
    plant_id uuid NOT NULL,
    game_date date NOT NULL,
    family character varying(100) NOT NULL,
    awarded bigint NOT NULL,
    boundary timestamp with time zone NOT NULL,
    provenance jsonb NOT NULL,
    CONSTRAINT ck_daily_item_grants_amount CHECK ((awarded > 0))
);


--
-- Name: daily_item_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_item_state (
    garden_id uuid NOT NULL,
    settled_at timestamp with time zone NOT NULL
);


--
-- Name: daily_skill_activity; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.daily_skill_activity (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    flights bigint NOT NULL,
    CONSTRAINT ck_daily_skill_activity_flights CHECK ((flights >= 0))
);


--
-- Name: economy_configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.economy_configs (
    version character varying(100) NOT NULL,
    effective_at timestamp with time zone NOT NULL,
    is_fixture boolean NOT NULL,
    rules jsonb NOT NULL,
    CONSTRAINT ck_economy_configs_rules_object CHECK ((jsonb_typeof(rules) = 'object'::text))
);


--
-- Name: exchange_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.exchange_offers (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    pack_id character varying(100) NOT NULL,
    pack_version integer NOT NULL,
    token_cost bigint NOT NULL,
    active boolean NOT NULL,
    currency character varying(10) DEFAULT 'tokens'::character varying NOT NULL,
    CONSTRAINT ck_exchange_offers_amounts CHECK (((version > 0) AND (token_cost > 0))),
    CONSTRAINT ck_exchange_offers_currency CHECK (((currency)::text = ANY ((ARRAY['tokens'::character varying, 'gems'::character varying])::text[])))
);


--
-- Name: expedition_bonus_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_bonus_grants (
    entitlement_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    amount bigint NOT NULL,
    CONSTRAINT ck_expedition_bonus_grants_amount CHECK ((amount > 0))
);


--
-- Name: expedition_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_claims (
    entitlement_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    receipt jsonb NOT NULL
);


--
-- Name: expedition_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_days (
    run_id uuid NOT NULL,
    device_id uuid NOT NULL,
    game_date date NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    steps bigint NOT NULL,
    steps_through timestamp with time zone,
    workouts_through timestamp with time zone,
    CONSTRAINT ck_expedition_days_steps CHECK ((steps >= 0))
);


--
-- Name: expedition_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_entitlements (
    id uuid NOT NULL,
    run_id uuid NOT NULL,
    reward_key character varying(100) NOT NULL,
    earned_at timestamp with time zone NOT NULL,
    reward jsonb NOT NULL
);


--
-- Name: expedition_launches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_launches (
    month date NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_expedition_launches_interval CHECK (((starts_at >= ((month)::timestamp without time zone AT TIME ZONE 'UTC'::text)) AND (starts_at < ((month + '1 mon'::interval) AT TIME ZONE 'UTC'::text))))
);


--
-- Name: expedition_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_runs (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    month date NOT NULL,
    template_version character varying(100) NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    evidence_until timestamp with time zone NOT NULL,
    progress_version bigint NOT NULL,
    progress jsonb NOT NULL,
    contributions jsonb NOT NULL
);


--
-- Name: expedition_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_schedule (
    month date NOT NULL,
    template_version character varying(100) NOT NULL,
    published_at timestamp with time zone NOT NULL
);


--
-- Name: expedition_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_templates (
    version character varying(100) NOT NULL,
    definition jsonb NOT NULL,
    published_at timestamp with time zone NOT NULL
);


--
-- Name: expedition_workouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expedition_workouts (
    run_id uuid NOT NULL,
    workout_id uuid NOT NULL,
    payload jsonb NOT NULL,
    intervals jsonb NOT NULL,
    outcome character varying(64) NOT NULL
);


--
-- Name: game_catalogue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.game_catalogue (
    id integer NOT NULL,
    version character varying(100) NOT NULL,
    is_fixture boolean NOT NULL,
    unit_metres numeric(9,3) NOT NULL,
    board_width numeric(9,3) NOT NULL,
    board_depth numeric(9,3) NOT NULL,
    starter_species_id character varying(100) NOT NULL,
    starter_variant_id character varying(100) NOT NULL,
    CONSTRAINT ck_game_catalogue_board_depth CHECK (((board_depth > (0)::numeric) AND (board_depth <> 'NaN'::numeric))),
    CONSTRAINT ck_game_catalogue_board_width CHECK (((board_width > (0)::numeric) AND (board_width <> 'NaN'::numeric))),
    CONSTRAINT ck_game_catalogue_singleton CHECK ((id = 1)),
    CONSTRAINT ck_game_catalogue_unit_metres CHECK (((unit_metres > (0)::numeric) AND (unit_metres <> 'NaN'::numeric)))
);


--
-- Name: game_catalogue_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.game_catalogue_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: game_catalogue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.game_catalogue_id_seq OWNED BY public.game_catalogue.id;


--
-- Name: garden_placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.garden_placements (
    plant_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    garden_id uuid NOT NULL,
    x numeric(9,3) NOT NULL,
    y numeric(9,3) NOT NULL,
    rotation_degrees numeric(5,2) NOT NULL,
    CONSTRAINT ck_garden_placements_rotation CHECK (((rotation_degrees >= (0)::numeric) AND (rotation_degrees < (360)::numeric))),
    CONSTRAINT ck_garden_placements_x CHECK (((x >= (0)::numeric) AND (x <> 'NaN'::numeric))),
    CONSTRAINT ck_garden_placements_y CHECK (((y >= (0)::numeric) AND (y <> 'NaN'::numeric)))
);


--
-- Name: garden_visitor_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.garden_visitor_state (
    garden_id uuid NOT NULL,
    settled_at timestamp with time zone NOT NULL,
    context_id uuid NOT NULL,
    stored_whole bigint NOT NULL,
    remainder jsonb NOT NULL,
    last_slot bigint NOT NULL,
    gap_slots integer NOT NULL,
    version bigint NOT NULL,
    ever_issued boolean DEFAULT false NOT NULL,
    CONSTRAINT ck_garden_visitor_state_amounts CHECK (((stored_whole >= 0) AND (version >= 0) AND (gap_slots >= 0)))
);


--
-- Name: gardens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gardens (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    width numeric(9,3) NOT NULL,
    depth numeric(9,3) NOT NULL,
    visibility character varying(16) DEFAULT 'friends'::character varying NOT NULL,
    layout_version bigint DEFAULT '0'::bigint NOT NULL,
    state_version bigint DEFAULT '0'::bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_gardens_depth CHECK (((depth > (0)::numeric) AND (depth <> 'NaN'::numeric))),
    CONSTRAINT ck_gardens_versions CHECK (((layout_version >= 0) AND (state_version >= 0))),
    CONSTRAINT ck_gardens_visibility CHECK (((visibility)::text = ANY ((ARRAY['friends'::character varying, 'private'::character varying])::text[]))),
    CONSTRAINT ck_gardens_width CHECK (((width > (0)::numeric) AND (width <> 'NaN'::numeric)))
);


--
-- Name: gem_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.gem_grants (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    source_id uuid NOT NULL,
    kind character varying(16) NOT NULL,
    rules_version character varying(64) NOT NULL,
    start_milestone bigint NOT NULL,
    end_milestone bigint NOT NULL,
    amount bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_gem_grants_amounts CHECK (((start_milestone >= 0) AND (end_milestone > start_milestone) AND (amount = (end_milestone - start_milestone)))),
    CONSTRAINT ck_gem_grants_kind CHECK (((kind)::text = ANY ((ARRAY['steps'::character varying, 'backfill'::character varying])::text[])))
);


--
-- Name: growth_day_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.growth_day_summaries (
    plant_id uuid NOT NULL,
    day date NOT NULL,
    rule_version character varying(100) NOT NULL,
    profile_key character varying(64) NOT NULL,
    profiles jsonb NOT NULL,
    awarded bigint NOT NULL,
    skill_bonus bigint NOT NULL,
    credit_count bigint NOT NULL,
    CONSTRAINT ck_growth_day_summaries_amounts CHECK (((awarded >= 0) AND (credit_count > 0)))
);


--
-- Name: growth_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.growth_profiles (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    thresholds jsonb NOT NULL,
    maximum_growth_micro_units bigint NOT NULL,
    CONSTRAINT ck_growth_profiles_maximum CHECK ((maximum_growth_micro_units > 0)),
    CONSTRAINT ck_growth_profiles_thresholds_object CHECK ((jsonb_typeof(thresholds) = 'object'::text)),
    CONSTRAINT ck_growth_profiles_version CHECK ((version > 0))
);


--
-- Name: growth_provenance; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.growth_provenance (
    id character varying(64) NOT NULL,
    payload jsonb NOT NULL
);


--
-- Name: growth_rule_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.growth_rule_profiles (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    rules jsonb NOT NULL,
    CONSTRAINT ck_growth_rule_profiles_rules_object CHECK ((jsonb_typeof(rules) = 'object'::text)),
    CONSTRAINT ck_growth_rule_profiles_version CHECK ((version > 0))
);


--
-- Name: item_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_definitions (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    display_name character varying(100) NOT NULL,
    description text NOT NULL,
    rarity character varying(32) NOT NULL,
    asset_version character varying(100) NOT NULL,
    model_key text NOT NULL,
    thumbnail_key text NOT NULL,
    clearance_radius numeric(9,3) NOT NULL,
    CONSTRAINT ck_item_definitions_radius CHECK (((clearance_radius > (0)::numeric) AND (clearance_radius <> 'NaN'::numeric))),
    CONSTRAINT ck_item_definitions_rarity CHECK (((rarity)::text = ANY ((ARRAY['common'::character varying, 'rare'::character varying, 'epic'::character varying, 'legendary'::character varying])::text[]))),
    CONSTRAINT ck_item_definitions_version CHECK ((version > 0))
);


--
-- Name: item_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_identities (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    item_id character varying(100) NOT NULL,
    item_version integer NOT NULL,
    source character varying(64) NOT NULL,
    reference character varying(255) NOT NULL,
    ordinal integer NOT NULL,
    acquired_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_item_identities_ordinal CHECK ((ordinal >= 0))
);


--
-- Name: item_placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_placements (
    item_id uuid NOT NULL,
    owner_id uuid NOT NULL,
    garden_id uuid NOT NULL,
    x numeric(9,3) NOT NULL,
    y numeric(9,3) NOT NULL,
    rotation_degrees numeric(5,2) NOT NULL,
    CONSTRAINT ck_item_placements_rotation CHECK (((rotation_degrees >= (0)::numeric) AND (rotation_degrees < (360)::numeric))),
    CONSTRAINT ck_item_placements_x CHECK (((x >= (0)::numeric) AND (x <> 'NaN'::numeric))),
    CONSTRAINT ck_item_placements_y CHECK (((y >= (0)::numeric) AND (y <> 'NaN'::numeric)))
);


--
-- Name: item_sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_sales (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    owned_item_id uuid NOT NULL,
    request_id uuid NOT NULL,
    payload_hash character varying(64) NOT NULL,
    tokens bigint NOT NULL,
    receipt jsonb NOT NULL,
    sold_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_item_sales_tokens CHECK ((tokens > 0))
);


--
-- Name: item_shop_offers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_shop_offers (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    item_id character varying(100) NOT NULL,
    item_version integer NOT NULL,
    token_cost bigint NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT ck_item_shop_offers_value CHECK (((version > 0) AND (token_cost >= 4)))
);


--
-- Name: item_skill_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_skill_bindings (
    item_id character varying(100) NOT NULL,
    item_version integer NOT NULL,
    profile_id character varying(100) NOT NULL,
    profile_version integer NOT NULL
);


--
-- Name: item_skill_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_skill_profiles (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    rules jsonb NOT NULL
);


--
-- Name: item_step_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_step_grants (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    family character varying(100) NOT NULL,
    tier bigint NOT NULL,
    boundary timestamp with time zone NOT NULL,
    provenance jsonb NOT NULL
);


--
-- Name: item_step_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_step_state (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    family character varying(100) NOT NULL,
    steps bigint NOT NULL,
    CONSTRAINT ck_item_step_state_steps CHECK ((steps >= 0))
);


--
-- Name: item_valuations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_valuations (
    owned_item_id uuid NOT NULL,
    valuation_version character varying(100) NOT NULL,
    token_value bigint NOT NULL,
    resale_basis_points integer NOT NULL,
    CONSTRAINT ck_item_valuations_value CHECK (((token_value >= 4) AND (resale_basis_points = 2500)))
);


--
-- Name: item_value_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.item_value_definitions (
    item_id character varying(100) NOT NULL,
    item_version integer NOT NULL,
    valuation_version character varying(100) NOT NULL,
    token_value bigint NOT NULL,
    resale_basis_points integer NOT NULL,
    CONSTRAINT ck_item_value_definitions_value CHECK (((token_value >= 4) AND (resale_basis_points = 2500)))
);


--
-- Name: level_benefits_policy; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.level_benefits_policy (
    version character varying(64) NOT NULL,
    effective_at timestamp with time zone NOT NULL
);


--
-- Name: level_up_notices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.level_up_notices (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    source_id uuid NOT NULL,
    from_level bigint NOT NULL,
    to_level bigint NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    consumed_at timestamp with time zone,
    claim_id uuid,
    installation_id uuid,
    CONSTRAINT ck_level_up_notices_claim CHECK ((((consumed_at IS NULL) AND (claim_id IS NULL) AND (installation_id IS NULL)) OR ((consumed_at IS NOT NULL) AND (claim_id IS NOT NULL) AND (installation_id IS NOT NULL)))),
    CONSTRAINT ck_level_up_notices_levels CHECK (((from_level >= 1) AND (to_level > from_level)))
);


--
-- Name: milestone_bonus_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_bonus_grants (
    owner_id uuid NOT NULL,
    milestone_id character varying(64) NOT NULL,
    amount bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_milestone_bonus_grants_amount CHECK ((amount > 0))
);


--
-- Name: milestone_claims; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_claims (
    owner_id uuid NOT NULL,
    milestone_id character varying(100) NOT NULL,
    claimed_at timestamp with time zone NOT NULL,
    reward_tokens bigint NOT NULL,
    receipt jsonb NOT NULL
);


--
-- Name: milestone_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_days (
    owner_id uuid NOT NULL,
    game_date date NOT NULL,
    steps bigint NOT NULL,
    workout_minutes text NOT NULL,
    active boolean NOT NULL,
    CONSTRAINT ck_milestone_days_steps CHECK ((steps >= 0))
);


--
-- Name: milestone_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_entitlements (
    owner_id uuid NOT NULL,
    milestone_id character varying(64) NOT NULL,
    policy_version character varying(64) NOT NULL,
    earned_at timestamp with time zone NOT NULL,
    definition jsonb NOT NULL,
    superseded_by character varying(64),
    legacy_id character varying(100)
);


--
-- Name: milestone_event_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_event_state (
    owner_id uuid NOT NULL,
    event_id character varying(32) NOT NULL,
    progress jsonb NOT NULL
);


--
-- Name: milestone_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_events (
    event_id character varying(32) NOT NULL,
    policy_version character varying(64) NOT NULL,
    name character varying(100) NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    claim_until timestamp with time zone NOT NULL,
    definition jsonb NOT NULL
);


--
-- Name: milestone_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_policies (
    version character varying(64) NOT NULL,
    effective_at timestamp with time zone NOT NULL,
    active boolean NOT NULL,
    definition jsonb NOT NULL
);


--
-- Name: milestone_species; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_species (
    owner_id uuid NOT NULL,
    species_id character varying(100) NOT NULL,
    rarity character varying(32) NOT NULL
);


--
-- Name: milestone_state; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.milestone_state (
    owner_id uuid NOT NULL,
    policy_version character varying(64) NOT NULL,
    enrolled_at timestamp with time zone NOT NULL,
    progress jsonb NOT NULL
);


--
-- Name: owned_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owned_items (
    id uuid NOT NULL,
    owner_id uuid NOT NULL
);


--
-- Name: owned_packs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owned_packs (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    pack_id character varying(100) NOT NULL,
    pack_version integer NOT NULL,
    exchange_id uuid NOT NULL,
    acquired_at timestamp with time zone NOT NULL
);


--
-- Name: owned_plants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owned_plants (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    species_id character varying(100) NOT NULL,
    variant_id character varying(100) NOT NULL,
    growth_profile_id character varying(100) NOT NULL,
    growth_profile_version integer NOT NULL,
    behaviour_profile_id character varying(100) NOT NULL,
    behaviour_profile_version integer NOT NULL,
    attraction_profile_id character varying(100) NOT NULL,
    attraction_profile_version integer NOT NULL,
    growth_micro_units bigint DEFAULT '0'::bigint NOT NULL,
    fractional_state jsonb DEFAULT '{}'::jsonb NOT NULL,
    acquisition_source character varying(64) NOT NULL,
    acquisition_reference character varying(255) NOT NULL,
    first_matured_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    clearance_radius numeric(9,3) NOT NULL,
    CONSTRAINT ck_owned_plants_fractional_object CHECK ((jsonb_typeof(fractional_state) = 'object'::text)),
    CONSTRAINT ck_owned_plants_growth CHECK ((growth_micro_units >= 0)),
    CONSTRAINT ck_owned_plants_radius CHECK (((clearance_radius > (0)::numeric) AND (clearance_radius <> 'NaN'::numeric)))
);


--
-- Name: pack_definitions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pack_definitions (
    id character varying(100) NOT NULL,
    version integer NOT NULL,
    is_fixture boolean NOT NULL,
    definition jsonb NOT NULL,
    CONSTRAINT ck_pack_definitions_version CHECK ((version > 0))
);


--
-- Name: pack_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pack_members (
    pack_id character varying(100) NOT NULL,
    pack_version integer NOT NULL,
    species_id character varying(100) NOT NULL,
    variant_id character varying(100) NOT NULL,
    growth_profile_id character varying(100) NOT NULL,
    growth_profile_version integer NOT NULL,
    behaviour_profile_id character varying(100) NOT NULL,
    behaviour_profile_version integer NOT NULL,
    attraction_profile_id character varying(100) NOT NULL,
    attraction_profile_version integer NOT NULL
);


--
-- Name: pack_openings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pack_openings (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    pack_id uuid NOT NULL,
    event_id uuid NOT NULL,
    plant_id uuid NOT NULL,
    rarity character varying(32) NOT NULL,
    opened_at timestamp with time zone NOT NULL
);


--
-- Name: plant_growth_credits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_growth_credits (
    plant_id uuid NOT NULL,
    activity_credit_id uuid NOT NULL,
    before_growth bigint NOT NULL,
    after_growth bigint NOT NULL,
    context jsonb NOT NULL,
    provenance_id character varying(64),
    CONSTRAINT ck_plant_growth_credits_growth CHECK (((before_growth >= 0) AND (after_growth >= before_growth)))
);


--
-- Name: plant_identities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_identities (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    acquisition_source character varying(64) NOT NULL,
    acquisition_reference character varying(255) NOT NULL,
    valuation_version character varying(100) NOT NULL,
    valuation_rarity character varying(32),
    variant_basis_points integer
);


--
-- Name: plant_sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_sales (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    plant_id uuid NOT NULL,
    request_id uuid NOT NULL,
    payload_hash character varying(64) NOT NULL,
    tokens bigint NOT NULL,
    receipt jsonb NOT NULL,
    sold_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_plant_sales_tokens CHECK ((tokens > 0))
);


--
-- Name: plant_species; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_species (
    id character varying(100) NOT NULL,
    display_name character varying(100) NOT NULL,
    description text NOT NULL,
    clearance_radius numeric(9,3) NOT NULL,
    growth_profile_id character varying(100) NOT NULL,
    growth_profile_version integer NOT NULL,
    behaviour_profile_id character varying(100) NOT NULL,
    behaviour_profile_version integer NOT NULL,
    attraction_profile_id character varying(100) NOT NULL,
    attraction_profile_version integer NOT NULL,
    enabled boolean NOT NULL,
    is_fixture boolean DEFAULT false NOT NULL,
    properties jsonb DEFAULT '{}'::jsonb NOT NULL,
    rarity character varying(32) DEFAULT 'development_unbalanced'::character varying NOT NULL,
    CONSTRAINT ck_plant_species_clearance_radius CHECK (((clearance_radius > (0)::numeric) AND (clearance_radius <> 'NaN'::numeric))),
    CONSTRAINT ck_plant_species_rarity CHECK (((rarity)::text ~ '^[a-z][a-z0-9_]{0,31}$'::text))
);


--
-- Name: plant_stages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_stages (
    species_id character varying(100) NOT NULL,
    variant_id character varying(100) NOT NULL,
    stage character varying(16) NOT NULL,
    model_key text NOT NULL,
    thumbnail_key text NOT NULL,
    CONSTRAINT ck_plant_stages_stage CHECK (((stage)::text = ANY ((ARRAY['sprout'::character varying, 'seedling'::character varying, 'young'::character varying, 'adult'::character varying])::text[])))
);


--
-- Name: plant_variants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.plant_variants (
    species_id character varying(100) NOT NULL,
    variant_id character varying(100) NOT NULL,
    display_name character varying(100) NOT NULL,
    description text NOT NULL,
    rarity character varying(32) NOT NULL,
    enabled boolean NOT NULL,
    asset_catalog_key text NOT NULL,
    asset_catalog_version character varying(100) NOT NULL,
    growth_profile_id character varying(100),
    growth_profile_version integer,
    behaviour_profile_id character varying(100),
    behaviour_profile_version integer,
    attraction_profile_id character varying(100),
    attraction_profile_version integer,
    CONSTRAINT ck_plant_variants_attraction_override_pair CHECK (((attraction_profile_id IS NULL) = (attraction_profile_version IS NULL))),
    CONSTRAINT ck_plant_variants_behaviour_override_pair CHECK (((behaviour_profile_id IS NULL) = (behaviour_profile_version IS NULL))),
    CONSTRAINT ck_plant_variants_growth_override_pair CHECK (((growth_profile_id IS NULL) = (growth_profile_version IS NULL)))
);


--
-- Name: player_progress; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_progress (
    owner_id uuid NOT NULL,
    activity_steps bigint NOT NULL,
    first_maturity_count bigint NOT NULL,
    last_sync_at timestamp with time zone,
    activity_metrics jsonb DEFAULT '{}'::jsonb NOT NULL,
    first_seedling_at timestamp with time zone,
    progression_version bigint DEFAULT '0'::bigint NOT NULL,
    CONSTRAINT ck_player_progress_counters CHECK (((activity_steps >= 0) AND (first_maturity_count >= 0))),
    CONSTRAINT ck_player_progress_progression_version CHECK ((progression_version >= 0))
);


--
-- Name: reward_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reward_events (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    request_id uuid NOT NULL,
    accepted_at timestamp with time zone NOT NULL,
    payload jsonb NOT NULL
);


--
-- Name: reward_recaps; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reward_recaps (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    event_id uuid NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone NOT NULL,
    acknowledged_at timestamp with time zone
);


--
-- Name: runtime_control; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.runtime_control (
    id integer NOT NULL,
    maintenance boolean DEFAULT false NOT NULL,
    release text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_runtime_control_singleton CHECK ((id = 1))
);


--
-- Name: runtime_control_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.runtime_control_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: runtime_control_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.runtime_control_id_seq OWNED BY public.runtime_control.id;


--
-- Name: shop_allowances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_allowances (
    owner_id uuid NOT NULL,
    offer_id character varying(100) NOT NULL,
    offer_version integer NOT NULL,
    purchased integer NOT NULL,
    CONSTRAINT ck_shop_allowances_quantity CHECK ((purchased > 0))
);


--
-- Name: shop_days; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_days (
    shop_date date NOT NULL,
    week_start date NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL
);


--
-- Name: shop_offer_windows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_offer_windows (
    offer_id character varying(100) NOT NULL,
    offer_version integer NOT NULL,
    shop_date date NOT NULL,
    slot character varying(20) NOT NULL,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone NOT NULL,
    purchase_limit integer,
    CONSTRAINT ck_shop_offer_windows_interval CHECK (((ends_at > starts_at) AND ((purchase_limit IS NULL) OR (purchase_limit > 0))))
);


--
-- Name: shop_releases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_releases (
    version character varying(100) NOT NULL,
    effective_week date NOT NULL,
    catalogue jsonb NOT NULL,
    policy jsonb NOT NULL,
    published_at timestamp with time zone NOT NULL
);


--
-- Name: shop_weeks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shop_weeks (
    week_start date NOT NULL,
    release_version character varying(100) NOT NULL,
    seed character varying(64) NOT NULL,
    plan jsonb NOT NULL
);


--
-- Name: skill_policies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.skill_policies (
    version character varying(100) NOT NULL,
    rules jsonb NOT NULL,
    CONSTRAINT ck_skill_policies_rules_object CHECK ((jsonb_typeof(rules) = 'object'::text))
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    auth_issuer text NOT NULL,
    auth_subject character varying(255) NOT NULL,
    username character varying(32) NOT NULL,
    display_name character varying(64) NOT NULL,
    game_timezone character varying(64) NOT NULL,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ck_users_display_name CHECK (((char_length(btrim((display_name)::text)) >= 1) AND (char_length(btrim((display_name)::text)) <= 64))),
    CONSTRAINT ck_users_status CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'disabled'::character varying])::text[]))),
    CONSTRAINT ck_users_username_format CHECK (((username)::text ~ '^[a-z0-9_]{3,32}$'::text))
);


--
-- Name: visitor_contexts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_contexts (
    id uuid NOT NULL,
    garden_id uuid NOT NULL,
    effective_at timestamp with time zone NOT NULL,
    rule_version character varying(100) NOT NULL,
    snapshot jsonb NOT NULL
);


--
-- Name: visitor_controls; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_controls (
    owner_id uuid NOT NULL,
    sequence bigint NOT NULL,
    request_id uuid,
    operation character varying(100),
    payload_hash character varying(64),
    accepted_at timestamp with time zone,
    CONSTRAINT ck_visitor_controls_sequence CHECK ((sequence >= 0))
);


--
-- Name: visitor_day_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_day_summaries (
    garden_id uuid NOT NULL,
    day date NOT NULL,
    rule_version character varying(100) NOT NULL,
    kind character varying(32) NOT NULL,
    microseconds bigint NOT NULL,
    generated jsonb NOT NULL,
    discarded jsonb NOT NULL,
    visits bigint NOT NULL,
    tokens bigint NOT NULL,
    CONSTRAINT ck_visitor_day_summaries_amounts CHECK (((microseconds >= 0) AND (visits >= 0) AND (tokens >= 0)))
);


--
-- Name: visitor_economy_conversions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_economy_conversions (
    owner_id uuid NOT NULL,
    version character varying(100) NOT NULL,
    converted_at timestamp with time zone NOT NULL,
    detail jsonb NOT NULL
);


--
-- Name: visitor_opportunities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_opportunities (
    id uuid NOT NULL,
    garden_id uuid NOT NULL,
    session_id uuid NOT NULL,
    context_id uuid NOT NULL,
    slot bigint NOT NULL,
    issued_at timestamp with time zone NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    rule_version character varying(100) NOT NULL,
    tokens bigint NOT NULL,
    status character varying(16) NOT NULL,
    result jsonb,
    CONSTRAINT ck_visitor_opportunities_status_reward CHECK (((tokens > 0) AND ((status)::text = ANY ((ARRAY['issued'::character varying, 'welcomed'::character varying, 'expired'::character varying])::text[]))))
);


--
-- Name: visitor_reward_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_reward_events (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    kind character varying(32) NOT NULL,
    source_id uuid NOT NULL,
    created_at timestamp with time zone NOT NULL,
    detail jsonb NOT NULL,
    receipt jsonb,
    summarized_at timestamp with time zone
);


--
-- Name: visitor_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_rules (
    version character varying(100) NOT NULL,
    effective_at timestamp with time zone NOT NULL,
    is_fixture boolean NOT NULL,
    rules jsonb NOT NULL
);


--
-- Name: visitor_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_schedules (
    garden_id uuid NOT NULL,
    context_id uuid NOT NULL,
    next_at timestamp with time zone,
    remaining jsonb NOT NULL,
    sequence bigint NOT NULL,
    tutorial_used boolean NOT NULL,
    CONSTRAINT ck_visitor_schedules_sequence CHECK ((sequence >= 0))
);


--
-- Name: visitor_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_sessions (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    garden_id uuid NOT NULL,
    installation_id uuid NOT NULL,
    started_at timestamp with time zone NOT NULL,
    lease_expires_at timestamp with time zone NOT NULL,
    ended_at timestamp with time zone,
    arrival_protocol integer DEFAULT 1 NOT NULL,
    CONSTRAINT ck_visitor_sessions_interval CHECK (((lease_expires_at >= started_at) AND ((ended_at IS NULL) OR (ended_at >= started_at))))
);


--
-- Name: visitor_settlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_settlements (
    id uuid NOT NULL,
    garden_id uuid NOT NULL,
    context_id uuid NOT NULL,
    start_at timestamp with time zone NOT NULL,
    end_at timestamp with time zone NOT NULL,
    mode character varying(16) NOT NULL,
    detail jsonb NOT NULL,
    CONSTRAINT ck_visitor_settlements_interval CHECK ((end_at > start_at))
);


--
-- Name: visitor_storage_lots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_storage_lots (
    garden_id uuid NOT NULL,
    rule_version character varying(100) NOT NULL,
    visits bigint NOT NULL,
    tokens_per_visit bigint NOT NULL,
    CONSTRAINT ck_visitor_storage_lots_amounts CHECK (((visits >= 0) AND (tokens_per_visit > 0)))
);


--
-- Name: visitor_throttles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_throttles (
    owner_id uuid NOT NULL,
    window_at timestamp with time zone NOT NULL,
    requests integer NOT NULL
);


--
-- Name: visitor_wallet_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_wallet_entries (
    id uuid NOT NULL,
    owner_id uuid NOT NULL,
    event_id uuid NOT NULL,
    amount bigint NOT NULL,
    created_at timestamp with time zone NOT NULL,
    CONSTRAINT ck_visitor_wallet_entries_amount CHECK ((amount > 0))
);


--
-- Name: visitor_wallets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.visitor_wallets (
    owner_id uuid NOT NULL,
    tokens bigint NOT NULL,
    hosted_active bigint NOT NULL,
    hosted_offline bigint NOT NULL,
    economy_version bigint DEFAULT '0'::bigint NOT NULL,
    gems bigint DEFAULT '0'::bigint NOT NULL,
    lifetime_gems_earned bigint DEFAULT '0'::bigint NOT NULL,
    progression_initialized boolean DEFAULT false NOT NULL,
    step_gems_earned bigint DEFAULT '0'::bigint NOT NULL,
    CONSTRAINT ck_visitor_wallets_amounts CHECK (((tokens >= 0) AND (hosted_active >= 0) AND (hosted_offline >= 0))),
    CONSTRAINT ck_visitor_wallets_economy_version CHECK ((economy_version >= 0)),
    CONSTRAINT ck_visitor_wallets_gem_amounts CHECK (((gems >= 0) AND (lifetime_gems_earned >= gems))),
    CONSTRAINT ck_visitor_wallets_step_gems CHECK (((step_gems_earned >= 0) AND (step_gems_earned <= lifetime_gems_earned)))
);


--
-- Name: game_catalogue id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.game_catalogue ALTER COLUMN id SET DEFAULT nextval('public.game_catalogue_id_seq'::regclass);


--
-- Name: runtime_control id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_control ALTER COLUMN id SET DEFAULT nextval('public.runtime_control_id_seq'::regclass);


--
-- Name: account_level_state pk_account_level_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_level_state
    ADD CONSTRAINT pk_account_level_state PRIMARY KEY (owner_id);


--
-- Name: activity_credits pk_activity_credits; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT pk_activity_credits PRIMARY KEY (id);


--
-- Name: activity_days pk_activity_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_days
    ADD CONSTRAINT pk_activity_days PRIMARY KEY (owner_id, game_date);


--
-- Name: activity_devices pk_activity_devices; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_devices
    ADD CONSTRAINT pk_activity_devices PRIMARY KEY (id);


--
-- Name: activity_metric_days pk_activity_metric_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_metric_days
    ADD CONSTRAINT pk_activity_metric_days PRIMARY KEY (owner_id, game_date, metric);


--
-- Name: activity_workout_days pk_activity_workout_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_workout_days
    ADD CONSTRAINT pk_activity_workout_days PRIMARY KEY (owner_id, game_date);


--
-- Name: activity_workouts pk_activity_workouts; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_workouts
    ADD CONSTRAINT pk_activity_workouts PRIMARY KEY (owner_id, workout_id);


--
-- Name: api_requests pk_api_requests; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_requests
    ADD CONSTRAINT pk_api_requests PRIMARY KEY (user_id, request_id);


--
-- Name: attraction_profiles pk_attraction_profiles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attraction_profiles
    ADD CONSTRAINT pk_attraction_profiles PRIMARY KEY (id, version);


--
-- Name: catalog_discovery_state pk_catalog_discovery_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_discovery_state
    ADD CONSTRAINT pk_catalog_discovery_state PRIMARY KEY (owner_id);


--
-- Name: catalog_stage_discoveries pk_catalog_stage_discoveries; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_stage_discoveries
    ADD CONSTRAINT pk_catalog_stage_discoveries PRIMARY KEY (owner_id, species_id, variant_id, stage);


--
-- Name: collection_events pk_collection_events; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collection_events
    ADD CONSTRAINT pk_collection_events PRIMARY KEY (id);


--
-- Name: daily_item_grants pk_daily_item_grants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_item_grants
    ADD CONSTRAINT pk_daily_item_grants PRIMARY KEY (owner_id, plant_id, game_date, family);


--
-- Name: daily_item_state pk_daily_item_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_item_state
    ADD CONSTRAINT pk_daily_item_state PRIMARY KEY (garden_id);


--
-- Name: daily_skill_activity pk_daily_skill_activity; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_skill_activity
    ADD CONSTRAINT pk_daily_skill_activity PRIMARY KEY (owner_id, game_date);


--
-- Name: economy_configs pk_economy_configs; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.economy_configs
    ADD CONSTRAINT pk_economy_configs PRIMARY KEY (version);


--
-- Name: exchange_offers pk_exchange_offers; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_offers
    ADD CONSTRAINT pk_exchange_offers PRIMARY KEY (id, version);


--
-- Name: expedition_bonus_grants pk_expedition_bonus_grants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_bonus_grants
    ADD CONSTRAINT pk_expedition_bonus_grants PRIMARY KEY (entitlement_id);


--
-- Name: expedition_claims pk_expedition_claims; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_claims
    ADD CONSTRAINT pk_expedition_claims PRIMARY KEY (entitlement_id);


--
-- Name: expedition_days pk_expedition_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_days
    ADD CONSTRAINT pk_expedition_days PRIMARY KEY (run_id, device_id, game_date);


--
-- Name: expedition_entitlements pk_expedition_entitlements; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_entitlements
    ADD CONSTRAINT pk_expedition_entitlements PRIMARY KEY (id);


--
-- Name: expedition_launches pk_expedition_launches; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_launches
    ADD CONSTRAINT pk_expedition_launches PRIMARY KEY (month);


--
-- Name: expedition_runs pk_expedition_runs; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_runs
    ADD CONSTRAINT pk_expedition_runs PRIMARY KEY (id);


--
-- Name: expedition_schedule pk_expedition_schedule; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_schedule
    ADD CONSTRAINT pk_expedition_schedule PRIMARY KEY (month);


--
-- Name: expedition_templates pk_expedition_templates; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_templates
    ADD CONSTRAINT pk_expedition_templates PRIMARY KEY (version);


--
-- Name: expedition_workouts pk_expedition_workouts; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_workouts
    ADD CONSTRAINT pk_expedition_workouts PRIMARY KEY (run_id, workout_id);


--
-- Name: game_catalogue pk_game_catalogue; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.game_catalogue
    ADD CONSTRAINT pk_game_catalogue PRIMARY KEY (id);


--
-- Name: garden_placements pk_garden_placements; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_placements
    ADD CONSTRAINT pk_garden_placements PRIMARY KEY (plant_id);


--
-- Name: garden_visitor_state pk_garden_visitor_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_visitor_state
    ADD CONSTRAINT pk_garden_visitor_state PRIMARY KEY (garden_id);


--
-- Name: gardens pk_gardens; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gardens
    ADD CONSTRAINT pk_gardens PRIMARY KEY (id);


--
-- Name: gem_grants pk_gem_grants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gem_grants
    ADD CONSTRAINT pk_gem_grants PRIMARY KEY (id);


--
-- Name: growth_day_summaries pk_growth_day_summaries; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_day_summaries
    ADD CONSTRAINT pk_growth_day_summaries PRIMARY KEY (plant_id, day, rule_version, profile_key);


--
-- Name: growth_profiles pk_growth_profiles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_profiles
    ADD CONSTRAINT pk_growth_profiles PRIMARY KEY (id, version);


--
-- Name: growth_provenance pk_growth_provenance; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_provenance
    ADD CONSTRAINT pk_growth_provenance PRIMARY KEY (id);


--
-- Name: growth_rule_profiles pk_growth_rule_profiles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_rule_profiles
    ADD CONSTRAINT pk_growth_rule_profiles PRIMARY KEY (id, version);


--
-- Name: item_definitions pk_item_definitions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_definitions
    ADD CONSTRAINT pk_item_definitions PRIMARY KEY (id, version);


--
-- Name: item_identities pk_item_identities; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_identities
    ADD CONSTRAINT pk_item_identities PRIMARY KEY (id);


--
-- Name: item_placements pk_item_placements; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_placements
    ADD CONSTRAINT pk_item_placements PRIMARY KEY (item_id);


--
-- Name: item_sales pk_item_sales; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_sales
    ADD CONSTRAINT pk_item_sales PRIMARY KEY (id);


--
-- Name: item_shop_offers pk_item_shop_offers; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_shop_offers
    ADD CONSTRAINT pk_item_shop_offers PRIMARY KEY (id, version);


--
-- Name: item_skill_bindings pk_item_skill_bindings; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_skill_bindings
    ADD CONSTRAINT pk_item_skill_bindings PRIMARY KEY (item_id, item_version);


--
-- Name: item_skill_profiles pk_item_skill_profiles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_skill_profiles
    ADD CONSTRAINT pk_item_skill_profiles PRIMARY KEY (id, version);


--
-- Name: item_step_grants pk_item_step_grants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_step_grants
    ADD CONSTRAINT pk_item_step_grants PRIMARY KEY (owner_id, game_date, family, tier);


--
-- Name: item_step_state pk_item_step_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_step_state
    ADD CONSTRAINT pk_item_step_state PRIMARY KEY (owner_id, game_date, family);


--
-- Name: item_valuations pk_item_valuations; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_valuations
    ADD CONSTRAINT pk_item_valuations PRIMARY KEY (owned_item_id);


--
-- Name: item_value_definitions pk_item_value_definitions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_value_definitions
    ADD CONSTRAINT pk_item_value_definitions PRIMARY KEY (item_id, item_version);


--
-- Name: level_benefits_policy pk_level_benefits_policy; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.level_benefits_policy
    ADD CONSTRAINT pk_level_benefits_policy PRIMARY KEY (version);


--
-- Name: level_up_notices pk_level_up_notices; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.level_up_notices
    ADD CONSTRAINT pk_level_up_notices PRIMARY KEY (id);


--
-- Name: milestone_bonus_grants pk_milestone_bonus_grants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_bonus_grants
    ADD CONSTRAINT pk_milestone_bonus_grants PRIMARY KEY (owner_id, milestone_id);


--
-- Name: milestone_claims pk_milestone_claims; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_claims
    ADD CONSTRAINT pk_milestone_claims PRIMARY KEY (owner_id, milestone_id);


--
-- Name: milestone_days pk_milestone_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_days
    ADD CONSTRAINT pk_milestone_days PRIMARY KEY (owner_id, game_date);


--
-- Name: milestone_entitlements pk_milestone_entitlements; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_entitlements
    ADD CONSTRAINT pk_milestone_entitlements PRIMARY KEY (owner_id, milestone_id);


--
-- Name: milestone_event_state pk_milestone_event_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_event_state
    ADD CONSTRAINT pk_milestone_event_state PRIMARY KEY (owner_id, event_id);


--
-- Name: milestone_events pk_milestone_events; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_events
    ADD CONSTRAINT pk_milestone_events PRIMARY KEY (event_id);


--
-- Name: milestone_policies pk_milestone_policies; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_policies
    ADD CONSTRAINT pk_milestone_policies PRIMARY KEY (version);


--
-- Name: milestone_species pk_milestone_species; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_species
    ADD CONSTRAINT pk_milestone_species PRIMARY KEY (owner_id, species_id);


--
-- Name: milestone_state pk_milestone_state; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_state
    ADD CONSTRAINT pk_milestone_state PRIMARY KEY (owner_id);


--
-- Name: owned_items pk_owned_items; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_items
    ADD CONSTRAINT pk_owned_items PRIMARY KEY (id);


--
-- Name: owned_packs pk_owned_packs; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_packs
    ADD CONSTRAINT pk_owned_packs PRIMARY KEY (id);


--
-- Name: owned_plants pk_owned_plants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT pk_owned_plants PRIMARY KEY (id);


--
-- Name: pack_definitions pk_pack_definitions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_definitions
    ADD CONSTRAINT pk_pack_definitions PRIMARY KEY (id, version);


--
-- Name: pack_members pk_pack_members; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT pk_pack_members PRIMARY KEY (pack_id, pack_version, species_id, variant_id);


--
-- Name: pack_openings pk_pack_openings; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT pk_pack_openings PRIMARY KEY (id);


--
-- Name: plant_growth_credits pk_plant_growth_credits; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_growth_credits
    ADD CONSTRAINT pk_plant_growth_credits PRIMARY KEY (plant_id, activity_credit_id);


--
-- Name: plant_identities pk_plant_identities; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_identities
    ADD CONSTRAINT pk_plant_identities PRIMARY KEY (id);


--
-- Name: plant_sales pk_plant_sales; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_sales
    ADD CONSTRAINT pk_plant_sales PRIMARY KEY (id);


--
-- Name: plant_species pk_plant_species; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_species
    ADD CONSTRAINT pk_plant_species PRIMARY KEY (id);


--
-- Name: plant_stages pk_plant_stages; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_stages
    ADD CONSTRAINT pk_plant_stages PRIMARY KEY (species_id, variant_id, stage);


--
-- Name: plant_variants pk_plant_variants; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_variants
    ADD CONSTRAINT pk_plant_variants PRIMARY KEY (species_id, variant_id);


--
-- Name: player_progress pk_player_progress; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.player_progress
    ADD CONSTRAINT pk_player_progress PRIMARY KEY (owner_id);


--
-- Name: reward_events pk_reward_events; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_events
    ADD CONSTRAINT pk_reward_events PRIMARY KEY (id);


--
-- Name: reward_recaps pk_reward_recaps; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_recaps
    ADD CONSTRAINT pk_reward_recaps PRIMARY KEY (id);


--
-- Name: runtime_control pk_runtime_control; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.runtime_control
    ADD CONSTRAINT pk_runtime_control PRIMARY KEY (id);


--
-- Name: shop_allowances pk_shop_allowances; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_allowances
    ADD CONSTRAINT pk_shop_allowances PRIMARY KEY (owner_id, offer_id, offer_version);


--
-- Name: shop_days pk_shop_days; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_days
    ADD CONSTRAINT pk_shop_days PRIMARY KEY (shop_date);


--
-- Name: shop_offer_windows pk_shop_offer_windows; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_offer_windows
    ADD CONSTRAINT pk_shop_offer_windows PRIMARY KEY (offer_id, offer_version);


--
-- Name: shop_releases pk_shop_releases; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_releases
    ADD CONSTRAINT pk_shop_releases PRIMARY KEY (version);


--
-- Name: shop_weeks pk_shop_weeks; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_weeks
    ADD CONSTRAINT pk_shop_weeks PRIMARY KEY (week_start);


--
-- Name: skill_policies pk_skill_policies; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.skill_policies
    ADD CONSTRAINT pk_skill_policies PRIMARY KEY (version);


--
-- Name: users pk_users; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT pk_users PRIMARY KEY (id);


--
-- Name: visitor_contexts pk_visitor_contexts; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_contexts
    ADD CONSTRAINT pk_visitor_contexts PRIMARY KEY (id);


--
-- Name: visitor_controls pk_visitor_controls; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_controls
    ADD CONSTRAINT pk_visitor_controls PRIMARY KEY (owner_id);


--
-- Name: visitor_day_summaries pk_visitor_day_summaries; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_day_summaries
    ADD CONSTRAINT pk_visitor_day_summaries PRIMARY KEY (garden_id, day, rule_version, kind);


--
-- Name: visitor_economy_conversions pk_visitor_economy_conversions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_economy_conversions
    ADD CONSTRAINT pk_visitor_economy_conversions PRIMARY KEY (owner_id, version);


--
-- Name: visitor_opportunities pk_visitor_opportunities; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT pk_visitor_opportunities PRIMARY KEY (id);


--
-- Name: visitor_reward_events pk_visitor_reward_events; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_reward_events
    ADD CONSTRAINT pk_visitor_reward_events PRIMARY KEY (id);


--
-- Name: visitor_rules pk_visitor_rules; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_rules
    ADD CONSTRAINT pk_visitor_rules PRIMARY KEY (version);


--
-- Name: visitor_schedules pk_visitor_schedules; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_schedules
    ADD CONSTRAINT pk_visitor_schedules PRIMARY KEY (garden_id);


--
-- Name: visitor_sessions pk_visitor_sessions; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_sessions
    ADD CONSTRAINT pk_visitor_sessions PRIMARY KEY (id);


--
-- Name: visitor_settlements pk_visitor_settlements; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_settlements
    ADD CONSTRAINT pk_visitor_settlements PRIMARY KEY (id);


--
-- Name: visitor_storage_lots pk_visitor_storage_lots; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_storage_lots
    ADD CONSTRAINT pk_visitor_storage_lots PRIMARY KEY (garden_id, rule_version);


--
-- Name: visitor_throttles pk_visitor_throttles; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_throttles
    ADD CONSTRAINT pk_visitor_throttles PRIMARY KEY (owner_id);


--
-- Name: visitor_wallet_entries pk_visitor_wallet_entries; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallet_entries
    ADD CONSTRAINT pk_visitor_wallet_entries PRIMARY KEY (id);


--
-- Name: visitor_wallets pk_visitor_wallets; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallets
    ADD CONSTRAINT pk_visitor_wallets PRIMARY KEY (owner_id);


--
-- Name: activity_credits uq_activity_credits_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT uq_activity_credits_owner_id UNIQUE (owner_id, game_date, request_id);


--
-- Name: activity_devices uq_activity_devices_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_devices
    ADD CONSTRAINT uq_activity_devices_id UNIQUE (id, owner_id);


--
-- Name: collection_events uq_collection_events_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collection_events
    ADD CONSTRAINT uq_collection_events_owner_id UNIQUE (owner_id, request_id);


--
-- Name: expedition_entitlements uq_expedition_entitlements_run_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_entitlements
    ADD CONSTRAINT uq_expedition_entitlements_run_id UNIQUE (run_id, reward_key);


--
-- Name: expedition_runs uq_expedition_runs_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_runs
    ADD CONSTRAINT uq_expedition_runs_id UNIQUE (id, owner_id);


--
-- Name: expedition_runs uq_expedition_runs_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_runs
    ADD CONSTRAINT uq_expedition_runs_owner_id UNIQUE (owner_id, month);


--
-- Name: gardens uq_gardens_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gardens
    ADD CONSTRAINT uq_gardens_id UNIQUE (id, owner_id);


--
-- Name: gardens uq_gardens_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gardens
    ADD CONSTRAINT uq_gardens_owner_id UNIQUE (owner_id);


--
-- Name: gem_grants uq_gem_grants_milestone; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gem_grants
    ADD CONSTRAINT uq_gem_grants_milestone UNIQUE (owner_id, end_milestone);


--
-- Name: gem_grants uq_gem_grants_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gem_grants
    ADD CONSTRAINT uq_gem_grants_source UNIQUE (owner_id, source_id);


--
-- Name: item_identities uq_item_identities_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_identities
    ADD CONSTRAINT uq_item_identities_id UNIQUE (id, owner_id);


--
-- Name: item_identities uq_item_identities_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_identities
    ADD CONSTRAINT uq_item_identities_owner_id UNIQUE (owner_id, source, reference, ordinal);


--
-- Name: item_sales uq_item_sales_owned_item_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_sales
    ADD CONSTRAINT uq_item_sales_owned_item_id UNIQUE (owned_item_id);


--
-- Name: item_sales uq_item_sales_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_sales
    ADD CONSTRAINT uq_item_sales_owner_id UNIQUE (owner_id, request_id);


--
-- Name: level_up_notices uq_level_notice_claim; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.level_up_notices
    ADD CONSTRAINT uq_level_notice_claim UNIQUE (owner_id, claim_id);


--
-- Name: level_up_notices uq_level_notice_source; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.level_up_notices
    ADD CONSTRAINT uq_level_notice_source UNIQUE (owner_id, source_id);


--
-- Name: owned_items uq_owned_items_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_items
    ADD CONSTRAINT uq_owned_items_id UNIQUE (id, owner_id);


--
-- Name: owned_plants uq_owned_plants_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT uq_owned_plants_id UNIQUE (id, owner_id);


--
-- Name: owned_plants uq_owned_plants_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT uq_owned_plants_owner_id UNIQUE (owner_id, acquisition_source, acquisition_reference);


--
-- Name: pack_openings uq_pack_openings_event_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT uq_pack_openings_event_id UNIQUE (event_id);


--
-- Name: pack_openings uq_pack_openings_pack_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT uq_pack_openings_pack_id UNIQUE (pack_id);


--
-- Name: pack_openings uq_pack_openings_plant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT uq_pack_openings_plant_id UNIQUE (plant_id);


--
-- Name: plant_identities uq_plant_identities_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_identities
    ADD CONSTRAINT uq_plant_identities_id UNIQUE (id, owner_id);


--
-- Name: plant_identities uq_plant_identities_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_identities
    ADD CONSTRAINT uq_plant_identities_owner_id UNIQUE (owner_id, acquisition_source, acquisition_reference);


--
-- Name: plant_sales uq_plant_sales_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_sales
    ADD CONSTRAINT uq_plant_sales_owner_id UNIQUE (owner_id, request_id);


--
-- Name: plant_sales uq_plant_sales_plant_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_sales
    ADD CONSTRAINT uq_plant_sales_plant_id UNIQUE (plant_id);


--
-- Name: reward_events uq_reward_events_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_events
    ADD CONSTRAINT uq_reward_events_owner_id UNIQUE (owner_id, request_id);


--
-- Name: reward_recaps uq_reward_recaps_event_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_recaps
    ADD CONSTRAINT uq_reward_recaps_event_id UNIQUE (event_id);


--
-- Name: shop_offer_windows uq_shop_offer_windows_shop_date; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_offer_windows
    ADD CONSTRAINT uq_shop_offer_windows_shop_date UNIQUE (shop_date, slot);


--
-- Name: shop_releases uq_shop_releases_effective_week; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_releases
    ADD CONSTRAINT uq_shop_releases_effective_week UNIQUE (effective_week);


--
-- Name: users uq_users_auth_issuer; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT uq_users_auth_issuer UNIQUE (auth_issuer, auth_subject);


--
-- Name: visitor_opportunities uq_visitor_opportunities_garden_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT uq_visitor_opportunities_garden_id UNIQUE (garden_id, slot);


--
-- Name: visitor_reward_events uq_visitor_reward_events_owner_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_reward_events
    ADD CONSTRAINT uq_visitor_reward_events_owner_id UNIQUE (owner_id, kind, source_id);


--
-- Name: visitor_settlements uq_visitor_settlements_garden_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_settlements
    ADD CONSTRAINT uq_visitor_settlements_garden_id UNIQUE (garden_id, start_at);


--
-- Name: visitor_wallet_entries uq_visitor_wallet_entries_event_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallet_entries
    ADD CONSTRAINT uq_visitor_wallet_entries_event_id UNIQUE (event_id);


--
-- Name: ix_activity_credits_accepted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_credits_accepted_at ON public.activity_credits USING btree (accepted_at);


--
-- Name: ix_activity_credits_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_credits_owner_id ON public.activity_credits USING btree (owner_id);


--
-- Name: ix_activity_devices_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_activity_devices_owner_id ON public.activity_devices USING btree (owner_id);


--
-- Name: ix_api_requests_response_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_api_requests_response_expires_at ON public.api_requests USING btree (response_expires_at);


--
-- Name: ix_collection_events_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_collection_events_owner_id ON public.collection_events USING btree (owner_id);


--
-- Name: ix_economy_configs_effective_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_economy_configs_effective_at ON public.economy_configs USING btree (effective_at);


--
-- Name: ix_expedition_bonus_grants_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expedition_bonus_grants_owner_id ON public.expedition_bonus_grants USING btree (owner_id);


--
-- Name: ix_expedition_claims_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expedition_claims_owner_id ON public.expedition_claims USING btree (owner_id);


--
-- Name: ix_expedition_entitlements_run_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expedition_entitlements_run_id ON public.expedition_entitlements USING btree (run_id);


--
-- Name: ix_expedition_runs_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_expedition_runs_owner_id ON public.expedition_runs USING btree (owner_id);


--
-- Name: ix_garden_placements_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_garden_placements_garden_id ON public.garden_placements USING btree (garden_id);


--
-- Name: ix_gem_grants_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_gem_grants_owner_id ON public.gem_grants USING btree (owner_id);


--
-- Name: ix_item_identities_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_item_identities_owner_id ON public.item_identities USING btree (owner_id);


--
-- Name: ix_item_placements_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_item_placements_garden_id ON public.item_placements USING btree (garden_id);


--
-- Name: ix_item_sales_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_item_sales_owner_id ON public.item_sales USING btree (owner_id);


--
-- Name: ix_level_up_notices_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_level_up_notices_owner_id ON public.level_up_notices USING btree (owner_id);


--
-- Name: ix_milestone_events_starts_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_milestone_events_starts_at ON public.milestone_events USING btree (starts_at);


--
-- Name: ix_owned_items_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_owned_items_owner_id ON public.owned_items USING btree (owner_id);


--
-- Name: ix_owned_packs_exchange_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_owned_packs_exchange_id ON public.owned_packs USING btree (exchange_id);


--
-- Name: ix_owned_packs_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_owned_packs_owner_id ON public.owned_packs USING btree (owner_id);


--
-- Name: ix_owned_plants_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_owned_plants_owner_id ON public.owned_plants USING btree (owner_id);


--
-- Name: ix_pack_openings_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_pack_openings_owner_id ON public.pack_openings USING btree (owner_id);


--
-- Name: ix_plant_growth_credits_activity_credit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plant_growth_credits_activity_credit_id ON public.plant_growth_credits USING btree (activity_credit_id);


--
-- Name: ix_plant_growth_credits_provenance_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plant_growth_credits_provenance_id ON public.plant_growth_credits USING btree (provenance_id);


--
-- Name: ix_plant_identities_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plant_identities_owner_id ON public.plant_identities USING btree (owner_id);


--
-- Name: ix_plant_sales_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_plant_sales_owner_id ON public.plant_sales USING btree (owner_id);


--
-- Name: ix_reward_events_accepted_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reward_events_accepted_at ON public.reward_events USING btree (accepted_at);


--
-- Name: ix_reward_events_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reward_events_owner_id ON public.reward_events USING btree (owner_id);


--
-- Name: ix_reward_recaps_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reward_recaps_owner_id ON public.reward_recaps USING btree (owner_id);


--
-- Name: ix_reward_recaps_pending_compaction; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_reward_recaps_pending_compaction ON public.reward_recaps USING btree (acknowledged_at) WHERE ((acknowledged_at IS NOT NULL) AND (NOT (payload ? 'compacted'::text)));


--
-- Name: ix_shop_days_week_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_shop_days_week_start ON public.shop_days USING btree (week_start);


--
-- Name: ix_shop_offer_windows_shop_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_shop_offer_windows_shop_date ON public.shop_offer_windows USING btree (shop_date);


--
-- Name: ix_visitor_contexts_effective_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_contexts_effective_at ON public.visitor_contexts USING btree (effective_at);


--
-- Name: ix_visitor_contexts_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_contexts_garden_id ON public.visitor_contexts USING btree (garden_id);


--
-- Name: ix_visitor_opportunities_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_opportunities_expires_at ON public.visitor_opportunities USING btree (expires_at);


--
-- Name: ix_visitor_opportunities_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_opportunities_garden_id ON public.visitor_opportunities USING btree (garden_id);


--
-- Name: ix_visitor_pending; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_pending ON public.visitor_opportunities USING btree (garden_id, expires_at) WHERE ((status)::text = 'issued'::text);


--
-- Name: ix_visitor_reward_events_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_reward_events_owner_id ON public.visitor_reward_events USING btree (owner_id);


--
-- Name: ix_visitor_reward_events_pending_summary; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_reward_events_pending_summary ON public.visitor_reward_events USING btree (created_at) WHERE ((summarized_at IS NULL) AND ((kind)::text = ANY ((ARRAY['active_welcome'::character varying, 'offline_claim'::character varying])::text[])));


--
-- Name: ix_visitor_rules_effective_at; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ix_visitor_rules_effective_at ON public.visitor_rules USING btree (effective_at);


--
-- Name: ix_visitor_sessions_ended_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_sessions_ended_at ON public.visitor_sessions USING btree (ended_at);


--
-- Name: ix_visitor_sessions_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_sessions_garden_id ON public.visitor_sessions USING btree (garden_id);


--
-- Name: ix_visitor_sessions_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_sessions_owner_id ON public.visitor_sessions USING btree (owner_id);


--
-- Name: ix_visitor_settlements_end_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_settlements_end_at ON public.visitor_settlements USING btree (end_at);


--
-- Name: ix_visitor_settlements_garden_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_settlements_garden_id ON public.visitor_settlements USING btree (garden_id);


--
-- Name: ix_visitor_wallet_entries_owner_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_visitor_wallet_entries_owner_id ON public.visitor_wallet_entries USING btree (owner_id);


--
-- Name: uq_activity_active_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_activity_active_owner ON public.activity_devices USING btree (owner_id) WHERE (revoked_at IS NULL);


--
-- Name: uq_exchange_active_offer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_exchange_active_offer ON public.exchange_offers USING btree (id) WHERE active;


--
-- Name: uq_item_shop_active_offer; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_item_shop_active_offer ON public.item_shop_offers USING btree (id) WHERE active;


--
-- Name: uq_milestone_policy_active; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_milestone_policy_active ON public.milestone_policies USING btree (active) WHERE active;


--
-- Name: uq_users_username_normalized; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_users_username_normalized ON public.users USING btree (lower((username)::text));


--
-- Name: uq_visitor_active_garden; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_visitor_active_garden ON public.visitor_sessions USING btree (garden_id) WHERE (ended_at IS NULL);


--
-- Name: uq_visitor_active_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_visitor_active_owner ON public.visitor_sessions USING btree (owner_id) WHERE (ended_at IS NULL);


--
-- Name: collection_events immutable_collection_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_collection_history BEFORE UPDATE ON public.collection_events FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: owned_packs immutable_collection_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_collection_history BEFORE UPDATE ON public.owned_packs FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: pack_definitions immutable_collection_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_collection_history BEFORE UPDATE ON public.pack_definitions FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: pack_members immutable_collection_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_collection_history BEFORE UPDATE ON public.pack_members FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: pack_openings immutable_collection_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_collection_history BEFORE UPDATE ON public.pack_openings FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: economy_configs immutable_config; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_config BEFORE DELETE OR UPDATE ON public.economy_configs FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: activity_credits immutable_credit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_credit BEFORE UPDATE ON public.activity_credits FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: plant_growth_credits immutable_credit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_credit BEFORE UPDATE ON public.plant_growth_credits FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: reward_events immutable_credit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_credit BEFORE UPDATE ON public.reward_events FOR EACH ROW EXECUTE FUNCTION public.forest_compact_growth_event();


--
-- Name: daily_item_grants immutable_daily_item_grants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_daily_item_grants BEFORE DELETE OR UPDATE ON public.daily_item_grants FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_bonus_grants immutable_expedition_bonus_grants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_bonus_grants BEFORE DELETE OR UPDATE ON public.expedition_bonus_grants FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_claims immutable_expedition_claims; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_claims BEFORE DELETE OR UPDATE ON public.expedition_claims FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_entitlements immutable_expedition_entitlements; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_entitlements BEFORE DELETE OR UPDATE ON public.expedition_entitlements FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_launches immutable_expedition_launches; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_launches BEFORE DELETE OR UPDATE ON public.expedition_launches FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_schedule immutable_expedition_schedule; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_schedule BEFORE DELETE OR UPDATE ON public.expedition_schedule FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_templates immutable_expedition_templates; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_templates BEFORE DELETE OR UPDATE ON public.expedition_templates FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: expedition_workouts immutable_expedition_workouts; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_expedition_workouts BEFORE DELETE OR UPDATE ON public.expedition_workouts FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_definitions immutable_item_definitions; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_definitions BEFORE DELETE OR UPDATE ON public.item_definitions FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_identities immutable_item_identities; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_identities BEFORE DELETE OR UPDATE ON public.item_identities FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_shop_offers immutable_item_offer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_offer BEFORE DELETE OR UPDATE ON public.item_shop_offers FOR EACH ROW EXECUTE FUNCTION public.forest_item_offer_immutable();


--
-- Name: item_sales immutable_item_sales; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_sales BEFORE DELETE OR UPDATE ON public.item_sales FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_skill_bindings immutable_item_skill_bindings; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_skill_bindings BEFORE DELETE OR UPDATE ON public.item_skill_bindings FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_skill_profiles immutable_item_skill_profiles; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_skill_profiles BEFORE DELETE OR UPDATE ON public.item_skill_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_step_grants immutable_item_step_grants; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_step_grants BEFORE DELETE OR UPDATE ON public.item_step_grants FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_valuations immutable_item_valuations; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_valuations BEFORE DELETE OR UPDATE ON public.item_valuations FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: item_value_definitions immutable_item_value_definitions; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_item_value_definitions BEFORE DELETE OR UPDATE ON public.item_value_definitions FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: milestone_entitlements immutable_milestone_entitlement; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_milestone_entitlement BEFORE DELETE OR UPDATE ON public.milestone_entitlements FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: milestone_events immutable_milestone_event; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_milestone_event BEFORE DELETE OR UPDATE ON public.milestone_events FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: milestone_policies immutable_milestone_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_milestone_policy BEFORE DELETE OR UPDATE ON public.milestone_policies FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_milestone_policy();


--
-- Name: milestone_species immutable_milestone_species; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_milestone_species BEFORE DELETE OR UPDATE ON public.milestone_species FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: exchange_offers immutable_offer; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_offer BEFORE UPDATE ON public.exchange_offers FOR EACH ROW EXECUTE FUNCTION public.forest_offer_immutable();


--
-- Name: plant_identities immutable_plant_identities; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_plant_identities BEFORE UPDATE ON public.plant_identities FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: plant_sales immutable_plant_sales; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_plant_sales BEFORE UPDATE ON public.plant_sales FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: attraction_profiles immutable_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_profile BEFORE DELETE OR UPDATE ON public.attraction_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: growth_profiles immutable_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_profile BEFORE DELETE OR UPDATE ON public.growth_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: growth_rule_profiles immutable_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_profile BEFORE DELETE OR UPDATE ON public.growth_rule_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: growth_provenance immutable_provenance; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_provenance BEFORE UPDATE ON public.growth_provenance FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: reward_recaps immutable_recap; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_recap BEFORE UPDATE ON public.reward_recaps FOR EACH ROW EXECUTE FUNCTION public.forest_recap_ack_only();


--
-- Name: activity_workouts immutable_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_record BEFORE UPDATE ON public.activity_workouts FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: milestone_claims immutable_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_record BEFORE UPDATE ON public.milestone_claims FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: visitor_economy_conversions immutable_record; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_record BEFORE DELETE OR UPDATE ON public.visitor_economy_conversions FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: shop_days immutable_shop_days; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_shop_days BEFORE DELETE OR UPDATE ON public.shop_days FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: shop_offer_windows immutable_shop_offer_windows; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_shop_offer_windows BEFORE DELETE OR UPDATE ON public.shop_offer_windows FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: shop_releases immutable_shop_releases; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_shop_releases BEFORE DELETE OR UPDATE ON public.shop_releases FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: shop_weeks immutable_shop_weeks; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_shop_weeks BEFORE DELETE OR UPDATE ON public.shop_weeks FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: skill_policies immutable_skill_policy; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_skill_policy BEFORE DELETE OR UPDATE ON public.skill_policies FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: visitor_contexts immutable_visitor_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON public.visitor_contexts FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: visitor_reward_events immutable_visitor_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON public.visitor_reward_events FOR EACH ROW EXECUTE FUNCTION public.forest_reward_recovery_metadata();


--
-- Name: visitor_rules immutable_visitor_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON public.visitor_rules FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: visitor_settlements immutable_visitor_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON public.visitor_settlements FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: visitor_wallet_entries immutable_visitor_history; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON public.visitor_wallet_entries FOR EACH ROW EXECUTE FUNCTION public.forest_immutable_profile();


--
-- Name: owned_items no_sold_item; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER no_sold_item BEFORE INSERT ON public.owned_items FOR EACH ROW EXECUTE FUNCTION public.forest_no_sold_item();


--
-- Name: owned_plants owned_plant_identity; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER owned_plant_identity BEFORE INSERT ON public.owned_plants FOR EACH ROW EXECUTE FUNCTION public.forest_record_plant_identity();


--
-- Name: owned_plants owned_plant_radius; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER owned_plant_radius BEFORE INSERT ON public.owned_plants FOR EACH ROW EXECUTE FUNCTION public.forest_pin_radius();


--
-- Name: plant_stages retain_pack_assets; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER retain_pack_assets BEFORE DELETE OR UPDATE ON public.plant_stages FOR EACH ROW EXECUTE FUNCTION public.forest_pack_asset_retention();


--
-- Name: plant_variants retain_pack_manifest; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER retain_pack_manifest BEFORE UPDATE ON public.plant_variants FOR EACH ROW EXECUTE FUNCTION public.forest_pack_manifest_retention();


--
-- Name: item_skill_profiles validate_item_skill; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_item_skill BEFORE INSERT ON public.item_skill_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_validate_item_skill();


--
-- Name: attraction_profiles validate_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_profile BEFORE INSERT ON public.attraction_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_validate_stage_profile();


--
-- Name: growth_profiles validate_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_profile BEFORE INSERT ON public.growth_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_validate_stage_profile();


--
-- Name: growth_rule_profiles validate_profile; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER validate_profile BEFORE INSERT ON public.growth_rule_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_validate_behaviour_profile();


--
-- Name: visitor_opportunities visitor_opportunity_transition; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER visitor_opportunity_transition BEFORE UPDATE ON public.visitor_opportunities FOR EACH ROW EXECUTE FUNCTION public.forest_opportunity_transition();


--
-- Name: visitor_rules visitor_rules_forward; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER visitor_rules_forward BEFORE INSERT ON public.visitor_rules FOR EACH ROW EXECUTE FUNCTION public.forest_visitor_rules_forward();


--
-- Name: growth_rule_profiles woodland_conversion_validation; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER woodland_conversion_validation BEFORE INSERT ON public.growth_rule_profiles FOR EACH ROW EXECUTE FUNCTION public.forest_validate_woodland_conversion();


--
-- Name: account_level_state fk_account_level_state_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.account_level_state
    ADD CONSTRAINT fk_account_level_state_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_credits fk_activity_credits_device_id_activity_devices; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT fk_activity_credits_device_id_activity_devices FOREIGN KEY (device_id, owner_id) REFERENCES public.activity_devices(id, owner_id);


--
-- Name: activity_credits fk_activity_credits_owner_id_activity_days; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT fk_activity_credits_owner_id_activity_days FOREIGN KEY (owner_id, game_date) REFERENCES public.activity_days(owner_id, game_date);


--
-- Name: activity_credits fk_activity_credits_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT fk_activity_credits_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_credits fk_activity_credits_rule_version_economy_configs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_credits
    ADD CONSTRAINT fk_activity_credits_rule_version_economy_configs FOREIGN KEY (rule_version) REFERENCES public.economy_configs(version);


--
-- Name: activity_days fk_activity_days_device_id_activity_devices; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_days
    ADD CONSTRAINT fk_activity_days_device_id_activity_devices FOREIGN KEY (device_id, owner_id) REFERENCES public.activity_devices(id, owner_id);


--
-- Name: activity_days fk_activity_days_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_days
    ADD CONSTRAINT fk_activity_days_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_days fk_activity_days_rule_version_economy_configs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_days
    ADD CONSTRAINT fk_activity_days_rule_version_economy_configs FOREIGN KEY (rule_version) REFERENCES public.economy_configs(version);


--
-- Name: activity_devices fk_activity_devices_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_devices
    ADD CONSTRAINT fk_activity_devices_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_metric_days fk_activity_metric_days_device_id_activity_devices; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_metric_days
    ADD CONSTRAINT fk_activity_metric_days_device_id_activity_devices FOREIGN KEY (device_id) REFERENCES public.activity_devices(id);


--
-- Name: activity_metric_days fk_activity_metric_days_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_metric_days
    ADD CONSTRAINT fk_activity_metric_days_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_metric_days fk_activity_metric_days_rule_version_economy_configs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_metric_days
    ADD CONSTRAINT fk_activity_metric_days_rule_version_economy_configs FOREIGN KEY (rule_version) REFERENCES public.economy_configs(version);


--
-- Name: activity_workout_days fk_activity_workout_days_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_workout_days
    ADD CONSTRAINT fk_activity_workout_days_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: activity_workout_days fk_activity_workout_days_rule_version_economy_configs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_workout_days
    ADD CONSTRAINT fk_activity_workout_days_rule_version_economy_configs FOREIGN KEY (rule_version) REFERENCES public.economy_configs(version);


--
-- Name: activity_workouts fk_activity_workouts_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_workouts
    ADD CONSTRAINT fk_activity_workouts_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: api_requests fk_api_requests_user_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.api_requests
    ADD CONSTRAINT fk_api_requests_user_id_users FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: catalog_discovery_state fk_catalog_discovery_state_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_discovery_state
    ADD CONSTRAINT fk_catalog_discovery_state_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: catalog_stage_discoveries fk_catalog_stage_discoveries_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_stage_discoveries
    ADD CONSTRAINT fk_catalog_stage_discoveries_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: catalog_stage_discoveries fk_catalog_stage_discoveries_species_id_plant_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.catalog_stage_discoveries
    ADD CONSTRAINT fk_catalog_stage_discoveries_species_id_plant_variants FOREIGN KEY (species_id, variant_id) REFERENCES public.plant_variants(species_id, variant_id);


--
-- Name: collection_events fk_collection_events_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.collection_events
    ADD CONSTRAINT fk_collection_events_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: daily_item_grants fk_daily_item_grants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_item_grants
    ADD CONSTRAINT fk_daily_item_grants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: daily_item_grants fk_daily_item_grants_plant_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_item_grants
    ADD CONSTRAINT fk_daily_item_grants_plant_id_plant_identities FOREIGN KEY (plant_id) REFERENCES public.plant_identities(id);


--
-- Name: daily_item_state fk_daily_item_state_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_item_state
    ADD CONSTRAINT fk_daily_item_state_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: daily_skill_activity fk_daily_skill_activity_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.daily_skill_activity
    ADD CONSTRAINT fk_daily_skill_activity_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: exchange_offers fk_exchange_offers_pack_id_pack_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.exchange_offers
    ADD CONSTRAINT fk_exchange_offers_pack_id_pack_definitions FOREIGN KEY (pack_id, pack_version) REFERENCES public.pack_definitions(id, version);


--
-- Name: expedition_bonus_grants fk_expedition_bonus_grants_entitlement_id_expedition_en_3df8; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_bonus_grants
    ADD CONSTRAINT fk_expedition_bonus_grants_entitlement_id_expedition_en_3df8 FOREIGN KEY (entitlement_id) REFERENCES public.expedition_entitlements(id);


--
-- Name: expedition_bonus_grants fk_expedition_bonus_grants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_bonus_grants
    ADD CONSTRAINT fk_expedition_bonus_grants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: expedition_claims fk_expedition_claims_entitlement_id_expedition_entitlements; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_claims
    ADD CONSTRAINT fk_expedition_claims_entitlement_id_expedition_entitlements FOREIGN KEY (entitlement_id) REFERENCES public.expedition_entitlements(id);


--
-- Name: expedition_claims fk_expedition_claims_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_claims
    ADD CONSTRAINT fk_expedition_claims_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: expedition_days fk_expedition_days_device_id_activity_devices; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_days
    ADD CONSTRAINT fk_expedition_days_device_id_activity_devices FOREIGN KEY (device_id) REFERENCES public.activity_devices(id);


--
-- Name: expedition_days fk_expedition_days_run_id_expedition_runs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_days
    ADD CONSTRAINT fk_expedition_days_run_id_expedition_runs FOREIGN KEY (run_id) REFERENCES public.expedition_runs(id);


--
-- Name: expedition_entitlements fk_expedition_entitlements_run_id_expedition_runs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_entitlements
    ADD CONSTRAINT fk_expedition_entitlements_run_id_expedition_runs FOREIGN KEY (run_id) REFERENCES public.expedition_runs(id);


--
-- Name: expedition_launches fk_expedition_launches_month_expedition_schedule; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_launches
    ADD CONSTRAINT fk_expedition_launches_month_expedition_schedule FOREIGN KEY (month) REFERENCES public.expedition_schedule(month);


--
-- Name: expedition_runs fk_expedition_runs_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_runs
    ADD CONSTRAINT fk_expedition_runs_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: expedition_runs fk_expedition_runs_template_version_expedition_templates; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_runs
    ADD CONSTRAINT fk_expedition_runs_template_version_expedition_templates FOREIGN KEY (template_version) REFERENCES public.expedition_templates(version);


--
-- Name: expedition_schedule fk_expedition_schedule_template_version_expedition_templates; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_schedule
    ADD CONSTRAINT fk_expedition_schedule_template_version_expedition_templates FOREIGN KEY (template_version) REFERENCES public.expedition_templates(version);


--
-- Name: expedition_workouts fk_expedition_workouts_run_id_expedition_runs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expedition_workouts
    ADD CONSTRAINT fk_expedition_workouts_run_id_expedition_runs FOREIGN KEY (run_id) REFERENCES public.expedition_runs(id);


--
-- Name: game_catalogue fk_game_catalogue_starter_species_id_plant_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.game_catalogue
    ADD CONSTRAINT fk_game_catalogue_starter_species_id_plant_variants FOREIGN KEY (starter_species_id, starter_variant_id) REFERENCES public.plant_variants(species_id, variant_id);


--
-- Name: garden_placements fk_garden_placements_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_placements
    ADD CONSTRAINT fk_garden_placements_garden_id_gardens FOREIGN KEY (garden_id, owner_id) REFERENCES public.gardens(id, owner_id);


--
-- Name: garden_placements fk_garden_placements_plant_id_owned_plants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_placements
    ADD CONSTRAINT fk_garden_placements_plant_id_owned_plants FOREIGN KEY (plant_id, owner_id) REFERENCES public.owned_plants(id, owner_id);


--
-- Name: garden_visitor_state fk_garden_visitor_state_context_id_visitor_contexts; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_visitor_state
    ADD CONSTRAINT fk_garden_visitor_state_context_id_visitor_contexts FOREIGN KEY (context_id) REFERENCES public.visitor_contexts(id);


--
-- Name: garden_visitor_state fk_garden_visitor_state_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.garden_visitor_state
    ADD CONSTRAINT fk_garden_visitor_state_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: gardens fk_gardens_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gardens
    ADD CONSTRAINT fk_gardens_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: gem_grants fk_gem_grants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.gem_grants
    ADD CONSTRAINT fk_gem_grants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: growth_day_summaries fk_growth_day_summaries_plant_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_day_summaries
    ADD CONSTRAINT fk_growth_day_summaries_plant_id_plant_identities FOREIGN KEY (plant_id) REFERENCES public.plant_identities(id);


--
-- Name: growth_day_summaries fk_growth_day_summaries_rule_version_economy_configs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.growth_day_summaries
    ADD CONSTRAINT fk_growth_day_summaries_rule_version_economy_configs FOREIGN KEY (rule_version) REFERENCES public.economy_configs(version);


--
-- Name: item_identities fk_item_identities_item_id_item_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_identities
    ADD CONSTRAINT fk_item_identities_item_id_item_definitions FOREIGN KEY (item_id, item_version) REFERENCES public.item_definitions(id, version);


--
-- Name: item_identities fk_item_identities_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_identities
    ADD CONSTRAINT fk_item_identities_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: item_placements fk_item_placements_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_placements
    ADD CONSTRAINT fk_item_placements_garden_id_gardens FOREIGN KEY (garden_id, owner_id) REFERENCES public.gardens(id, owner_id);


--
-- Name: item_placements fk_item_placements_item_id_owned_items; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_placements
    ADD CONSTRAINT fk_item_placements_item_id_owned_items FOREIGN KEY (item_id, owner_id) REFERENCES public.owned_items(id, owner_id);


--
-- Name: item_sales fk_item_sales_owned_item_id_item_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_sales
    ADD CONSTRAINT fk_item_sales_owned_item_id_item_identities FOREIGN KEY (owned_item_id, owner_id) REFERENCES public.item_identities(id, owner_id);


--
-- Name: item_sales fk_item_sales_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_sales
    ADD CONSTRAINT fk_item_sales_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: item_shop_offers fk_item_shop_offers_item_id_item_value_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_shop_offers
    ADD CONSTRAINT fk_item_shop_offers_item_id_item_value_definitions FOREIGN KEY (item_id, item_version) REFERENCES public.item_value_definitions(item_id, item_version);


--
-- Name: item_skill_bindings fk_item_skill_bindings_item_id_item_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_skill_bindings
    ADD CONSTRAINT fk_item_skill_bindings_item_id_item_definitions FOREIGN KEY (item_id, item_version) REFERENCES public.item_definitions(id, version);


--
-- Name: item_skill_bindings fk_item_skill_bindings_profile_id_item_skill_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_skill_bindings
    ADD CONSTRAINT fk_item_skill_bindings_profile_id_item_skill_profiles FOREIGN KEY (profile_id, profile_version) REFERENCES public.item_skill_profiles(id, version);


--
-- Name: item_step_grants fk_item_step_grants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_step_grants
    ADD CONSTRAINT fk_item_step_grants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: item_step_state fk_item_step_state_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_step_state
    ADD CONSTRAINT fk_item_step_state_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: item_valuations fk_item_valuations_owned_item_id_item_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_valuations
    ADD CONSTRAINT fk_item_valuations_owned_item_id_item_identities FOREIGN KEY (owned_item_id) REFERENCES public.item_identities(id);


--
-- Name: item_value_definitions fk_item_value_definitions_item_id_item_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.item_value_definitions
    ADD CONSTRAINT fk_item_value_definitions_item_id_item_definitions FOREIGN KEY (item_id, item_version) REFERENCES public.item_definitions(id, version);


--
-- Name: level_up_notices fk_level_up_notices_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.level_up_notices
    ADD CONSTRAINT fk_level_up_notices_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_bonus_grants fk_milestone_bonus_grants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_bonus_grants
    ADD CONSTRAINT fk_milestone_bonus_grants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_claims fk_milestone_claims_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_claims
    ADD CONSTRAINT fk_milestone_claims_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_days fk_milestone_days_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_days
    ADD CONSTRAINT fk_milestone_days_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_entitlements fk_milestone_entitlements_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_entitlements
    ADD CONSTRAINT fk_milestone_entitlements_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_entitlements fk_milestone_entitlements_policy_version_milestone_policies; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_entitlements
    ADD CONSTRAINT fk_milestone_entitlements_policy_version_milestone_policies FOREIGN KEY (policy_version) REFERENCES public.milestone_policies(version);


--
-- Name: milestone_event_state fk_milestone_event_state_event_id_milestone_events; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_event_state
    ADD CONSTRAINT fk_milestone_event_state_event_id_milestone_events FOREIGN KEY (event_id) REFERENCES public.milestone_events(event_id);


--
-- Name: milestone_event_state fk_milestone_event_state_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_event_state
    ADD CONSTRAINT fk_milestone_event_state_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_events fk_milestone_events_policy_version_milestone_policies; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_events
    ADD CONSTRAINT fk_milestone_events_policy_version_milestone_policies FOREIGN KEY (policy_version) REFERENCES public.milestone_policies(version);


--
-- Name: milestone_species fk_milestone_species_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_species
    ADD CONSTRAINT fk_milestone_species_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_species fk_milestone_species_species_id_plant_species; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_species
    ADD CONSTRAINT fk_milestone_species_species_id_plant_species FOREIGN KEY (species_id) REFERENCES public.plant_species(id);


--
-- Name: milestone_state fk_milestone_state_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_state
    ADD CONSTRAINT fk_milestone_state_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: milestone_state fk_milestone_state_policy_version_milestone_policies; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.milestone_state
    ADD CONSTRAINT fk_milestone_state_policy_version_milestone_policies FOREIGN KEY (policy_version) REFERENCES public.milestone_policies(version);


--
-- Name: owned_items fk_owned_items_id_item_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_items
    ADD CONSTRAINT fk_owned_items_id_item_identities FOREIGN KEY (id, owner_id) REFERENCES public.item_identities(id, owner_id);


--
-- Name: owned_items fk_owned_items_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_items
    ADD CONSTRAINT fk_owned_items_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: owned_packs fk_owned_packs_exchange_id_collection_events; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_packs
    ADD CONSTRAINT fk_owned_packs_exchange_id_collection_events FOREIGN KEY (exchange_id) REFERENCES public.collection_events(id);


--
-- Name: owned_packs fk_owned_packs_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_packs
    ADD CONSTRAINT fk_owned_packs_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: owned_packs fk_owned_packs_pack_id_pack_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_packs
    ADD CONSTRAINT fk_owned_packs_pack_id_pack_definitions FOREIGN KEY (pack_id, pack_version) REFERENCES public.pack_definitions(id, version);


--
-- Name: owned_plants fk_owned_plants_attraction_profile_id_attraction_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_attraction_profile_id_attraction_profiles FOREIGN KEY (attraction_profile_id, attraction_profile_version) REFERENCES public.attraction_profiles(id, version);


--
-- Name: owned_plants fk_owned_plants_behaviour_profile_id_growth_rule_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_behaviour_profile_id_growth_rule_profiles FOREIGN KEY (behaviour_profile_id, behaviour_profile_version) REFERENCES public.growth_rule_profiles(id, version);


--
-- Name: owned_plants fk_owned_plants_growth_profile_id_growth_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_growth_profile_id_growth_profiles FOREIGN KEY (growth_profile_id, growth_profile_version) REFERENCES public.growth_profiles(id, version);


--
-- Name: owned_plants fk_owned_plants_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_id_plant_identities FOREIGN KEY (id, owner_id) REFERENCES public.plant_identities(id, owner_id);


--
-- Name: owned_plants fk_owned_plants_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: owned_plants fk_owned_plants_species_id_plant_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owned_plants
    ADD CONSTRAINT fk_owned_plants_species_id_plant_variants FOREIGN KEY (species_id, variant_id) REFERENCES public.plant_variants(species_id, variant_id);


--
-- Name: pack_members fk_pack_members_attraction_profile_id_attraction_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT fk_pack_members_attraction_profile_id_attraction_profiles FOREIGN KEY (attraction_profile_id, attraction_profile_version) REFERENCES public.attraction_profiles(id, version);


--
-- Name: pack_members fk_pack_members_behaviour_profile_id_growth_rule_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT fk_pack_members_behaviour_profile_id_growth_rule_profiles FOREIGN KEY (behaviour_profile_id, behaviour_profile_version) REFERENCES public.growth_rule_profiles(id, version);


--
-- Name: pack_members fk_pack_members_growth_profile_id_growth_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT fk_pack_members_growth_profile_id_growth_profiles FOREIGN KEY (growth_profile_id, growth_profile_version) REFERENCES public.growth_profiles(id, version);


--
-- Name: pack_members fk_pack_members_pack_id_pack_definitions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT fk_pack_members_pack_id_pack_definitions FOREIGN KEY (pack_id, pack_version) REFERENCES public.pack_definitions(id, version);


--
-- Name: pack_members fk_pack_members_species_id_plant_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_members
    ADD CONSTRAINT fk_pack_members_species_id_plant_variants FOREIGN KEY (species_id, variant_id) REFERENCES public.plant_variants(species_id, variant_id);


--
-- Name: pack_openings fk_pack_openings_event_id_collection_events; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT fk_pack_openings_event_id_collection_events FOREIGN KEY (event_id) REFERENCES public.collection_events(id);


--
-- Name: pack_openings fk_pack_openings_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT fk_pack_openings_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: pack_openings fk_pack_openings_pack_id_owned_packs; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT fk_pack_openings_pack_id_owned_packs FOREIGN KEY (pack_id) REFERENCES public.owned_packs(id);


--
-- Name: pack_openings fk_pack_openings_plant_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pack_openings
    ADD CONSTRAINT fk_pack_openings_plant_id_plant_identities FOREIGN KEY (plant_id) REFERENCES public.plant_identities(id);


--
-- Name: plant_growth_credits fk_plant_growth_credits_activity_credit_id_activity_credits; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_growth_credits
    ADD CONSTRAINT fk_plant_growth_credits_activity_credit_id_activity_credits FOREIGN KEY (activity_credit_id) REFERENCES public.activity_credits(id);


--
-- Name: plant_growth_credits fk_plant_growth_credits_plant_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_growth_credits
    ADD CONSTRAINT fk_plant_growth_credits_plant_id_plant_identities FOREIGN KEY (plant_id) REFERENCES public.plant_identities(id);


--
-- Name: plant_growth_credits fk_plant_growth_credits_provenance_id_growth_provenance; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_growth_credits
    ADD CONSTRAINT fk_plant_growth_credits_provenance_id_growth_provenance FOREIGN KEY (provenance_id) REFERENCES public.growth_provenance(id);


--
-- Name: plant_identities fk_plant_identities_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_identities
    ADD CONSTRAINT fk_plant_identities_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: plant_sales fk_plant_sales_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_sales
    ADD CONSTRAINT fk_plant_sales_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: plant_sales fk_plant_sales_plant_id_plant_identities; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_sales
    ADD CONSTRAINT fk_plant_sales_plant_id_plant_identities FOREIGN KEY (plant_id) REFERENCES public.plant_identities(id);


--
-- Name: plant_species fk_plant_species_attraction_profile_id_attraction_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_species
    ADD CONSTRAINT fk_plant_species_attraction_profile_id_attraction_profiles FOREIGN KEY (attraction_profile_id, attraction_profile_version) REFERENCES public.attraction_profiles(id, version);


--
-- Name: plant_species fk_plant_species_behaviour_profile_id_growth_rule_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_species
    ADD CONSTRAINT fk_plant_species_behaviour_profile_id_growth_rule_profiles FOREIGN KEY (behaviour_profile_id, behaviour_profile_version) REFERENCES public.growth_rule_profiles(id, version);


--
-- Name: plant_species fk_plant_species_growth_profile_id_growth_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_species
    ADD CONSTRAINT fk_plant_species_growth_profile_id_growth_profiles FOREIGN KEY (growth_profile_id, growth_profile_version) REFERENCES public.growth_profiles(id, version);


--
-- Name: plant_stages fk_plant_stages_species_id_plant_variants; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_stages
    ADD CONSTRAINT fk_plant_stages_species_id_plant_variants FOREIGN KEY (species_id, variant_id) REFERENCES public.plant_variants(species_id, variant_id);


--
-- Name: plant_variants fk_plant_variants_attraction_profile_id_attraction_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_variants
    ADD CONSTRAINT fk_plant_variants_attraction_profile_id_attraction_profiles FOREIGN KEY (attraction_profile_id, attraction_profile_version) REFERENCES public.attraction_profiles(id, version);


--
-- Name: plant_variants fk_plant_variants_behaviour_profile_id_growth_rule_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_variants
    ADD CONSTRAINT fk_plant_variants_behaviour_profile_id_growth_rule_profiles FOREIGN KEY (behaviour_profile_id, behaviour_profile_version) REFERENCES public.growth_rule_profiles(id, version);


--
-- Name: plant_variants fk_plant_variants_growth_profile_id_growth_profiles; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_variants
    ADD CONSTRAINT fk_plant_variants_growth_profile_id_growth_profiles FOREIGN KEY (growth_profile_id, growth_profile_version) REFERENCES public.growth_profiles(id, version);


--
-- Name: plant_variants fk_plant_variants_species_id_plant_species; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.plant_variants
    ADD CONSTRAINT fk_plant_variants_species_id_plant_species FOREIGN KEY (species_id) REFERENCES public.plant_species(id);


--
-- Name: player_progress fk_player_progress_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.player_progress
    ADD CONSTRAINT fk_player_progress_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: reward_events fk_reward_events_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_events
    ADD CONSTRAINT fk_reward_events_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: reward_recaps fk_reward_recaps_event_id_reward_events; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_recaps
    ADD CONSTRAINT fk_reward_recaps_event_id_reward_events FOREIGN KEY (event_id) REFERENCES public.reward_events(id);


--
-- Name: reward_recaps fk_reward_recaps_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reward_recaps
    ADD CONSTRAINT fk_reward_recaps_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: shop_allowances fk_shop_allowances_offer_id_item_shop_offers; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_allowances
    ADD CONSTRAINT fk_shop_allowances_offer_id_item_shop_offers FOREIGN KEY (offer_id, offer_version) REFERENCES public.item_shop_offers(id, version);


--
-- Name: shop_allowances fk_shop_allowances_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_allowances
    ADD CONSTRAINT fk_shop_allowances_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: shop_days fk_shop_days_week_start_shop_weeks; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_days
    ADD CONSTRAINT fk_shop_days_week_start_shop_weeks FOREIGN KEY (week_start) REFERENCES public.shop_weeks(week_start);


--
-- Name: shop_offer_windows fk_shop_offer_windows_offer_id_item_shop_offers; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_offer_windows
    ADD CONSTRAINT fk_shop_offer_windows_offer_id_item_shop_offers FOREIGN KEY (offer_id, offer_version) REFERENCES public.item_shop_offers(id, version);


--
-- Name: shop_offer_windows fk_shop_offer_windows_shop_date_shop_days; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_offer_windows
    ADD CONSTRAINT fk_shop_offer_windows_shop_date_shop_days FOREIGN KEY (shop_date) REFERENCES public.shop_days(shop_date);


--
-- Name: shop_weeks fk_shop_weeks_release_version_shop_releases; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shop_weeks
    ADD CONSTRAINT fk_shop_weeks_release_version_shop_releases FOREIGN KEY (release_version) REFERENCES public.shop_releases(version);


--
-- Name: visitor_contexts fk_visitor_contexts_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_contexts
    ADD CONSTRAINT fk_visitor_contexts_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_contexts fk_visitor_contexts_rule_version_visitor_rules; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_contexts
    ADD CONSTRAINT fk_visitor_contexts_rule_version_visitor_rules FOREIGN KEY (rule_version) REFERENCES public.visitor_rules(version);


--
-- Name: visitor_controls fk_visitor_controls_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_controls
    ADD CONSTRAINT fk_visitor_controls_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_day_summaries fk_visitor_day_summaries_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_day_summaries
    ADD CONSTRAINT fk_visitor_day_summaries_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_day_summaries fk_visitor_day_summaries_rule_version_visitor_rules; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_day_summaries
    ADD CONSTRAINT fk_visitor_day_summaries_rule_version_visitor_rules FOREIGN KEY (rule_version) REFERENCES public.visitor_rules(version);


--
-- Name: visitor_economy_conversions fk_visitor_economy_conversions_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_economy_conversions
    ADD CONSTRAINT fk_visitor_economy_conversions_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_opportunities fk_visitor_opportunities_context_id_visitor_contexts; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT fk_visitor_opportunities_context_id_visitor_contexts FOREIGN KEY (context_id) REFERENCES public.visitor_contexts(id);


--
-- Name: visitor_opportunities fk_visitor_opportunities_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT fk_visitor_opportunities_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_opportunities fk_visitor_opportunities_rule_version_visitor_rules; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT fk_visitor_opportunities_rule_version_visitor_rules FOREIGN KEY (rule_version) REFERENCES public.visitor_rules(version);


--
-- Name: visitor_opportunities fk_visitor_opportunities_session_id_visitor_sessions; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_opportunities
    ADD CONSTRAINT fk_visitor_opportunities_session_id_visitor_sessions FOREIGN KEY (session_id) REFERENCES public.visitor_sessions(id);


--
-- Name: visitor_reward_events fk_visitor_reward_events_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_reward_events
    ADD CONSTRAINT fk_visitor_reward_events_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_schedules fk_visitor_schedules_context_id_visitor_contexts; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_schedules
    ADD CONSTRAINT fk_visitor_schedules_context_id_visitor_contexts FOREIGN KEY (context_id) REFERENCES public.visitor_contexts(id);


--
-- Name: visitor_schedules fk_visitor_schedules_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_schedules
    ADD CONSTRAINT fk_visitor_schedules_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_sessions fk_visitor_sessions_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_sessions
    ADD CONSTRAINT fk_visitor_sessions_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_sessions fk_visitor_sessions_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_sessions
    ADD CONSTRAINT fk_visitor_sessions_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_settlements fk_visitor_settlements_context_id_visitor_contexts; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_settlements
    ADD CONSTRAINT fk_visitor_settlements_context_id_visitor_contexts FOREIGN KEY (context_id) REFERENCES public.visitor_contexts(id);


--
-- Name: visitor_settlements fk_visitor_settlements_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_settlements
    ADD CONSTRAINT fk_visitor_settlements_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_storage_lots fk_visitor_storage_lots_garden_id_gardens; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_storage_lots
    ADD CONSTRAINT fk_visitor_storage_lots_garden_id_gardens FOREIGN KEY (garden_id) REFERENCES public.gardens(id);


--
-- Name: visitor_storage_lots fk_visitor_storage_lots_rule_version_visitor_rules; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_storage_lots
    ADD CONSTRAINT fk_visitor_storage_lots_rule_version_visitor_rules FOREIGN KEY (rule_version) REFERENCES public.visitor_rules(version);


--
-- Name: visitor_throttles fk_visitor_throttles_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_throttles
    ADD CONSTRAINT fk_visitor_throttles_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_wallet_entries fk_visitor_wallet_entries_event_id_visitor_reward_events; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallet_entries
    ADD CONSTRAINT fk_visitor_wallet_entries_event_id_visitor_reward_events FOREIGN KEY (event_id) REFERENCES public.visitor_reward_events(id);


--
-- Name: visitor_wallet_entries fk_visitor_wallet_entries_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallet_entries
    ADD CONSTRAINT fk_visitor_wallet_entries_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: visitor_wallets fk_visitor_wallets_owner_id_users; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.visitor_wallets
    ADD CONSTRAINT fk_visitor_wallets_owner_id_users FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--
