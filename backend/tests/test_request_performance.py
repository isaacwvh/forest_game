"""Real PostgreSQL contracts and bounded round trips for the hosted hot paths."""

from concurrent.futures import ThreadPoolExecutor
from threading import Event

from fastapi.testclient import TestClient
from sqlalchemy import select
from test_item_rotations import rotating as rotating
from test_placement import edit_body, plant_action
from test_placement import garden_setup as garden_setup

from forest_api import services
from forest_api.garden_strategy import strategy_signature
from forest_api.models import GameCatalogue, Garden, GardenPlacement, Species, Variant

SNAPSHOT = "/v1/me/garden/snapshot"
EDITS = "/v1/me/garden/edits"


def capable(headers, **extra):
    return {**headers(), "X-Forest-Snapshot": "1", "X-Forest-Items": "1", **extra}


def test_catalogue_queries_are_bounded_as_variants_grow(app, client, headers):
    app.state.metrics.enabled = True
    before = client.get("/v1/catalog", headers=headers())
    assert before.status_code == 200
    original_queries = app.state.metrics.samples[-1]["queries"]
    assert original_queries <= 7
    with app.state.database.sessions.begin() as session:
        source = session.get(Variant, ("oak", "standard"))
        stages = list(
            session.scalars(
                select(services.PlantStage).where(
                    services.PlantStage.species_id == "oak",
                    services.PlantStage.variant_id == "standard",
                )
            )
        )
        for number in range(20):
            identifier = f"performance-{number}"
            session.add(
                Variant(
                    **{
                        column.name: identifier
                        if column.name == "variant_id"
                        else getattr(source, column.name)
                        for column in Variant.__table__.columns
                    }
                )
            )
            session.flush()
            for stage in stages:
                session.add(
                    services.PlantStage(
                        **{
                            column.name: identifier
                            if column.name == "variant_id"
                            else getattr(stage, column.name)
                            for column in services.PlantStage.__table__.columns
                        }
                    )
                )
    after = client.get("/v1/catalog", headers=headers())
    assert after.status_code == 200, after.text
    assert app.state.metrics.samples[-1]["queries"] == original_queries
    oak = next(s for s in after.json()["species"] if s["speciesId"] == "oak")
    assert len(oak["variants"]) >= 20
    assert all(len(v["stages"]) == 4 for v in oak["variants"])


def test_catalogue_cache_is_versioned_defensive_and_never_bypasses_fixture_guard(
    app, client, headers
):
    app.state.settings.catalogue_cache_seconds = 60
    app.state.metrics.enabled = True
    first = client.get("/v1/catalog", headers=headers())
    assert first.status_code == 200
    assert app.state.metrics.samples[-1]["queries"] <= 7
    assert client.get("/v1/catalog", headers=headers()).json() == first.json()
    assert app.state.metrics.samples[-1]["queries"] == 1
    with app.state.database.sessions() as session:
        value = services.read_catalogue(session, app.state.settings)
        value.species.clear()
    assert client.get("/v1/catalog", headers=headers()).json() == first.json()
    with app.state.database.sessions.begin() as session:
        session.get(GameCatalogue, 1).version = "performance-published-v2"
        session.get(Species, "oak").description = "Updated published description"
    updated = client.get("/v1/catalog", headers=headers())
    assert updated.json()["catalogVersion"] == "performance-published-v2"
    assert any(
        s["description"] == "Updated published description" for s in updated.json()["species"]
    )
    credentials = headers()
    app.state.settings.environment = "production"
    assert (
        client.get("/v1/catalog", headers=credentials).json()["error"]["code"]
        == "fixture_catalogue_disabled"
    )


