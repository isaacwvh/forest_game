"""UTC recurrence, real HTTP evidence recovery, grants and item accounting."""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from test_activity_launch import player as player
from test_visitor_rescale import scene as scene
from test_woodland import forest as forest

from forest_api import expeditions, items, progression, recovery, services
from forest_api.activity_models import WorkoutImport
from forest_api.expedition_models import (
    ExpeditionClaim,
    ExpeditionRun,
    ItemStepGrant,
    ItemStepState,
)
from forest_api.item_models import ItemIdentity, ItemPlacement, OwnedItem
from forest_api.models import Garden, OwnedPlant, PlayerProgress
from forest_api.visitor_models import VisitorWallet


@pytest.fixture
def expedition(forest, app):
    start = expeditions.next_month(expeditions.month_start(forest["now"][0]))
    with app.state.database.sessions() as session:
        preview = expeditions.publish(
            session, app.state.settings, start.date(), clock=lambda: forest["now"][0]
        )
    assert not preview["applied"]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(ExpeditionRun)) == 0
    with app.state.database.sessions() as session:
        expeditions.publish(
            session, app.state.settings, start.date(), apply=True, clock=lambda: forest["now"][0]
        )
    forest["now"][0] = start + timedelta(hours=12)
    return {
        **forest,
        "start": start,
        "headers": {**forest["headers"], "X-Forest-Expeditions": "1", "X-Forest-Recovery": "1"},
    }


def current(client, e):
    response = client.get("/v1/me/expeditions/current", headers=e["headers"])
    assert response.status_code == 200, response.text
    return response.json()["current"]


def evidence(client, e, run, days, workouts=None, request=None, status=200):
    body = {
        "requestId": str(request or uuid4()),
        "deviceId": e["device"],
        "installationId": e["installation"],
        "observedAt": e["now"][0].isoformat(),
        "days": days,
        "workouts": workouts or [],
    }
    response = client.post(
        f"/v1/me/expeditions/{run['runId']}/evidence", headers=e["headers"], json=body
    )
    assert response.status_code == status, response.text
    return response.json()


def day(start, steps, *, through=None):
    return {
        "gameDate": start.date().isoformat(),
        "startsAt": start.isoformat(),
        "through": (through or start + timedelta(days=1)).isoformat(),
        "steps": steps,
        "workoutsComplete": True,
    }


def quest(run, key):
    return next(q for q in run["quests"] if q["id"] == key)


def claim(client, e, run, entitlement, request=None, status=200):
    response = client.post(
        f"/v1/me/expeditions/{run['runId']}/rewards/{entitlement['id']}/claim",
        headers=e["headers"],
        json={"requestId": str(request or uuid4())},
    )
    assert response.status_code == status, response.text
    return response.json()


def economic_snapshot(app, e):
    with app.state.database.sessions() as session:
        wallet = session.get(VisitorWallet, e["owner"])
        progress = session.get(PlayerProgress, e["owner"])
        plant = session.get(OwnedPlant, UUID(e["plant"]))
        return (
            wallet.tokens,
            wallet.gems,
            wallet.lifetime_gems_earned,
            progress.activity_steps,
            plant.growth_micro_units,
            session.scalar(select(func.count()).select_from(WorkoutImport)),
            session.scalar(select(func.count()).select_from(ItemStepGrant)),
        )


def test_month_boundaries_are_server_utc_and_calendar_exact():
    for year, month, length in (
        (2027, 1, 31),
        (2027, 2, 28),
        (2028, 2, 29),
        (2027, 4, 30),
        (2027, 12, 31),
    ):
        start = datetime(year, month, 1, tzinfo=UTC)
        assert (expeditions.next_month(start) - start).days == length
        assert expeditions.month_start(start - timedelta(microseconds=1)) < start


