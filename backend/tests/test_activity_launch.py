"""Full typed-input, publication and introductory-economy regression coverage."""

import copy
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from fractions import Fraction
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import pytest
from sqlalchemy import func, select

from forest_api import activity, launch_balance, services
from forest_api.activity_models import MilestoneClaim, WorkoutDay, WorkoutImport
from forest_api.activity_schemas import SyncActivity
from forest_api.calculations import (
    MICRO,
    MetricRate,
    VisitorCurve,
    calculate_growth,
    visitor_parameters,
)
from forest_api.models import BehaviourProfile, OwnedPlant, Species
from forest_api.skill_rules import SkillCaps
from forest_api.skills import SkillSnapshot
from forest_api.visitor_models import VisitorWallet


@pytest.fixture
def player(app, client, headers, register):
    with app.state.database.sessions() as session:
        publication = launch_balance.publish(session, app.state.settings)
    now = [datetime.fromisoformat(publication["effectiveAt"]) + timedelta(seconds=1)]
    app.state.clock = lambda: now[0]
    account = register()
    owner = UUID(account["profile"]["userId"])
    plant = account["starterPlantId"]
    installation = str(uuid4())
    enrol = {
        "requestId": str(uuid4()),
        "installationId": installation,
        "observedAt": now[0].isoformat(),
        "steps": 1000,
        "walkingRunningDistanceMetres": "1000.000",
        "activeEnergyKcal": "100.000",
        "flightsClimbed": 5,
        "workoutsAvailable": True,
    }
    response = client.post("/v1/activity/enrolments", headers=headers(), json=enrol)
    assert response.status_code == 200, response.text
    device = response.json()["device"]["deviceId"]
    placed = client.post(
        "/v1/me/garden/edits",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": launch_balance.VERSION,
            "actions": [
                {"action": "plant", "plantId": plant, "x": 2, "y": 2, "rotationDegrees": 0}
            ],
        },
    )
    assert placed.status_code == 200, placed.text

    def submit(*, steps=1000, workouts=None, days=None, **metrics):
        body = {
            "requestId": str(uuid4()),
            "installationId": installation,
            "deviceId": device,
            "observedAt": now[0].isoformat(),
            "workoutsAvailable": True,
            "workouts": workouts or [],
            "days": days
            or [
                {
                    "gameDate": now[0].astimezone(ZoneInfo("Asia/Singapore")).date().isoformat(),
                    "steps": steps,
                    **metrics,
                }
            ],
        }
        result = client.post("/v1/activity/sync", headers=headers(), json=body)
        assert result.status_code == 200, result.text
        return result.json(), body

    return {
        "now": now,
        "owner": owner,
        "plant": plant,
        "submit": submit,
        "device": device,
        "installation": installation,
        "client": client,
        "headers": headers(),
        "publication": publication,
    }


def workout(start, minutes=60, kind=37, **changes):
    return {
        "workoutId": str(uuid4()),
        "originalType": kind,
        "sourceBundleIdentifier": "example.recorded",
        "start": start.isoformat(),
        "end": (start + timedelta(minutes=minutes)).isoformat(),
        "durationMilliseconds": minutes * 60 * 1000,
        "wasUserEntered": None,
        **changes,
    }


def growth(result):
    return int(result["garden"]["plants"][0]["growthMicroUnits"])


def test_publication_profiles_prices_odds_caps_and_repeat_safe(app, client, headers, player):
    summary = client.get("/v1/me/collection", headers=headers()).json()
    assert {o["offerId"]: o["tokenCost"] for o in summary["offers"]} == {
        "woodland": "120",
        "moonwillow": "240",
    }
    woodland = next(o["pack"] for o in summary["offers"] if o["offerId"] == "woodland")
    assert {p["rarity"]: p["weight"] for p in woodland["rarities"]} == {"common": 75, "epic": 25}
    with app.state.database.sessions() as session:
        assert launch_balance.publish(session, app.state.settings)["alreadyPublished"]
    with app.state.database.sessions() as session:
        oak = session.get(OwnedPlant, UUID(player["plant"]))
        assert oak.behaviour_profile_id == "launch_oak"
        assert session.get(BehaviourProfile, ("dev_oak_behaviour", 1)).rules[
            "metricMultipliers"
        ] == {"steps": 1.0}
        moon = session.get(Species, "moonwillow")
        assert float(moon.clearance_radius) == 0.95 and moon.rarity == "epic"
    assert len(summary["milestones"]) == 5


