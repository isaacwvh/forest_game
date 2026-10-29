"""PostgreSQL discovery persistence, authoritative growth, retries and upgrade preservation."""

import copy
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from alembic import command
from alembic.script import ScriptDirectory
from conftest import migration_config, migration_url
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError

from forest_api import discovery, services
from forest_api.models import (
    BehaviourProfile,
    CatalogDiscoveryState,
    CatalogStageDiscovery,
    EconomyConfig,
    Garden,
    GardenPlacement,
    GrowthProfile,
    OwnedPlant,
    Species,
)
from forest_api.schemas import BehaviourDefinition

NOW = datetime(2026, 10, 29, 4, tzinfo=UTC)
PATH = "/v1/me/catalog-discovery"


@pytest.fixture
def world(app, client, register, headers):
    now = [NOW]
    app.state.clock = lambda: now[0]
    account = register()
    installation = str(uuid4())
    response = client.post(
        "/v1/activity/enrolments",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "installationId": installation,
            "observedAt": NOW.isoformat(),
            "steps": 0,
        },
    )
    assert response.status_code == 200, response.text
    placed = client.post(
        "/v1/me/garden/edits",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [
                {
                    "action": "plant",
                    "plantId": account["starterPlantId"],
                    "x": 2,
                    "y": 2,
                    "rotationDegrees": 0,
                }
            ],
        },
    )
    assert placed.status_code == 200, placed.text
    return dict(
        now=now,
        owner=UUID(account["profile"]["userId"]),
        plant=UUID(account["starterPlantId"]),
        installation=installation,
        device=response.json()["device"]["deviceId"],
    )


def payload(world, steps):
    return {
        "requestId": str(uuid4()),
        "installationId": world["installation"],
        "deviceId": world["device"],
        "observedAt": world["now"][0].isoformat(),
        "days": [{"gameDate": world["now"][0].date().isoformat(), "steps": steps}],
    }


def snapshot(client, headers, subject="alice"):
    response = client.get(PATH, headers=headers(subject))
    assert response.status_code == 200, response.text
    return response.json()


def test_empty_owner_snapshot_and_authentication(client, headers, register):
    account = register()
    assert client.get(PATH).status_code == 401
    assert snapshot(client, headers) == {
        "userId": account["profile"]["userId"],
        "catalogVersion": "development-oak-v1",
        "discoveryVersion": 0,
        "entries": [],
    }
    assert client.post(PATH, headers=headers(), json={}).status_code == 405


@pytest.mark.parametrize(
    ("steps", "stages"),
    [
        (9999, []),
        (10000, ["seedling"]),
        (39999, ["seedling"]),
        (40000, ["seedling", "young"]),
        (99999, ["seedling", "young"]),
        (100000, ["seedling", "young", "adult"]),
    ],
)
def test_exact_growth_thresholds_and_intermediate_stages(world, client, headers, steps, stages):
    response = client.post("/v1/activity/sync", headers=headers(), json=payload(world, steps))
    assert response.status_code == 200, response.text
    result = snapshot(client, headers)
    assert result["discoveryVersion"] == int(bool(stages))
    assert result["entries"] == (
        [{"speciesId": "oak", "variantId": "standard", "stages": stages}] if stages else []
    )


def test_variant_duplicates_storage_and_account_isolation(world, app, client, headers, register):
    register("bob")
    body = payload(world, 100000)
    first = client.post("/v1/activity/sync", headers=headers(), json=body)
    assert first.status_code == 200, first.text
    assert client.post("/v1/activity/sync", headers=headers(), json=body).json() == first.json()
    assert snapshot(client, headers)["discoveryVersion"] == 1
    with app.state.database.sessions.begin() as session:
        blue = services.award_plant(session, world["owner"], "oak", "blue", "test", "blue")
        services.award_plant(session, world["owner"], "oak", "standard", "test", "duplicate")
        session.add(
            GardenPlacement(
                plant_id=blue.id,
                owner_id=world["owner"],
                garden_id=session.scalar(
                    select(Garden.id).where(Garden.owner_id == world["owner"])
                ),
                x=4,
                y=2,
                rotation_degrees=0,
            )
        )
    assert snapshot(client, headers, "bob")["entries"] == []
    world["now"][0] += timedelta(days=1)
    response = client.post("/v1/activity/sync", headers=headers(), json=payload(world, 10000))
    assert response.status_code == 200, response.text
    result = snapshot(client, headers)
    assert result["discoveryVersion"] == 2
    assert result["entries"] == [
        {"speciesId": "oak", "variantId": "blue", "stages": ["seedling"]},
        {"speciesId": "oak", "variantId": "standard", "stages": ["seedling", "young", "adult"]},
    ]
    stored = client.post(
        "/v1/me/garden/edits",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 1,
            "catalogVersion": "development-oak-v1",
            "actions": [{"action": "store", "plantId": str(world["plant"])}],
        },
    )
    assert stored.status_code == 200, stored.text
    assert snapshot(client, headers) == result