def test_utc_renewal_preserves_claims_and_allows_same_item_again(expedition, app, client):
    e = expedition
    run = current(client, e)
    assert run["timezone"] == "UTC" and run["startsAt"].endswith("00:00:00+00:00")
    e["now"][0] = e["start"] + timedelta(days=3)
    evidence(client, e, run, [day(e["start"] + timedelta(days=i), 5000) for i in range(3)])
    run = current(client, e)
    ent = quest(run, "steps_days_3")["entitlement"]
    request = uuid4()
    first = claim(client, e, run, ent, request)
    assert len(first["ownedItemIds"]) == 1
    assert claim(client, e, run, ent, request) == first
    assert claim(client, e, run, ent)["ownedItemIds"] == first["ownedItemIds"]
    e["now"][0] = datetime.fromisoformat(run["endsAt"])
    new = current(client, e)
    assert new["runId"] != run["runId"] and new["completedCount"] == 0
    assert claim(client, e, run, ent)["ownedItemIds"] == first["ownedItemIds"]
    start = e["now"][0]
    e["now"][0] += timedelta(days=3)
    evidence(client, e, new, [day(start + timedelta(days=i), 5000) for i in range(3)])
    second = claim(client, e, new, quest(current(client, e), "steps_days_3")["entitlement"])
    assert second["ownedItemIds"] != first["ownedItemIds"]
    with app.state.database.sessions() as session:
        assert (
            session.scalar(
                select(func.count()).select_from(OwnedItem).where(OwnedItem.owner_id == e["owner"])
            )
            == 2
        )


def test_long_absence_recovers_first_date_without_economic_side_effects(expedition, app, client):
    e = expedition
    run = current(client, e)
    e["now"][0] = datetime.fromisoformat(run["endsAt"]) + timedelta(days=6, hours=23)
    before = economic_snapshot(app, e)
    for offset in range(0, (datetime.fromisoformat(run["endsAt"]) - e["start"]).days, 7):
        dates = [
            day(e["start"] + timedelta(days=i), 1000)
            for i in range(
                offset, min(offset + 7, (datetime.fromisoformat(run["endsAt"]) - e["start"]).days)
            )
        ]
        evidence(client, e, run, dates)
    assert economic_snapshot(app, e) == before
    archived = client.get(f"/v1/me/expeditions/{run['runId']}", headers=e["headers"]).json()
    assert quest(archived, "monthly_steps_30000")["current"] == min(
        (datetime.fromisoformat(run["endsAt"]) - e["start"]).days * 1000, 30000
    )
    evidence(client, e, run, [day(e["start"], 5000)])
    archived = client.get(f"/v1/me/expeditions/{run['runId']}", headers=e["headers"]).json()
    assert quest(archived, "steps_days_3")["current"] == 1
    e["now"][0] = datetime.fromisoformat(run["evidenceUntil"])
    evidence(client, e, run, [day(e["start"], 9000)], status=409)
    assert economic_snapshot(app, e) == before


def test_partial_day_highwater_overlap_and_original_request_recovery(expedition, app, client):
    e = expedition
    run = current(client, e)
    request = uuid4()
    payload = [day(e["start"], 4999, through=e["now"][0])]
    first = evidence(client, e, run, payload, request=request)
    assert evidence(client, e, run, payload, request=request) == first
    assert quest(current(client, e), "steps_days_3")["current"] == 0
    e["now"][0] += timedelta(hours=2)
    evidence(client, e, run, [day(e["start"], 5000, through=e["now"][0])])
    evidence(client, e, run, [day(e["start"], 2000, through=e["now"][0])])
    assert quest(current(client, e), "monthly_steps_30000")["current"] == 5000
    assert quest(current(client, e), "steps_days_3")["current"] == 1


@pytest.mark.parametrize(
    "kind,seconds,metres,expected",
    [
        (37, 600, "1999", 0),
        (37, 600, "2000", 1),
        (52, 899, None, 0),
        (52, 900, None, 1),
        (24, 1200, "3000", 0),
    ],
)
def test_recorded_workout_exact_thresholds(
    expedition, app, client, kind, seconds, metres, expected
):
    e = expedition
    run = current(client, e)
    start = e["start"] + timedelta(hours=1)
    workout = {
        "workoutId": str(uuid4()),
        "originalType": kind,
        "start": start.isoformat(),
        "end": (start + timedelta(seconds=seconds)).isoformat(),
        "durationMilliseconds": seconds * 1000,
        "distanceMetres": metres,
        "sourceBundleIdentifier": "com.example.watch",
        "wasUserEntered": False,
    }
    before = economic_snapshot(app, e)
    evidence(client, e, run, [day(e["start"], None, through=e["now"][0])], [workout])
    assert quest(current(client, e), "run_walk_sessions_3")["current"] == expected
    evidence(client, e, run, [day(e["start"], None, through=e["now"][0])], [workout])
    duplicate = {**workout, "workoutId": str(uuid4())}
    evidence(client, e, run, [day(e["start"], None, through=e["now"][0])], [duplicate])
    assert quest(current(client, e), "run_walk_sessions_3")["current"] == expected
    assert economic_snapshot(app, e) == before