def test_steps_plus_one_hour_workout_and_no_duplicate_credit(player, client):
    start = player["now"][0] + timedelta(seconds=1)
    record = workout(start)
    player["now"][0] = start + timedelta(hours=1, seconds=1)
    result, body = player["submit"](steps=2000, workouts=[record])
    assert growth(result) == 25 * MICRO
    assert Fraction(result["activityMetrics"]["workout_minutes.running"]) == 60
    replay = client.post("/v1/activity/sync", headers=player["headers"], json=body)
    assert replay.json() == result
    again, _ = player["submit"](steps=2000, workouts=[record])
    assert growth(again) == 25 * MICRO
    assert again["workouts"][0]["status"] == "already_processed"


@pytest.mark.parametrize("manual", [True, False, None])
def test_manual_guard_preserves_true_false_absent(player, app, manual):
    start = player["now"][0] + timedelta(seconds=1)
    record = workout(start, wasUserEntered=manual)
    if manual is None:
        record.pop("wasUserEntered")
    player["now"][0] = start + timedelta(hours=1, seconds=1)
    result, _ = player["submit"](workouts=[record])
    assert growth(result) == (0 if manual is True else 15 * MICRO)
    with app.state.database.sessions() as session:
        stored = session.get(WorkoutImport, (player["owner"], UUID(record["workoutId"])))
        assert stored.payload["wasUserEntered"] is manual


def test_overlap_across_sources_and_types_and_late_duplicate(player):
    start = player["now"][0] + timedelta(seconds=1)
    a = workout(start)
    b = workout(start + timedelta(minutes=30), kind=13, sourceBundleIdentifier="another.tracker")
    player["now"][0] = start + timedelta(minutes=91)
    result, _ = player["submit"](workouts=[b, a])
    assert growth(result) == int(22.5 * MICRO)
    duplicate = workout(start, kind=46)
    again, _ = player["submit"](workouts=[duplicate])
    assert growth(again) == growth(result)


def test_multisport_segments_replace_parent_and_exclude_transition(player):
    start = player["now"][0] + timedelta(seconds=1)
    record = workout(
        start,
        kind=999,
        hasSegments=True,
        segments=[
            {
                "originalType": 37,
                "start": start.isoformat(),
                "end": (start + timedelta(minutes=20)).isoformat(),
                "durationMilliseconds": 1_200_000,
            },
            {
                "originalType": 999,
                "start": (start + timedelta(minutes=20)).isoformat(),
                "end": (start + timedelta(minutes=30)).isoformat(),
                "durationMilliseconds": 600_000,
            },
            {
                "originalType": 13,
                "start": (start + timedelta(minutes=30)).isoformat(),
                "end": (start + timedelta(minutes=60)).isoformat(),
                "durationMilliseconds": 1_800_000,
            },
        ],
    )
    player["now"][0] = start + timedelta(minutes=61)
    result, _ = player["submit"](workouts=[record])
    assert growth(result) == int(12.5 * MICRO)
    assert Fraction(result["activityMetrics"]["workout_minutes.running"]) == 20
    assert Fraction(result["activityMetrics"]["workout_minutes.cycling"]) == 30


def test_cross_midnight_exact_attribution(player):
    zone = ZoneInfo("Asia/Singapore")
    date = player["now"][0].astimezone(zone).date() + timedelta(days=1)
    midnight = activity.day_bounds(date, "Asia/Singapore")[0]
    start = midnight - timedelta(minutes=10)
    record = workout(start, minutes=30)
    player["now"][0] = midnight + timedelta(minutes=21)
    result, _ = player["submit"](steps=0, workouts=[record])
    assert growth(result) == int(7.5 * MICRO)
    minutes = [
        Fraction(d["metrics"]["workout_minutes.running"]["newlyEligible"])
        for d in result["days"]
        if "workout_minutes.running" in d["metrics"]
    ]
    assert minutes == [10, 20]


