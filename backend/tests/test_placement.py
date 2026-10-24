import json
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from decimal import Decimal
from threading import Barrier, Event
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from forest_api import placement, services
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.errors import ApiError
from forest_api.main import create_app
from forest_api.models import (
    ApiRequest,
    GameCatalogue,
    Garden,
    GardenPlacement,
    OwnedPlant,
    Species,
)
from forest_api.schemas import GardenEditRequest

ENDPOINT = "/v1/me/garden/edits"


def plant_action(plant_id, **changes):
    return {
        "action": "plant",
        "plantId": str(plant_id),
        "x": 2,
        "y": 2,
        "rotationDegrees": 0,
        **changes,
    }


def edit_body(*actions, version=0, **changes):
    return {
        "requestId": str(uuid4()),
        "expectedLayoutVersion": version,
        "catalogVersion": "development-oak-v1",
        "actions": list(actions),
        **changes,
    }


@pytest.fixture
def garden_setup(register, app):
    account = register()
    owner = UUID(account["profile"]["userId"])
    first = UUID(account["starterPlantId"])
    with app.state.database.sessions.begin() as session:
        second = services.award_plant(session, owner, "oak", "blue", "test", str(uuid4())).id
    return account, owner, first, second


def post(client, headers, body):
    return client.post(ENDPOINT, headers=headers(), json=body)


def test_plant_move_rotate_store_replant_preserves_all_owned_state(
    client, app, headers, garden_setup
):
    account, owner, first, _ = garden_setup
    with app.state.database.sessions.begin() as session:
        plant = session.get(OwnedPlant, first)
        plant.growth_micro_units = 580_000_000
        plant.fractional_state = {"steps": "0.25"}
    original = client.get(f"/v1/me/plants/{first}", headers=headers()).json()
    result = post(
        client, headers, edit_body(plant_action(first, x=0.9, y=9.1, rotationDegrees=359.99))
    )
    assert result.status_code == 200, result.text
    assert result.json()["garden"]["layoutVersion"] == 1
    assert result.json()["garden"]["stateVersion"] == 1
    assert result.json()["updatedPlants"][0]["growthStage"] == "young"
    assert len(client.get("/v1/me/inventory", headers=headers()).json()["plants"]) == 1
    commands = [
        {"action": "move", "plantId": str(first), "x": 3.201, "y": 4.609},
        {"action": "rotate", "plantId": str(first), "rotationDegrees": 35.12},
        {"action": "store", "plantId": str(first)},
        plant_action(first, x=3.201, y=4.609, rotationDegrees=35.12),
    ]
    for version, action in enumerate(commands, start=1):
        response = post(client, headers, edit_body(action, version=version))
        assert response.status_code == 200, response.text
        assert response.json()["garden"]["layoutVersion"] == version + 1
        updated = response.json()["updatedPlants"][0]
        for field in (
            "plantId",
            "speciesId",
            "variantId",
            "pinnedProfiles",
            "growthMicroUnits",
            "growthStage",
            "modelKey",
            "thumbnailKey",
        ):
            assert updated[field] == original[field]
        if action["action"] == "move":
            assert updated["placement"]["rotationDegrees"] == 359.99
        if action["action"] == "store":
            assert updated["placement"] is None
            assert updated["contributesAttraction"] is False
            assert response.json()["garden"]["plants"] == []
    with app.state.database.sessions() as session:
        plant = session.get(OwnedPlant, first)
        assert plant.owner_id == owner
        assert plant.fractional_state == {"steps": "0.25"}
        assert plant.first_matured_at is None
        assert session.get(GardenPlacement, first).garden_id == UUID(account["gardenId"])


def test_batch_swap_and_exact_tangent_layout_validate_final_state(client, headers, garden_setup):
    _, _, first, second = garden_setup
    response = post(client, headers, edit_body(plant_action(first), plant_action(second, x=3.8)))
    assert response.status_code == 200, response.text
    response = post(
        client,
        headers,
        edit_body(
            {"action": "move", "plantId": str(first), "x": 3.8, "y": 2, "rotationDegrees": 45},
            {"action": "move", "plantId": str(second), "x": 2, "y": 2},
            version=1,
        ),
    )
    assert response.status_code == 200, response.text
    by_id = {plant["plantId"]: plant for plant in response.json()["garden"]["plants"]}
    assert by_id[str(first)]["placement"]["x"] == 3.8
    assert by_id[str(second)]["placement"]["x"] == 2
    assert response.json()["garden"]["layoutVersion"] == 2
    assert response.json()["garden"]["stateVersion"] == 2