def test_snapshot_completion_and_independent_four_nine_rewards(expedition, app, client):
    e = expedition
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == e["owner"]))
        ids = items.grant(
            session,
            e["owner"],
            "astronomers-satchel",
            1,
            source="fixture",
            reference="four",
            quantity=4,
        )
        for i, identifier in enumerate(ids):
            session.add(
                ItemPlacement(
                    item_id=identifier,
                    owner_id=e["owner"],
                    garden_id=garden.id,
                    x=i * 2,
                    y=0,
                    rotation_degrees=0,
                )
            )
    run = current(client, e)
    assert quest(run, "items_together_4")["completedAt"]
    with app.state.database.sessions.begin() as session:
        for row in session.scalars(
            select(ItemPlacement).where(ItemPlacement.owner_id == e["owner"])
        ):
            session.delete(row)
        r = session.get(ExpeditionRun, UUID(run["runId"]))
        for key, _, target, _ in __import__(
            "forest_api.expedition_definitions", fromlist=["QUESTS"]
        ).QUESTS:
            expeditions.set_progress(session, r, key, target, e["now"][0])
    run = current(client, e)
    assert run["completedCount"] == 9 and len(run["rewards"]) == 11
    assert not any(r["claimed"] for r in run["rewards"])
    for count, item_id in ((9, "worldseed-orrery"), (4, "comet-basin")):
        reward = next(r for r in run["rewards"] if r["rewardKey"] == f"milestone:{count}")
        receipt = claim(client, e, run, reward)
        with app.state.database.sessions() as session:
            assert session.get(ItemIdentity, UUID(receipt["ownedItemIds"][0])).item_id == item_id
    gem = quest(run, "packs_opened_3")["entitlement"]
    claim(client, e, run, gem)
    with app.state.database.sessions() as session:
        progression.reconcile(session, e["owner"], session.get(VisitorWallet, e["owner"]))
    with app.state.database.sessions() as session:
        recovery.maintain(session, apply=True, now=e["now"][0] + timedelta(days=40))
    assert claim(client, e, run, gem)["gemsEarned"] == "1"


def test_item_capacity_preserves_entitlement_and_same_request_retry(expedition, app, client):
    e = expedition
    run = current(client, e)
    with app.state.database.sessions.begin() as session:
        r = session.get(ExpeditionRun, UUID(run["runId"]))
        expeditions.set_progress(session, r, "steps_days_3", 3, e["now"][0])
    entitlement = quest(current(client, e), "steps_days_3")["entitlement"]
    original_limit = app.state.settings.item_capacity
    app.state.settings.item_capacity = 0
    request = uuid4()
    try:
        claim(client, e, run, entitlement, request, status=409)
    finally:
        app.state.settings.item_capacity = original_limit
    assert len(claim(client, e, run, entitlement, request)["ownedItemIds"]) == 1
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(ExpeditionClaim)) == 1