def test_duration_cap_is_shared_across_types_and_overflow_is_not_backlog(player, app):
    start = player["now"][0] + timedelta(seconds=1)
    records = [
        workout(start, minutes=90),
        workout(start + timedelta(minutes=90), minutes=90, kind=13),
    ]
    player["now"][0] = start + timedelta(minutes=181)
    result, _ = player["submit"](workouts=records)
    assert growth(result) == 30 * MICRO
    with app.state.database.sessions() as session:
        total = session.scalar(select(func.sum(WorkoutDay.credited_microseconds)))
        assert total == 7200 * 1_000_000
    repeat, _ = player["submit"](workouts=[workout(start, minutes=180, kind=46)])
    assert growth(repeat) == 30 * MICRO


def test_missing_optional_data_and_downward_revision_leave_steps_usable(player):
    a, _ = player["submit"](steps=2000)
    assert growth(a) == 10 * MICRO
    b, _ = player["submit"](steps=1500, walkingRunningDistanceMetres="2000.000")
    assert growth(b) == 10 * MICRO  # Oak deliberately omits distance.
    assert Fraction(b["activityMetrics"]["walking_running_distance_km"]) == 1
    c, _ = player["submit"](steps=2500, walkingRunningDistanceMetres="1500.000")
    assert growth(c) == 15 * MICRO
    assert Fraction(c["activityMetrics"]["walking_running_distance_km"]) == 1


def test_first_read_of_a_previously_missing_metric_is_only_a_baseline(player, app):
    with app.state.database.sessions.begin() as session:
        from forest_api.models import ActivityDevice

        device = session.get(ActivityDevice, UUID(player["device"]))
        saved = dict(device.metric_baselines)
        saved.pop("active_energy_kcal")
        device.metric_baselines = saved
    first, _ = player["submit"](activeEnergyKcal="500.000")
    assert first["days"][0]["metrics"]["active_energy_kcal"]["baselineEstablished"]
    assert Fraction(first["activityMetrics"]["active_energy_kcal"]) == 0
    second, _ = player["submit"](activeEnergyKcal="550.250")
    assert Fraction(second["activityMetrics"]["active_energy_kcal"]) == Fraction(201, 4)


def test_different_request_uuids_do_not_reissue_workout_time_concurrently(player):
    start = player["now"][0] + timedelta(seconds=1)
    record = workout(start)
    player["now"][0] = start + timedelta(minutes=61)
    # Separate HTTP requests share owner/garden locks, not process-local state.
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: player["submit"](workouts=[record])[0], range(2)))
    assert all(growth(r) == 15 * MICRO for r in results)


def test_milestone_once_only_wallet_ledger_and_no_hosted_inflation(player, client, app):
    player["submit"](steps=2000)
    body = {"requestId": str(uuid4())}
    path = "/v1/me/milestones/first_movement/claim"
    first = client.post(path, headers=player["headers"], json=body)
    assert first.status_code == 200, first.text
    assert first.json()["tokensEarned"] == "30"
    assert client.post(path, headers=player["headers"], json=body).json() == first.json()
    assert (
        client.post(path, headers=player["headers"], json={"requestId": str(uuid4())}).json()
        == first.json()
    )
    with app.state.database.sessions() as session:
        wallet = session.get(VisitorWallet, player["owner"])
        assert wallet.tokens == 30 and wallet.hosted_active == wallet.hosted_offline == 0
        assert session.scalar(select(func.count()).select_from(MilestoneClaim)) == 1
    not_ready = client.post(
        "/v1/me/milestones/first_maturity/claim",
        headers=player["headers"],
        json={"requestId": str(uuid4())},
    )
    assert not_ready.status_code == 409


