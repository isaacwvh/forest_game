from concurrent.futures import ThreadPoolExecutor
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select

from forest_api import items
from forest_api.errors import ApiError
from forest_api.item_models import ItemIdentity, OwnedItem
from forest_api.models import Garden


def setup_bench(app, register):
    account = register()
    owner = UUID(account["profile"]["userId"])
    with app.state.database.sessions.begin() as session:
        items.publish_bench(session)
    return owner


def test_copies_replay_account_isolation_and_capacity(app, client, register, headers):
    owner = setup_bench(app, register)
    with app.state.database.sessions.begin() as session:
        ids = items.grant(
            session, owner, "wooden-bench", 1, source="event", reference="test", quantity=2
        )
    with app.state.database.sessions.begin() as session:
        version = session.scalar(select(Garden.state_version).where(Garden.owner_id == owner))
        assert (
            items.grant(
                session, owner, "wooden-bench", 1, source="event", reference="test", quantity=2
            )
            == ids
        )
        assert (
            session.scalar(select(Garden.state_version).where(Garden.owner_id == owner)) == version
        )
    page = client.get("/v1/me/items", headers=headers()).json()
    assert {r["ownedItemId"] for r in page["items"]} == {str(v) for v in ids}
    assert page["capacity"] == {
        "ownedItems": 2,
        "placedItems": 0,
        "storedItems": 2,
        "itemLimit": 50,
    }
    assert all(r["description"] == items.BENCH_DESCRIPTION for r in page["items"])
    register("bob")
    assert client.get("/v1/me/items", headers=headers("bob")).json()["items"] == []


def test_full_capacity_blocks_whole_reward_and_preserves_source(app, register):
    owner = setup_bench(app, register)
    app.state.settings.item_capacity = 2
    with app.state.database.sessions.begin() as session:
        items.grant(session, owner, "wooden-bench", 1, source="test", reference="first")
    with pytest.raises(ApiError, match="Item inventory full"):
        with app.state.database.sessions.begin() as session:
            items.grant(
                session, owner, "wooden-bench", 1, source="event", reference="unclaimed", quantity=2
            )
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(OwnedItem)) == 1
        assert (
            session.scalar(
                select(func.count())
                .select_from(ItemIdentity)
                .where(ItemIdentity.reference == "unclaimed")
            )
            == 0
        )
        # Source remains available after capacity is increased; no lost entitlement.
        app.state.settings.item_capacity = 3
        assert (
            len(
                items.grant(
                    session,
                    owner,
                    "wooden-bench",
                    1,
                    source="event",
                    reference="unclaimed",
                    quantity=2,
                )
            )
            == 2
        )


def test_bench_preview_rolls_back_and_apply_repeats_safely(app, register):
    register()
    with app.state.database.sessions() as session:
        report = items.grant_bench(session, "alice")
        assert report["capacity"]["ownedItems"] == 1
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 0
    with app.state.database.sessions() as session:
        first = items.grant_bench(session, "alice", apply=True)
    with app.state.database.sessions() as session:
        assert (
            items.grant_bench(session, "alice", apply=True)["ownedItemIds"] == first["ownedItemIds"]
        )