def test_orrery_uses_shared_once_daily_tiers_and_flat_water(expedition, app):
    from types import SimpleNamespace

    from forest_api.calculations import MICRO
    from forest_api.item_step_grants import settle_steps
    from forest_api.placement import DISABLED_ACCOUNTING

    e = expedition
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == e["owner"]))
        ids = items.grant(
            session,
            e["owner"],
            "worldseed-orrery",
            1,
            source="test",
            reference="orreries",
            quantity=2,
        )
        for i, identifier in enumerate(ids):
            session.add(
                ItemPlacement(
                    item_id=identifier,
                    owner_id=e["owner"],
                    garden_id=garden.id,
                    x=i * 3,
                    y=0,
                    rotation_degrees=0,
                )
            )
        session.flush()
        plant = session.get(OwnedPlant, UUID(e["plant"]))
        plant.growth_micro_units = 0
        presenter = services.PlantPresenter(session)
        presenter.preload([plant])
        snapshot = services.skill_snapshot(
            session, garden, presenter=presenter, boundary=e["now"][0]
        )
        assert (
            len([r for r in snapshot.summary()["activeSkills"] if r["id"] == "alignment_of_worlds"])
            == 1
        )
        daily = SimpleNamespace(game_date=e["now"][0].date(), newly_eligible_steps=6000)
        settle_steps(
            session,
            app.state.settings,
            garden,
            [plant],
            presenter,
            snapshot,
            [daily],
            e["now"][0],
            DISABLED_ACCOUNTING,
        )
        assert plant.growth_micro_units == 12 * MICRO
        assert session.scalar(select(func.count()).select_from(ItemStepGrant)) == 3
        settle_steps(
            session,
            app.state.settings,
            garden,
            [plant],
            presenter,
            snapshot,
            [daily],
            e["now"][0],
            DISABLED_ACCOUNTING,
        )
        assert plant.growth_micro_units == 12 * MICRO
        for row in session.scalars(
            select(ItemPlacement).where(ItemPlacement.owner_id == e["owner"])
        ):
            session.delete(row)
        session.flush()
        stored = services.skill_snapshot(session, garden, presenter=presenter, boundary=e["now"][0])
        assert not any(r["id"] == "alignment_of_worlds" for r in stored.summary()["activeSkills"])
        assert session.scalar(select(ItemStepState.steps)) == 6000


def test_guiding_glow_is_step_only_and_does_not_duplicate_stack(expedition, app):

    e = expedition
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == e["owner"]))
        ids = items.grant(
            session, e["owner"], "comet-basin", 1, source="test", reference="basins", quantity=2
        )
        for i, identifier in enumerate(ids):
            session.add(
                ItemPlacement(
                    item_id=identifier,
                    owner_id=e["owner"],
                    garden_id=garden.id,
                    x=i * 3,
                    y=0,
                    rotation_degrees=0,
                )
            )
        session.flush()
        snapshot = services.skill_snapshot(session, garden, boundary=e["now"][0])
        factors = snapshot.summary()["growthFactors"][0]
        assert factors["activityFactors"]["steps"] == "1.03"
        assert factors["activityFactors"].get("active_energy_kcal", "1") == "1"
        assert factors["waterFactor"] == "1"