@pytest.mark.parametrize(
    "actions,error",
    [
        (lambda a, b: [plant_action(a), plant_action(b, x=3.799)], "clearance_overlap"),
        (lambda a, b: [plant_action(a), plant_action(b, x=0.899)], "out_of_bounds"),
    ],
)
def test_invalid_batch_has_no_partial_writes(client, app, headers, garden_setup, actions, error):
    _, _, first, second = garden_setup
    body = edit_body(*actions(first, second))
    response = post(client, headers, body)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == error
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(GardenPlacement)) == 0
        assert session.scalar(select(Garden.layout_version)) == 0
        assert session.scalar(select(Garden.state_version)) == 0
        assert session.get(ApiRequest, (garden_setup[1], UUID(body["requestId"]))) is None


@pytest.mark.parametrize(
    "action,field,value",
    [
        ("plant", "x", 1.0001),
        ("plant", "x", -1),
        ("plant", "x", True),
        ("plant", "x", "2"),
        ("plant", "x", None),
        ("plant", "x", 1000000),
        ("plant", "y", 2.0001),
        ("plant", "rotationDegrees", 1.001),
        ("plant", "rotationDegrees", 360),
        ("plant", "rotationDegrees", -0.01),
        ("plant", "rotationDegrees", False),
        ("move", "rotationDegrees", None),
    ],
)
def test_invalid_numeric_input_never_reaches_database(
    client, headers, garden_setup, action, field, value
):
    _, _, first, _ = garden_setup
    command = plant_action(first)
    command.update(action=action)
    command[field] = value
    response = post(client, headers, edit_body(command))
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "invalid_request"


@pytest.mark.parametrize(
    "token",
    [
        "1.00000000000000000001",
        "1e-1000",
        "NaN",
        "Infinity",
        "-Infinity",
        "1e999999",
        "1e99999999999999999999999999999999999999",
        "1" * 65,
    ],
)
def test_raw_json_precision_and_nonfinite_numbers_cannot_be_rounded_away(
    client, headers, garden_setup, token
):
    body = json.dumps(edit_body(plant_action(garden_setup[2], x="EXACT_NUMBER")))
    body = body.replace('"EXACT_NUMBER"', token)
    response = client.post(
        ENDPOINT, content=body, headers={**headers(), "Content-Type": "application/json"}
    )
    assert response.status_code == 422, response.text


@pytest.mark.parametrize(
    "change",
    [
        {"actions": []},
        {"expectedLayoutVersion": True},
        {"expectedLayoutVersion": 0.0},
        {"expectedLayoutVersion": -1},
        {"ownerId": str(uuid4())},
        {"requestId": "bad"},
        {"catalogVersion": ""},
    ],
)
def test_invalid_batch_envelopes(client, headers, garden_setup, change):
    response = post(client, headers, edit_body(plant_action(garden_setup[2]), **change))
    assert response.status_code == 422


def test_duplicate_actions_and_client_radius_are_rejected(client, headers, garden_setup):
    first = garden_setup[2]
    for actions in (
        [plant_action(first), plant_action(first)],
        [plant_action(first, clearanceRadius=0.01)],
        [plant_action(first, action="unknown")],
        [plant_action(first)] * 101,
    ):
        assert post(client, headers, edit_body(*actions)).status_code == 422


@pytest.mark.parametrize("body", ["{", '{"actions": [], "actions": []}', "[[]]"])
def test_malformed_or_duplicate_json_fields(client, headers, body):
    response = client.post(
        ENDPOINT, content=body, headers={**headers(), "Content-Type": "application/json"}
    )
    assert response.status_code == 422


def test_body_size_is_bounded_and_swagger_has_a_typed_request(client, headers):
    response = client.post(
        ENDPOINT, content=" " * 65537, headers={**headers(), "Content-Type": "application/json"}
    )
    assert response.status_code == 413
    schema = client.get("/openapi.json").json()
    request = schema["paths"][ENDPOINT]["post"]["requestBody"]
    assert request["content"]["application/json"]["schema"]["$ref"].endswith("GardenEditRequest")
    for name in ("PlantAction", "MoveAction"):
        props = schema["components"]["schemas"][name]["properties"]
        assert props["x"]["type"] == "number"
        assert props["x"]["multipleOf"] == 0.001
        assert props["rotationDegrees"]["type"] == "number"
        assert props["rotationDegrees"]["multipleOf"] == 0.01
    assert client.post(ENDPOINT, json=edit_body(plant_action(uuid4()))).status_code == 401