def test_mixed_placement_atomicity_legacy_gate_and_replay(app, client, register, headers):
    account = register()
    with app.state.database.sessions() as session:
        item_id = items.grant_bench(session, "alice", apply=True)["ownedItemIds"][0]
    h = {**headers(), "X-Forest-Items": "1"}

    def post(item_actions, actions=None, version=0):
        body = {
            "requestId": str(uuid4()),
            "catalogVersion": "development-oak-v1",
            "expectedLayoutVersion": version,
            "actions": actions or [],
            "itemActions": item_actions,
        }
        return client.post("/v1/me/garden/edits", headers=h, json=body), body

    place = {"action": "place", "itemId": item_id, "x": 5, "y": 5, "rotationDegrees": 0}
    response, body = post([place])
    assert response.status_code == 200, response.text
    garden = response.json()["garden"]
    assert garden["items"][0]["ownedItemId"] == item_id
    assert garden["plants"] == [] and garden["totalAttractionMicroUnits"] == "0"
    assert client.post("/v1/me/garden/edits", headers=h, json=body).json() == response.json()
    legacy = client.post(
        "/v1/me/garden/edits",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "catalogVersion": "development-oak-v1",
            "expectedLayoutVersion": 1,
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
    assert legacy.status_code == 426
    plant = {
        "action": "plant",
        "plantId": account["starterPlantId"],
        "x": 2,
        "y": 2,
        "rotationDegrees": 0,
    }
    response, _ = post([], [plant], version=1)
    assert response.status_code == 200, response.text
    # Mixed swap validates only the final layout.
    response, _ = post(
        [{"action": "move", "itemId": item_id, "x": 2, "y": 2}],
        [{"action": "move", "plantId": account["starterPlantId"], "x": 5, "y": 5}],
        version=2,
    )
    assert response.status_code == 200, response.text
    before = client.get("/v1/me/garden", headers=h).json()
    response, _ = post([{"action": "move", "itemId": item_id, "x": 5, "y": 5}], version=3)
    assert response.status_code == 422
    assert client.get("/v1/me/garden", headers=h).json() == before
    response, _ = post([{"action": "store", "itemId": item_id}], version=3)
    assert response.status_code == 200, response.text
    assert response.json()["garden"]["items"] == []
    page = client.get("/v1/me/items", headers=h).json()
    assert page["items"][0]["placement"] is None
    assert page["capacity"]["ownedItems"] == 1


def test_concurrent_grants_cannot_exceed_capacity(app, register):
    owner = setup_bench(app, register)
    app.state.settings.item_capacity = 1

    def attempt(reference):
        try:
            with app.state.database.sessions.begin() as session:
                items.grant(session, owner, "wooden-bench", 1, source="event", reference=reference)
            return "granted"
        except ApiError as error:
            return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(attempt, ["first", "second"]))
    assert sorted(outcomes) == ["granted", "item_capacity_full"]


def test_export_items_http_contract(app, client, register, headers):
    """Real HTTP synthetic fixture; resource export is opt-in only."""
    import json
    import os
    from pathlib import Path

    owner = setup_bench(app, register)
    with app.state.database.sessions.begin() as session:
        ids = items.grant(
            session,
            owner,
            "wooden-bench",
            1,
            source="test",
            reference="native-contract",
            quantity=2,
        )
    h = {**headers(), "X-Forest-Items": "1"}
    value = {
        "profile": client.get("/v1/me", headers=h).json(),
        "catalogue": client.get("/v1/catalog", headers=h).json(),
        "emptyGarden": client.get("/v1/me/garden", headers=h).json(),
        "storedInventory": client.get("/v1/me/items", headers=h).json(),
    }
    request = {
        "requestId": str(uuid4()),
        "expectedLayoutVersion": 0,
        "catalogVersion": "development-oak-v1",
        "actions": [],
        "itemActions": [
            {"action": "place", "itemId": str(ids[0]), "x": 2, "y": 2, "rotationDegrees": 90}
        ],
    }
    response = client.post("/v1/me/garden/edits", headers=h, json=request)
    assert response.status_code == 200, response.text
    value.update(
        placeRequest=request,
        placeResult=response.json(),
        placedInventory=client.get("/v1/me/items", headers=h).json(),
    )
    request = {
        **request,
        "requestId": str(uuid4()),
        "expectedLayoutVersion": 1,
        "itemActions": [{"action": "store", "itemId": str(ids[0])}],
    }
    response = client.post("/v1/me/garden/edits", headers=h, json=request)
    assert response.status_code == 200, response.text
    value.update(storeRequest=request, storeResult=response.json())
    if os.environ.get("FOREST_EXPORT_ITEMS_CONTRACT") == "1":
        path = (
            Path(__file__).resolve().parents[2]
            / "frontend/MovementForest/Resources/Fixtures/items-contract.json"
        )
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def test_failed_reward_rolls_back_other_components(app, register):
    from forest_api.collection import wallet_for
    from forest_api.visitor_models import VisitorWallet

    owner = setup_bench(app, register)
    app.state.settings.item_capacity = 1
    with app.state.database.sessions.begin() as session:
        items.grant(session, owner, "wooden-bench", 1, source="test", reference="full")
        original_tokens = wallet_for(session, owner).tokens
    with pytest.raises(ApiError):
        with app.state.database.sessions.begin() as session:
            wallet_for(session, owner).tokens += 500
            items.grant(session, owner, "wooden-bench", 1, source="event", reference="blocked")
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, owner).tokens == original_tokens
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 1