def test_snapshot_matches_existing_reads_and_omits_only_known_catalogue(
    client, headers, garden_setup
):
    account, _, first, _ = garden_setup
    credentials = capable(headers)
    response = client.get(SNAPSHOT, headers=credentials)
    assert response.status_code == 200, response.text
    assert response.headers["Cache-Control"] == "no-store"
    snapshot = response.json()
    assert snapshot["profile"] == account["profile"]
    for key, endpoint in (
        ("garden", "/v1/me/garden"),
        ("inventory", "/v1/me/inventory"),
        ("itemInventory", "/v1/me/items"),
        ("catalogue", "/v1/catalog"),
    ):
        assert snapshot[key] == client.get(endpoint, headers=credentials).json()
    assert str(first) in {p["plantId"] for p in snapshot["inventory"]["plants"]}
    known = client.get(
        SNAPSHOT,
        headers=credentials,
        params={"catalogVersion": snapshot["garden"]["catalogVersion"]},
    )
    assert known.json()["catalogue"] is None
    unknown = client.get(SNAPSHOT, headers=credentials, params={"catalogVersion": "old"})
    assert unknown.json()["catalogue"] == snapshot["catalogue"]


def test_snapshot_keeps_account_boundaries_and_requires_auth(client, headers, register):
    alice, bob = register(), register("bob")
    assert client.get(SNAPSHOT).status_code == 401
    for subject, account in (("alice", alice), ("bob", bob)):
        snapshot = client.get(SNAPSHOT, headers=headers(subject)).json()
        assert snapshot["profile"]["userId"] == account["profile"]["userId"]
        assert [p["plantId"] for p in snapshot["inventory"]["plants"]] == [
            account["starterPlantId"]
        ]
    assert (
        client.get(SNAPSHOT, headers=headers("unknown")).json()["error"]["code"]
        == "account_required"
    )


def test_fresh_save_has_atomic_inventory_but_replay_is_explicit(app, client, headers, garden_setup):
    _, owner, first, _ = garden_setup
    credentials = capable(headers)
    body = edit_body(plant_action(first))
    response = client.post(EDITS, headers=credentials, json=body)
    assert response.status_code == 200, response.text
    saved = response.json()
    assert saved["replayed"] is False
    assert str(first) not in {p["plantId"] for p in saved["inventory"]["plants"]}
    assert saved["inventory"]["capacity"]["plantedPlants"] == len(saved["garden"]["plants"])
    assert saved["itemInventory"] == client.get("/v1/me/items", headers=credentials).json()
    later = client.post(
        EDITS,
        headers=credentials,
        json=edit_body({"action": "store", "plantId": str(first)}, version=1),
    )
    assert later.status_code == 200
    replay = client.post(EDITS, headers=credentials, json=body).json()
    assert replay["replayed"] is True
    assert replay["garden"] == saved["garden"]  # historical, never advertised as fresh
    assert client.get(SNAPSHOT, headers=credentials).json()["garden"]["layoutVersion"] == 2
    with app.state.database.sessions() as session:
        assert session.scalar(select(Garden).where(Garden.owner_id == owner)).layout_version == 2


def test_legacy_save_still_replays_exactly(client, headers, garden_setup):
    _, _, first, _ = garden_setup
    body = edit_body(plant_action(first))
    original = client.post(EDITS, headers=headers(), json=body)
    assert original.status_code == 200
    assert original.json()["inventory"] is None
    assert client.post(EDITS, headers=headers(), json=body).json() == original.json()


def test_one_request_save_checks_reviewed_effects_and_replay_identity(
    app, client, headers, garden_setup
):
    _, _, first, _ = garden_setup
    credentials = capable(headers)
    body = edit_body(plant_action(first))
    preview = client.post("/v1/me/garden/preview", headers=credentials, json=body).json()
    body["expectedStrategySignature"] = strategy_signature(preview)
    invalid = {**body, "expectedStrategySignature": "wrong"}
    rejected = client.post(EDITS, headers=credentials, json=invalid)
    assert rejected.status_code == 409
    assert rejected.json()["error"]["code"] == "strategy_changed"
    assert client.get(SNAPSHOT, headers=credentials).json()["garden"]["layoutVersion"] == 0
    saved = client.post(EDITS, headers=credentials, json=body)
    assert saved.status_code == 200, saved.text
    assert saved.json()["replayed"] is False
    assert client.post(EDITS, headers=credentials, json=body).json()["replayed"] is True
    conflict = client.post(EDITS, headers=credentials, json=invalid)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"