def test_replay_precedes_stale_layout_catalogue_and_changed_membership(
    client, app, headers, garden_setup
):
    _, _, first, _ = garden_setup
    body = edit_body(plant_action(first))
    original = post(client, headers, body).json()
    assert post(client, headers, body).json() == original
    assert (
        post(
            client, headers, edit_body({"action": "store", "plantId": str(first)}, version=1)
        ).status_code
        == 200
    )
    with app.state.database.sessions.begin() as session:
        session.get(GameCatalogue, 1).version = "new-catalogue"
    assert post(client, headers, body).json() == original
    altered = {**body, "actions": [plant_action(first, x=5)]}
    conflict = post(client, headers, altered)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "idempotency_conflict"
    reopened = create_app(client.app.state.settings)
    with TestClient(reopened) as restarted:
        assert post(restarted, headers, body).json() == original


def test_request_id_is_shared_across_operations(client, headers, garden_setup):
    body = edit_body(plant_action(garden_setup[2]))
    assert post(client, headers, body).status_code == 200
    response = client.patch(
        "/v1/me",
        json={"requestId": body["requestId"], "displayName": "Other operation"},
        headers=headers(),
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "idempotency_conflict"


def test_noop_records_receipt_without_advancing_versions(client, app, headers, garden_setup):
    _, owner, first, _ = garden_setup
    assert post(client, headers, edit_body(plant_action(first))).status_code == 200
    body = edit_body({"action": "move", "plantId": str(first), "x": 2, "y": 2}, version=1)
    result = post(client, headers, body)
    assert result.status_code == 200
    assert result.json()["garden"]["layoutVersion"] == 1
    assert result.json()["garden"]["stateVersion"] == 1
    assert post(client, headers, body).json() == result.json()
    with app.state.database.sessions() as session:
        assert session.get(ApiRequest, (owner, UUID(body["requestId"]))) is not None


def test_layout_and_state_versions_are_independent(client, app, headers, garden_setup):
    with app.state.database.sessions.begin() as session:
        session.get(Garden, UUID(garden_setup[0]["gardenId"])).state_version = 7
    response = post(client, headers, edit_body(plant_action(garden_setup[2])))
    assert response.status_code == 200
    assert response.json()["garden"]["layoutVersion"] == 1
    assert response.json()["garden"]["stateVersion"] == 8
    stale = post(client, headers, edit_body(plant_action(garden_setup[3])))
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "stale_layout"
    assert stale.json()["error"]["details"]["currentLayoutVersion"] == 1
    bad_catalogue = post(
        client, headers, edit_body(plant_action(garden_setup[3]), version=1, catalogVersion="old")
    )
    assert bad_catalogue.status_code == 409
    assert bad_catalogue.json()["error"]["code"] == "stale_catalogue"


def test_operation_state_conflicts_and_disabled_new_planting(client, app, headers, garden_setup):
    first = garden_setup[2]
    for action in (
        {"action": "store", "plantId": str(first)},
        {"action": "rotate", "plantId": str(first), "rotationDegrees": 10},
        {"action": "move", "plantId": str(first), "x": 2, "y": 2},
    ):
        result = post(client, headers, edit_body(action))
        assert result.status_code == 409
        assert result.json()["error"]["code"] == "plant_not_placed"
    assert post(client, headers, edit_body(plant_action(first))).status_code == 200
    result = post(client, headers, edit_body(plant_action(first), version=1))
    assert result.json()["error"]["code"] == "plant_already_placed"
    with app.state.database.sessions.begin() as session:
        session.get(Species, "oak").enabled = False
    result = post(client, headers, edit_body(plant_action(garden_setup[3]), version=1))
    assert result.json()["error"]["code"] == "plant_unavailable"
    assert (
        post(
            client, headers, edit_body({"action": "store", "plantId": str(first)}, version=1)
        ).status_code
        == 200
    )


def test_foreign_or_missing_plant_rolls_back_whole_batch(client, headers, register, garden_setup):
    bob = register("bob")
    for foreign in (bob["starterPlantId"], str(uuid4())):
        result = post(
            client, headers, edit_body(plant_action(garden_setup[2]), plant_action(foreign, x=6))
        )
        assert result.status_code == 404
        assert result.json()["error"] == {"code": "plant_not_found", "message": "Plant not found"}
    assert client.get("/v1/me/garden", headers=headers()).json()["plants"] == []


def test_failure_after_flush_rolls_back_placements_versions_and_receipt(
    client, app, settings, garden_setup, monkeypatch
):
    body = GardenEditRequest.model_validate(edit_body(plant_action(garden_setup[2])))

    def fail_after_flush(*args):
        raise RuntimeError("Injected failure before commit")

    monkeypatch.setattr(services, "record_request", fail_after_flush)
    with app.state.database.sessions() as session:
        with pytest.raises(RuntimeError, match="Injected"):
            placement.edit_garden(session, settings, Identity(DEV_ISSUER, "alice"), body)
    with app.state.database.sessions() as session:
        assert session.get(GardenPlacement, garden_setup[2]) is None
        garden = session.get(Garden, UUID(garden_setup[0]["gardenId"]))
        assert (garden.layout_version, garden.state_version) == (0, 0)
        assert session.get(ApiRequest, (garden_setup[1], body.request_id)) is None


def test_accounting_boundary_surrounds_changes_once_and_replay_does_not_repeat_it(
    app, settings, garden_setup
):
    calls = []
    boundary = datetime(2026, 10, 20, tzinfo=UTC)

    class Accounting:
        def before_change(self, session, garden, at):
            count = session.scalar(select(func.count()).select_from(GardenPlacement))
            calls.append(("before", at, count, garden.layout_version))

        def after_change(self, session, garden, at):
            count = session.scalar(select(func.count()).select_from(GardenPlacement))
            calls.append(("after", at, count, garden.layout_version))

    body = GardenEditRequest.model_validate(edit_body(plant_action(garden_setup[2])))
    for _ in range(2):
        with app.state.database.sessions() as session:
            placement.edit_garden(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                body,
                accounting=Accounting(),
                clock=lambda: boundary,
            )
    assert calls == [("before", boundary, 0, 0), ("after", boundary, 1, 1)]


@pytest.mark.parametrize("same_id", [True, False])
def test_concurrent_duplicate_and_competing_edits(app, settings, garden_setup, same_id):
    workers = 4
    barrier = Barrier(workers)
    bodies = [edit_body(plant_action(garden_setup[2])) for _ in range(workers)]
    if same_id:
        bodies = [bodies[0]] * workers

    def edit(body):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            try:
                return placement.edit_garden(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "alice"),
                    GardenEditRequest.model_validate(body),
                )
            except ApiError as error:
                return error

    with ThreadPoolExecutor(max_workers=workers) as pool:
        outcomes = list(pool.map(edit, bodies))
    errors = [result for result in outcomes if isinstance(result, ApiError)]
    if same_id:
        assert not errors
        assert all(result == outcomes[0] for result in outcomes)
    else:
        assert len(errors) == workers - 1
        assert all(error.code == "stale_layout" for error in errors)
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(GardenPlacement)) == 1
        assert session.scalar(select(Garden.layout_version)) == 1