def test_concurrent_and_zero_change_syncs_do_not_mint_discovery_versions(
    world, app, client, headers
):
    bodies = [payload(world, 40000), payload(world, 40000)]
    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(
            workers.map(
                lambda body: client.post("/v1/activity/sync", headers=headers(), json=body), bodies
            )
        )
    assert [result.status_code for result in results] == [200, 200]
    assert snapshot(client, headers)["discoveryVersion"] == 1
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(CatalogStageDiscovery)) == 2


def test_discovery_and_growth_rollback_together(world, app, client, headers, monkeypatch):
    record = discovery.record_reached

    def fail_after_insert(*args, **kwargs):
        record(*args, **kwargs)
        raise RuntimeError("forced discovery rollback")

    body = payload(world, 100000)
    with monkeypatch.context() as patch:
        patch.setattr(discovery, "record_reached", fail_after_insert)
        with pytest.raises(RuntimeError, match="forced discovery rollback"):
            client.post("/v1/activity/sync", headers=headers(), json=body)
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, world["plant"]).growth_micro_units == 0
        assert session.get(CatalogDiscoveryState, world["owner"]).version == 0
        assert session.scalar(select(func.count()).select_from(CatalogStageDiscovery)) == 0
    assert client.post("/v1/activity/sync", headers=headers(), json=body).status_code == 200
    assert snapshot(client, headers)["discoveryVersion"] == 1


def test_upgrade_uses_all_stored_pinned_copies_and_is_repeat_safe(app, client, headers, register):
    first, second = register(), register("bob")
    owner = UUID(first["profile"]["userId"])
    with app.state.database.sessions.begin() as session:
        # The progressed copy is deliberately after more than one inventory page of sprouts.
        for index in range(35):
            services.award_plant(session, owner, "oak", "standard", "test", str(index))
        for variant, growth in [
            ("standard", 200_000_000),
            ("blue", 1_000_000_000),
            ("vined", 400_000_000),
        ]:
            plant = services.award_plant(session, owner, "oak", variant, "test", variant)
            plant.growth_micro_units = growth
        session.add(
            GrowthProfile(
                id="future_default",
                version=1,
                thresholds={
                    "sprout": 0,
                    "seedling": 800_000_000,
                    "young": 900_000_000,
                    "adult": 1_000_000_000,
                },
                maximum_growth_micro_units=1_000_000_000,
            )
        )
        session.flush()
        session.get(Species, "oak").growth_profile_id = "future_default"
    engine = app.state.database.engine
    with migration_url(app.state.settings.database_url.get_secret_value()):
        configuration = migration_config()
        command.downgrade(configuration, "0008_scheduled_visitors")
        with engine.connect() as connection:
            before = {
                table: connection.execute(
                    text(f"SELECT to_jsonb(t) FROM {table} t ORDER BY id")
                ).all()
                for table in ["users", "gardens", "owned_plants"]
            }
        command.upgrade(configuration, "head")
        command.check(configuration)
        with engine.connect() as connection:
            assert before == {
                table: connection.execute(
                    text(f"SELECT to_jsonb(t) FROM {table} t ORDER BY id")
                ).all()
                for table in before
            }
        result = snapshot(client, headers)
        assert result["discoveryVersion"] == 1
        assert result["entries"] == [
            {"speciesId": "oak", "variantId": "blue", "stages": ["seedling", "young", "adult"]},
            {"speciesId": "oak", "variantId": "standard", "stages": ["seedling"]},
            {"speciesId": "oak", "variantId": "vined", "stages": ["seedling", "young"]},
        ]
        assert snapshot(client, headers, "bob") == {
            "userId": second["profile"]["userId"],
            "catalogVersion": "development-oak-v1",
            "discoveryVersion": 0,
            "entries": [],
        }
        revision = ScriptDirectory.from_config(configuration).get_revision("0009_catalog_discovery")
        with engine.begin() as connection:
            revision.module.backfill(connection)
        assert snapshot(client, headers) == result
        with pytest.raises(RuntimeError, match="Earned catalog discoveries"):
            command.downgrade(configuration, "0008_scheduled_visitors")