def test_new_curve_monotonic_continuous_bounded_and_more_room_for_gardens():
    curve = VisitorCurve.model_validate(launch_balance.CURVE)
    values = [
        visitor_parameters(a * MICRO, 1, curve)["active_probability"]
        for a in [0, 2, 20, 32, 60, 100, 200, 299, 300, 301, 450, 600, 1000000]
    ]
    assert values == sorted(values) and all(Fraction(1, 10) <= p <= Fraction(4, 5) for p in values)
    assert visitor_parameters(0, 0, curve)["active_probability"] == 0
    assert visitor_parameters(300 * MICRO, 15, curve)["active_probability"] == Fraction(3, 5)
    assert float(values[4] / values[8]) < 0.4
    assert float(values[9] - values[8]) < 0.002


def test_new_policy_limits_each_growth_layer_to_two(player, app):
    from forest_api.models import SkillPolicy

    with app.state.database.sessions() as session:
        caps = SkillCaps.model_validate(session.get(SkillPolicy, launch_balance.POLICY).rules)
    assert caps.activity_bonus == caps.water_bonus == "1"
    snapshot = SkillSnapshot((), caps, launch_balance.POLICY)
    assert snapshot.caps.activity_bonus == "1"


def test_legacy_queued_request_hash_is_unchanged():
    payload = {
        "installationId": str(uuid4()),
        "deviceId": str(uuid4()),
        "observedAt": "2026-10-25T12:00:00Z",
        "days": [{"gameDate": "2026-10-25", "steps": 2000}],
    }
    body = SyncActivity.model_validate({"requestId": str(uuid4()), **payload})
    old = body.model_dump(mode="json", by_alias=True, exclude={"request_id"})
    for key in ("workoutsAvailable", "workouts"):
        old.pop(key)
    for day in old["days"]:
        for key in ("walkingRunningDistanceMetres", "activeEnergyKcal", "flightsClimbed"):
            day.pop(key)
    digest = hashlib.sha256(
        json.dumps(["activity_sync", old], sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    assert services.request_hash("activity_sync", body) == digest


def test_optional_daily_inputs_grow_a_profile_that_enables_them(player, app):
    with app.state.database.sessions.begin() as session:
        profile = session.get(BehaviourProfile, ("launch_oak", 1))
        rules = copy.deepcopy(profile.rules)
        rules["metricMultipliers"].update(
            walking_running_distance_km=1, active_energy_kcal=1, flights_climbed=1
        )
        session.add(BehaviourProfile(id="test_all_metrics", version=1, rules=rules))
        session.flush()
        species = session.get(Species, "oak")
        species.behaviour_profile_id = "test_all_metrics"
        fresh = services.award_plant(
            session, player["owner"], "oak", "standard", "test", "all-metrics"
        )
        from forest_api.models import Garden, GardenPlacement

        garden = session.scalar(select(Garden).where(Garden.owner_id == player["owner"]))
        session.add(
            GardenPlacement(
                plant_id=fresh.id,
                owner_id=player["owner"],
                garden_id=garden.id,
                x=5,
                y=5,
                rotation_degrees=0,
            )
        )
        plant_id = fresh.id
    result, _ = player["submit"](
        walkingRunningDistanceMetres="2000.000", activeEnergyKcal="200.000", flightsClimbed=10
    )
    fresh = next(p for p in result["garden"]["plants"] if p["plantId"] == str(plant_id))
    assert int(fresh["growthMicroUnits"]) == 4 * MICRO  # 1 km + 100 kcal + 5 flights.


def test_split_session_matches_whole_session_and_late_overlap_does_not_add(player):
    start = player["now"][0] + timedelta(seconds=1)
    player["now"][0] = start + timedelta(minutes=61)
    first, _ = player["submit"](workouts=[workout(start, minutes=20)])
    assert growth(first) == 5 * MICRO
    split, _ = player["submit"](workouts=[workout(start + timedelta(minutes=20), minutes=40)])
    whole, _ = player["submit"](workouts=[workout(start)])
    assert growth(split) == growth(whole) == 15 * MICRO


def test_proportional_paused_duration_is_split_exactly_at_midnight(player):
    date = player["now"][0].astimezone(ZoneInfo("Asia/Singapore")).date() + timedelta(days=1)
    midnight = activity.day_bounds(date, "Asia/Singapore")[0]
    record = workout(midnight - timedelta(minutes=10), minutes=30, durationMilliseconds=900_000)
    player["now"][0] = midnight + timedelta(minutes=21)
    result, _ = player["submit"](steps=0, workouts=[record])
    assert growth(result) == 3_750_000
    assert [
        Fraction(d["metrics"]["workout_minutes.running"]["newlyEligible"])
        for d in result["days"]
        if "workout_minutes.running" in d["metrics"]
    ] == [5, 10]


def test_workouts_remain_usable_when_steps_are_unavailable(player, app):
    from forest_api.models import ActivityDevice

    with app.state.database.sessions.begin() as session:
        device = session.get(ActivityDevice, UUID(player["device"]))
        device.metric_baselines = {**device.metric_baselines, "steps": {"ready": False}}
    start = player["now"][0] + timedelta(seconds=1)
    player["now"][0] = start + timedelta(minutes=61)
    result, _ = player["submit"](steps=None, workouts=[workout(start)])
    assert growth(result) == 15 * MICRO
    assert result["activitySteps"] == "0"


def test_milestone_concurrency_credits_only_one_ledger_entry(player, client, app):
    from forest_api.visitor_models import VisitorRewardEvent, VisitorWalletEntry

    player["submit"](steps=2000)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(
                lambda _: client.post(
                    "/v1/me/milestones/first_movement/claim",
                    headers=player["headers"],
                    json={"requestId": str(uuid4())},
                ),
                range(2),
            )
        )
    assert all(r.status_code == 200 for r in results)
    assert results[0].json() == results[1].json()
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, player["owner"]).tokens == 30
        assert session.scalar(select(func.count()).select_from(VisitorWalletEntry)) == 1
        assert (
            session.scalar(
                select(func.count())
                .select_from(VisitorRewardEvent)
                .where(VisitorRewardEvent.kind == "milestone")
            )
            == 1
        )