def test_garden_reader_blocks_layout_writer_until_snapshot_is_complete(
    app, settings, garden_setup, monkeypatch
):
    read_locked, writer_started, writer_done, release_reader = Event(), Event(), Event(), Event()
    original_present = services.present_garden

    def delayed_present(session, garden, catalogue, presenter=None, **kwargs):
        if presenter is None:
            read_locked.set()
            assert release_reader.wait(timeout=10)
        return original_present(session, garden, catalogue, presenter, **kwargs)

    monkeypatch.setattr(services, "present_garden", delayed_present)

    def reader():
        with app.state.database.sessions() as session:
            return services.read_garden(session, settings, Identity(DEV_ISSUER, "alice"))

    def writer():
        writer_started.set()
        with app.state.database.sessions() as session:
            result = placement.edit_garden(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                GardenEditRequest.model_validate(edit_body(plant_action(garden_setup[2]))),
            )
        writer_done.set()
        return result

    with ThreadPoolExecutor(max_workers=2) as pool:
        read_future = pool.submit(reader)
        assert read_locked.wait(timeout=10)
        write_future = pool.submit(writer)
        try:
            assert writer_started.wait(timeout=10)
            assert not writer_done.wait(timeout=0.2)
        finally:
            release_reader.set()
        before = read_future.result(timeout=10)
        after = write_future.result(timeout=10)
    assert before.layout_version == 0 and before.plants == []
    assert after.garden.layout_version == 1 and len(after.garden.plants) == 1


def test_store_and_replacement_can_share_the_same_final_position(client, headers, garden_setup):
    _, _, first, second = garden_setup
    assert post(client, headers, edit_body(plant_action(first))).status_code == 200
    response = post(
        client,
        headers,
        edit_body({"action": "store", "plantId": str(first)}, plant_action(second), version=1),
    )
    assert response.status_code == 200, response.text
    result = response.json()
    assert [row["plantId"] for row in result["garden"]["plants"]] == [str(second)]
    assert result["updatedPlants"][0]["placement"] is None