def test_signature_extension_preserves_legacy_hash_and_has_bounded_size():
    from forest_api.schemas import GardenEditRequest

    body = edit_body(plant_action("00000000-0000-0000-0000-000000000001"))
    old = GardenEditRequest.model_validate(body)
    neutral = GardenEditRequest.model_validate({**body, "expectedStrategySignature": None})
    assert services.request_hash("garden_edits", old) == services.request_hash(
        "garden_edits", neutral
    )
    import pytest

    with pytest.raises(ValueError):
        GardenEditRequest.model_validate({**body, "expectedStrategySignature": "x" * 32769})


def test_snapshot_waits_for_edit_and_returns_one_coherent_layout(
    app, client, headers, garden_setup
):
    _, owner, first, _ = garden_setup
    entered = Event()

    def read():
        entered.set()
        with TestClient(app) as other:
            return other.get(SNAPSHOT, headers=capable(headers))

    # Commit a placement while the reader is waiting on the same account lock.
    with ThreadPoolExecutor(1) as pool:
        with app.state.database.sessions.begin() as session:
            user = session.scalar(
                select(services.User).where(services.User.id == owner).with_for_update()
            )
            garden = services.lock_garden(session, user.id, write=True)
            future = pool.submit(read)
            assert entered.wait(5)
            session.add(
                GardenPlacement(
                    plant_id=first,
                    owner_id=owner,
                    garden_id=garden.id,
                    x=2,
                    y=2,
                    rotation_degrees=0,
                )
            )
            garden.layout_version += 1
            garden.state_version += 1
        snapshot = future.result(timeout=10).json()
    assert snapshot["garden"]["layoutVersion"] == 1
    assert [p["plantId"] for p in snapshot["garden"]["plants"]] == [str(first)]
    assert str(first) not in {p["plantId"] for p in snapshot["inventory"]["plants"]}


def test_maintenance_admission_remains_fail_closed_with_fewer_round_trips(
    app, client, headers, register
):
    register()
    app.state.settings.maintenance_gate_enabled = True
    app.state.metrics.enabled = True
    response = client.get("/v1/me", headers=headers())
    assert response.status_code == 200
    # Two admissions (settings+try-lock, control read), plus the profile query.
    assert app.state.metrics.samples[-1]["queries"] == 5


def test_published_content_snapshot_uses_less_sql_than_separate_reads(rotating):
    """Query-count budgets survive network changes; elapsed time is diagnostic."""
    import json

    app, client = rotating["app"], rotating["client"]
    app.state.settings.maintenance_gate_enabled = True
    app.state.settings.catalogue_cache_seconds = 60
    app.state.metrics.enabled = True
    credentials = {**rotating["headers"], "X-Forest-Snapshot": "1"}
    legacy = []
    for path in (
        "/v1/catalog",
        "/v1/me/garden",
        "/v1/me/inventory",
        "/v1/me/items",
        "/v1/me/garden",
    ):
        response = client.get(path, headers=credentials)
        assert response.status_code == 200, response.text
        legacy.append(dict(app.state.metrics.samples[-1]))
    modern = client.get(SNAPSHOT, headers=credentials)
    assert modern.status_code == 200, modern.text
    snapshot = dict(app.state.metrics.samples[-1])
    assert snapshot["queries"] < sum(sample["queries"] for sample in legacy) / 2
    assert snapshot["queries"] <= 45
    body = edit_body(plant_action(rotating["plant"]))
    preview = client.post("/v1/me/garden/preview", headers=credentials, json=body)
    assert preview.status_code == 200, preview.text
    body["expectedStrategySignature"] = strategy_signature(preview.json())
    saved = client.post(EDITS, headers=credentials, json=body)
    assert saved.status_code == 200, saved.text
    save = dict(app.state.metrics.samples[-1])
    assert save["queries"] <= 100
    print(
        "REQUEST_BENCHMARK "
        + json.dumps(
            {
                "legacyRefresh": {
                    "requests": 5,
                    "queries": sum(s["queries"] for s in legacy),
                    "serverMs": sum(s["requestMs"] for s in legacy),
                },
                "snapshot": snapshot,
                "save": save,
            }
        )
    )