def test_earned_growth_milestones_fund_a_pack_with_new_profiles(player, client):
    from test_collection import exchange, open_pack

    player["submit"](steps=31000)
    for steps in [30000, 30000, 10000]:
        player["now"][0] += timedelta(days=1)
        player["submit"](steps=steps)
    for milestone in ["first_movement", "first_seedling", "first_maturity"]:
        result = client.post(
            f"/v1/me/milestones/{milestone}/claim",
            headers=player["headers"],
            json={"requestId": str(uuid4())},
        )
        assert result.status_code == 200, result.text
    economy = {"client": client, "headers": player["headers"]}
    bought = exchange(economy, offerVersion=launch_balance.PACK_VERSION)
    assert bought.status_code == 200, bought.text
    assert bought.json()["tokenBalance"] == "30"
    opened = open_pack(economy, bought.json()["packs"][0]["ownedPackId"])
    assert opened.status_code == 200, opened.text
    assert opened.json()["plant"]["pinnedProfiles"]["behaviour"]["id"].startswith("launch_")


def test_actual_two_layer_caps_produce_at_most_four_times_growth():
    from test_skills import effect, facts

    source = facts(
        effects=[
            effect(
                id="activity",
                scope="activity",
                metric="workout_minutes.running",
                stackingGroup="activity",
                magnitude={"value": "9"},
            ),
            effect(id="water", stackingGroup="water", magnitude={"value": "9"}),
        ]
    )
    caps = SkillCaps.model_validate(
        {**launch_balance.CAPS_V1, "activityBonus": "1", "waterBonus": "1"}
    )
    snapshot = SkillSnapshot((source,), caps, launch_balance.POLICY)
    factors, water = snapshot.growth(source, ["workout_minutes.running"])
    assert factors["workout_minutes.running"] == water == 2
    rates = {
        "workout_minutes.running": MetricRate.model_validate(
            launch_balance.METRICS["workout_minutes.running"]
        )
    }
    result = calculate_growth(
        {"workout_minutes.running": 60},
        rates,
        {"workout_minutes.*": 1},
        0,
        1000 * MICRO,
        {},
        activity_factors=factors,
        water_factor=water,
    )
    assert result.awarded == 60 * MICRO
    exact_zero = calculate_growth(
        {"workout_minutes.running": 60},
        rates,
        {"workout_minutes.*": 1, "workout_minutes.running": 0},
        0,
        1000 * MICRO,
        {},
    )
    assert exact_zero.awarded == 0