def test_no_gameplay_limit_of_fifteen_plants(client, app, headers, garden_setup):
    _, owner, first, second = garden_setup
    plants = [first, second]
    with app.state.database.sessions.begin() as session:
        for _ in range(14):
            plants.append(
                services.award_plant(session, owner, "oak", "standard", "test", str(uuid4())).id
            )
    actions = [
        plant_action(plant, x=1 + 2 * (i % 4), y=1 + 2 * (i // 4)) for i, plant in enumerate(plants)
    ]
    response = post(client, headers, edit_body(*actions))
    assert response.status_code == 200, response.text
    assert len(response.json()["garden"]["plants"]) == 16
    assert response.json()["garden"]["layoutVersion"] == 1


def test_equivalent_numeric_spellings_have_the_same_request_identity(client, headers, garden_setup):
    body = edit_body(plant_action(garden_setup[2], x=2, rotationDegrees=0))
    original = post(client, headers, body)
    assert original.status_code == 200, original.text
    raw = (
        json.dumps(body)
        .replace('"x": 2', '"x": 2.000')
        .replace('"rotationDegrees": 0', '"rotationDegrees": -0.00')
    )
    replay = client.post(
        ENDPOINT, content=raw, headers={**headers(), "Content-Type": "application/json"}
    )
    assert replay.status_code == 200, replay.text
    assert replay.json() == original.json()


def test_concurrent_same_id_different_payload_cannot_double_apply(app, settings, garden_setup):
    barrier = Barrier(2)
    first_body = edit_body(plant_action(garden_setup[2]))
    bodies = [first_body, {**first_body, "actions": [plant_action(garden_setup[2], x=5)]}]

    def writer(body):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            try:
                return placement.edit_garden(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "alice"),
                    GardenEditRequest.model_validate(body),
                )
            except ApiError as error:
                return error

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(writer, bodies))
    errors = [result for result in results if isinstance(result, ApiError)]
    assert len(errors) == 1 and errors[0].code == "idempotency_conflict"
    with app.state.database.sessions() as session:
        assert session.scalar(select(Garden.layout_version)) == 1
        assert session.scalar(select(func.count()).select_from(GardenPlacement)) == 1


def test_concurrent_different_plants_cannot_enter_overlapping_space(app, settings, garden_setup):
    barrier = Barrier(2)

    def writer(plant):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            try:
                return placement.edit_garden(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "alice"),
                    GardenEditRequest.model_validate(edit_body(plant_action(plant))),
                )
            except ApiError as error:
                return error

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(writer, [garden_setup[2], garden_setup[3]]))
    errors = [result for result in results if isinstance(result, ApiError)]
    assert len(errors) == 1 and errors[0].code == "stale_layout"
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(GardenPlacement)) == 1


def test_failed_future_accounting_refresh_rolls_back_edit(app, settings, garden_setup):
    class FailingAccounting:
        def before_change(self, session, garden, boundary):
            pass

        def after_change(self, session, garden, boundary):
            raise RuntimeError("Failed future context refresh")

    body = GardenEditRequest.model_validate(edit_body(plant_action(garden_setup[2])))
    with app.state.database.sessions() as session:
        with pytest.raises(RuntimeError, match="future context"):
            placement.edit_garden(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                body,
                accounting=FailingAccounting(),
            )
    with app.state.database.sessions() as session:
        assert session.get(GardenPlacement, garden_setup[2]) is None
        assert session.scalar(select(Garden.layout_version)) == 0
        assert session.get(ApiRequest, (garden_setup[1], body.request_id)) is None


def test_invalid_edit_does_not_change_configured_radius_or_other_growth(
    client, app, headers, garden_setup
):
    _, _, first, second = garden_setup
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, first).growth_micro_units = 1_000_000_000
        session.get(OwnedPlant, first).first_matured_at = datetime(2026, 10, 20, tzinfo=UTC)
    # Both an adult standard copy and a blue sprout still reserve the species' 0.9 radius.
    response = post(client, headers, edit_body(plant_action(first), plant_action(second, x=3.799)))
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "clearance_overlap"
    with app.state.database.sessions() as session:
        adult = session.get(OwnedPlant, first)
        assert adult.growth_micro_units == 1_000_000_000
        assert adult.first_matured_at == datetime(2026, 10, 20, tzinfo=UTC)
        assert session.get(OwnedPlant, second).growth_micro_units == 0
        assert session.get(Species, "oak").clearance_radius == Decimal("0.900")