def test_item_edit_compaction_preserves_acquisition_and_recovery(app, client, register, headers):
    from datetime import UTC, datetime, timedelta

    from forest_api.history import maintain
    from forest_api.storage_usage import category

    owner = setup_bench(app, register)
    with app.state.database.sessions.begin() as session:
        item_id = items.grant(session, owner, "wooden-bench", 1, source="event", reference="keep")[
            0
        ]
    body = {
        "requestId": str(uuid4()),
        "expectedLayoutVersion": 0,
        "catalogVersion": "development-oak-v1",
        "actions": [],
        "itemActions": [
            {"action": "place", "itemId": str(item_id), "x": 2, "y": 2, "rotationDegrees": 0}
        ],
    }
    h = {**headers(), "X-Forest-Items": "1", "X-Forest-Recovery": "1"}
    response = client.post("/v1/me/garden/edits", headers=h, json=body)
    assert response.status_code == 200, response.text
    with app.state.database.sessions() as session:
        maintain(
            session,
            apply=True,
            responses=True,
            visitor_detail=False,
            growth_detail=False,
            now=datetime.now(UTC) + timedelta(days=9),
            limit=100,
        )
    replay = client.post("/v1/me/garden/edits", headers=h, json=body)
    assert replay.status_code == 200, replay.text
    assert replay.json()["recovery"]["outcome"]["gardenId"] == response.json()["garden"]["gardenId"]
    page = client.get("/v1/me/items", headers=h).json()
    assert page["capacity"]["ownedItems"] == 1 and page["items"][0]["ownedItemId"] == str(item_id)
    assert category("public", "item_identities") == "durable_recovery"
    assert category("public", "owned_items") == "current_state"


def test_foreign_item_is_rejected_without_writes(app, client, register, headers):
    owner = setup_bench(app, register)
    with app.state.database.sessions.begin() as session:
        item_id = items.grant(
            session, owner, "wooden-bench", 1, source="test", reference="private"
        )[0]
    register("bob")
    h = {**headers("bob"), "X-Forest-Items": "1"}
    before = client.get("/v1/me/garden", headers=h).json()
    response = client.post(
        "/v1/me/garden/edits",
        headers=h,
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [],
            "itemActions": [
                {"action": "place", "itemId": str(item_id), "x": 2, "y": 2, "rotationDegrees": 0}
            ],
        },
    )
    assert response.status_code == 404
    assert client.get("/v1/me/garden", headers=h).json() == before


@pytest.mark.parametrize(
    "change",
    [
        {"x": "2"},
        {"x": True},
        {"x": 2.0001},
        {"x": None},
        {"rotationDegrees": 360},
        {"rotationDegrees": 0.001},
        {"radius": 0.001},
    ],
)
def test_item_numeric_and_action_validation(app, client, register, headers, change):
    owner = setup_bench(app, register)
    with app.state.database.sessions.begin() as session:
        item_id = items.grant(session, owner, "wooden-bench", 1, source="test", reference="exact")[
            0
        ]
    action = {
        "action": "place",
        "itemId": str(item_id),
        "x": 2,
        "y": 2,
        "rotationDegrees": 0,
        **change,
    }
    h = {**headers(), "X-Forest-Items": "1"}
    before = client.get("/v1/me/garden", headers=h).json()
    response = client.post(
        "/v1/me/garden/edits",
        headers=h,
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [],
            "itemActions": [action],
        },
    )
    assert response.status_code == 422, response.text
    assert client.get("/v1/me/garden", headers=h).json() == before