def test_publication_preserves_existing_plant_and_old_owned_pack(economy):
    from test_collection import exchange, open_pack

    from forest_api.collection_models import PackDefinition

    app = economy["app"]
    bought = exchange(economy).json()
    with app.state.database.sessions() as session:
        existing = [(p.id, services.profile_refs(p)) for p in session.scalars(select(OwnedPlant))]
        old_definition = copy.deepcopy(session.get(PackDefinition, ("woodland", 1)).definition)
    with app.state.database.sessions() as session:
        publication = launch_balance.publish(session, app.state.settings)
    app.state.clock = lambda: (
        datetime.fromisoformat(publication["effectiveAt"]) + timedelta(seconds=1)
    )
    with app.state.database.sessions() as session:
        assert [
            (p.id, services.profile_refs(p)) for p in session.scalars(select(OwnedPlant))
        ] == existing
        assert session.get(PackDefinition, ("woodland", 1)).definition == old_definition
    opened = open_pack(economy, bought["packs"][0]["ownedPackId"])
    assert opened.status_code == 200, opened.text
    assert opened.json()["plant"]["pinnedProfiles"]["behaviour"]["id"].startswith("dev_")


def test_fresh_nonfixture_publication_needs_no_development_seed(database_factory):
    from alembic import command
    from conftest import migration_config, migration_url

    from forest_api.collection_models import PackDefinition
    from forest_api.config import Settings
    from forest_api.database import Database
    from forest_api.models import GameCatalogue

    with database_factory() as url:
        with migration_url(url):
            command.upgrade(migration_config(), "head")
        settings = Settings(
            _env_file=None,
            database_url=url,
            environment="production",
            auth_mode="jwks",
            auth_issuer="https://auth.example.test",
            auth_audience="forest",
            auth_jwks_url="https://auth.example.test/jwks",
        )
        database = Database(settings)
        try:
            with database.sessions() as session:
                launch_balance.publish(session, settings)
            with database.sessions() as session:
                assert not session.get(GameCatalogue, 1).is_fixture
                assert not session.get(
                    PackDefinition, ("woodland", launch_balance.PACK_VERSION)
                ).is_fixture
                assert (
                    services.get_catalogue_state(session, settings).version
                    == launch_balance.VERSION
                )
        finally:
            database.engine.dispose()


def test_fresh_test_grant_is_repeat_safe_and_keeps_progress(player, app):
    from forest_api.models import PlayerProgress

    player["submit"](steps=2000)
    with app.state.database.sessions() as session:
        preview = launch_balance.grant_test_plants(
            session, app.state.settings, "alice", dry_run=True
        )
    assert all(p["plantId"] is None for p in preview["plants"])
    with app.state.database.sessions() as session:
        first = launch_balance.grant_test_plants(session, app.state.settings, "alice")
    with app.state.database.sessions() as session:
        repeat = launch_balance.grant_test_plants(session, app.state.settings, "alice")
    assert [p["plantId"] for p in first["plants"]] == [p["plantId"] for p in repeat["plants"]]
    with app.state.database.sessions() as session:
        assert session.get(PlayerProgress, player["owner"]).activity_steps == 1000
        for granted in first["plants"]:
            plant = session.get(OwnedPlant, UUID(granted["plantId"]))
            assert plant.growth_micro_units == 0 and plant.acquisition_source == "development_grant"