def test_http_native_expedition_contract(expedition, app, client):
    import json
    import os
    from pathlib import Path

    from forest_api.expedition_definitions import QUESTS

    e = expedition
    initial = current(client, e)
    with app.state.database.sessions.begin() as session:
        r = session.get(ExpeditionRun, UUID(initial["runId"]))
        for key, _, target, _ in QUESTS:
            expeditions.set_progress(session, r, key, target, e["now"][0])
    earned = current(client, e)
    receipts = [claim(client, e, earned, reward) for reward in earned["rewards"]]
    restored = current(client, e)
    assert restored["completedCount"] == 9 and all(r["claimed"] for r in restored["rewards"])
    assert sum(int(r["tokensEarned"]) for r in receipts) == 1850
    assert sum(int(r["gemsEarned"]) for r in receipts) == 1
    assert sum(len(r["ownedItemIds"]) for r in receipts) == 3
    if os.environ.get("FOREST_EXPORT_EXPEDITIONS") == "1":
        target = (
            Path(__file__).resolve().parents[2]
            / "frontend/MovementForest/Resources/Fixtures/expeditions-contract.json"
        )
        target.write_text(
            json.dumps(
                {
                    "synthetic": True,
                    "initial": initial,
                    "earned": earned,
                    "restored": restored,
                    "receipts": receipts,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )


def test_fractional_device_baseline_uses_safe_native_wire_precision(expedition, app, client):
    from forest_api.models import ActivityDevice

    e = expedition
    with app.state.database.sessions.begin() as session:
        device = session.get(ActivityDevice, UUID(e["device"]))
        device.baseline_at = e["start"] + timedelta(hours=1, microseconds=123456)
    run = current(client, e)
    interval = run["coverage"][0]
    start = datetime.fromisoformat(interval["startsAt"])
    assert start.microsecond == 124000
    evidence(
        client,
        e,
        run,
        [
            {
                "gameDate": interval["gameDate"],
                "startsAt": start.isoformat(timespec="milliseconds"),
                "through": e["now"][0].isoformat(),
                "steps": 5000,
            }
        ],
    )
    assert quest(current(client, e), "steps_days_3")["current"] == 1


def test_future_replacement_pins_old_month_and_repeats_new_template(expedition, app, client):
    from copy import deepcopy

    from forest_api.expedition_models import ExpeditionTemplate

    e = expedition
    old = current(client, e)
    future = datetime.fromisoformat(old["endsAt"])
    with app.state.database.sessions() as session:
        data = deepcopy(session.get(ExpeditionTemplate, old["templateVersion"]).definition)
    data["name"] = "Observatory Revisited"
    replacement = {"version": "observatory-revisited-v2", "definition": data}
    with app.state.database.sessions() as session:
        report = expeditions.publish(
            session,
            app.state.settings,
            future.date(),
            apply=True,
            clock=lambda: e["now"][0],
            replacement=replacement,
        )
    assert report["recursMonthly"] and report["tokens"] == 1850
    e["now"][0] = future
    new = current(client, e)
    assert (
        new["name"] == "Observatory Revisited" and new["templateVersion"] != old["templateVersion"]
    )
    old_read = client.get(f"/v1/me/expeditions/{old['runId']}", headers=e["headers"]).json()
    assert old_read["templateVersion"] == old["templateVersion"]
    e["now"][0] = expeditions.next_month(future)
    assert current(client, e)["templateVersion"] == new["templateVersion"]


def test_morning_rain_stage_observer_pack_capacity_and_maintenance(expedition, app, client):
    from forest_api import history, item_catalogue
    from forest_api.calculations import MICRO
    from forest_api.models import GardenPlacement

    e = expedition
    e["headers"] = {**e["headers"], "X-Forest-Items": "1", "X-Forest-Item-Rotations": "1"}
    with app.state.database.sessions() as session:
        item_catalogue.publish(session, apply=True, clock=lambda: e["now"][0])
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == e["owner"]))
        for i in range(4):
            plant = services.award_plant(
                session, e["owner"], "oak", "standard", "fixture", f"rain-stage-{i}"
            )
            profile = services.PlantPresenter(session).profile(
                "growth", plant.growth_profile_id, plant.growth_profile_version
            )
            plant.growth_micro_units = profile.thresholds["seedling"] - MICRO
            session.add(
                GardenPlacement(
                    plant_id=plant.id,
                    owner_id=e["owner"],
                    garden_id=garden.id,
                    x=1 + i * 2,
                    y=5,
                    rotation_degrees=0,
                )
            )
        harp = items.grant(session, e["owner"], "rainharp", 1, source="fixture", reference="rain")[
            0
        ]
        session.add(
            ItemPlacement(
                item_id=harp, owner_id=e["owner"], garden_id=garden.id, x=8, y=8, rotation_degrees=0
            )
        )
    e["now"][0] += timedelta(days=1)
    response = client.get("/v1/me/garden", headers=e["headers"])
    assert response.status_code == 200, response.text
    run = current(client, e)
    reward = quest(run, "copies_advanced_4")["entitlement"]
    assert reward and quest(run, "copies_advanced_4")["current"] == 4
    original_limit = app.state.settings.pack_capacity
    app.state.settings.pack_capacity = 0
    request = uuid4()
    try:
        claim(client, e, run, reward, request, status=409)
    finally:
        app.state.settings.pack_capacity = original_limit
    receipt = claim(client, e, run, reward, request)
    assert len(receipt["packs"]) == 1 and receipt["packs"][0]["packId"] == "woodland"
    with app.state.database.sessions() as session:
        result = history.maintain(
            session,
            apply=True,
            responses=True,
            visitor_detail=True,
            growth_detail=True,
            now=e["now"][0] + timedelta(days=40),
        )
    assert isinstance(result, dict)
    assert claim(client, e, run, reward, request)["packs"] == receipt["packs"]