@pytest.mark.parametrize("stage", ["sprout", "missing", "adult"])
def test_database_rejects_invalid_stage_or_variant(app, register, stage):
    account = register()
    with pytest.raises(IntegrityError), app.state.database.sessions.begin() as session:
        session.add(
            CatalogStageDiscovery(
                owner_id=UUID(account["profile"]["userId"]),
                species_id="oak",
                variant_id="missing" if stage == "adult" else "standard",
                stage=stage,
            )
        )


def test_shared_wire_fixture_is_valid():
    path = (
        Path(__file__).resolve().parents[2]
        / "frontend/MovementForest/Resources/Fixtures/catalog-discovery-contract.json"
    )
    fixture = json.loads(path.read_text())
    for value in fixture.values():
        parsed = discovery.DiscoverySnapshot.model_validate(value)
        assert parsed.model_dump(mode="json", by_alias=True) == value


@pytest.mark.parametrize(
    ("metric", "field", "quantity"),
    [
        ("walking_running_distance_km", "walkingRunningDistanceMetres", "1000.000"),
        ("active_energy_kcal", "activeEnergyKcal", "1.000"),
        ("flights_climbed", "flightsClimbed", 1),
        ("workout_minutes.running", "workout", None),
    ],
)
def test_optional_metrics_and_workout_use_same_discovery_transaction(
    world, app, client, headers, metric, field, quantity
):
    with app.state.database.sessions.begin() as session:
        rules = copy.deepcopy(session.get(EconomyConfig, "development-neutral-v1").rules)
        rules["metrics"][metric] = {"normalisation": "1", "water_micro_units": 100_000_000}
        session.add(
            EconomyConfig(
                version="discovery-input",
                effective_at=datetime(1971, 1, 1, tzinfo=UTC),
                is_fixture=True,
                rules=rules,
            )
        )
        session.add(
            BehaviourProfile(
                id="discovery-input",
                version=1,
                rules=BehaviourDefinition(metric_multipliers={metric: 1}).model_dump(
                    mode="json", by_alias=True
                ),
            )
        )
        session.flush()
        plant = session.get(OwnedPlant, world["plant"])
        plant.behaviour_profile_id = "discovery-input"
        plant.behaviour_profile_version = 1
    # The device already has a steps baseline. Optional inputs establish their own
    # baseline on first observation; another enrolment must not reset that device.
    baseline = payload(world, 0)
    baseline["workoutsAvailable"] = True
    baseline["days"][0].update(
        walkingRunningDistanceMetres="0.000", activeEnergyKcal="0.000", flightsClimbed=0
    )
    response = client.post("/v1/activity/sync", headers=headers(), json=baseline)
    assert response.status_code == 200, response.text
    world["now"][0] += timedelta(minutes=2)
    body = payload(world, 0)
    if field == "workout":
        body.update(
            workoutsAvailable=True,
            workouts=[
                {
                    "workoutId": str(uuid4()),
                    "sourceBundleIdentifier": "example.discovery",
                    "originalType": 37,
                    "start": (NOW + timedelta(seconds=1)).isoformat(),
                    "end": (NOW + timedelta(seconds=61)).isoformat(),
                    "durationMilliseconds": 60000,
                }
            ],
        )
    else:
        body["days"][0][field] = quantity
    response = client.post("/v1/activity/sync", headers=headers(), json=body)
    assert response.status_code == 200, response.text
    assert snapshot(client, headers)["entries"] == [
        {"speciesId": "oak", "variantId": "standard", "stages": ["seedling"]}
    ]
