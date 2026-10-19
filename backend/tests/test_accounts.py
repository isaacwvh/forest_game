from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select

from forest_api.auth import DEV_ISSUER, Identity
from forest_api.main import create_app
from forest_api.models import ApiRequest, Garden, OwnedPlant, User
from forest_api.schemas import RegisterAccount
from forest_api.services import register_account


def body(**overrides):
    return {
        "requestId": str(uuid4()),
        "username": "alice",
        "displayName": "Alice",
        "gameTimezone": "Asia/Singapore",
        **overrides,
    }


def test_account_and_starter_are_atomic_and_repeat_safe(client, app, headers):
    payload = body()
    first = client.post("/v1/accounts", json=payload, headers=headers()).json()
    assert client.post("/v1/accounts", json=payload, headers=headers()).json() == first
    again = client.post("/v1/accounts", json=body(), headers=headers()).json()
    assert again == first
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant):
            assert session.scalar(select(func.count()).select_from(model)) == 1
        assert session.scalar(select(func.count()).select_from(ApiRequest)) == 2
    plant = client.get("/v1/me/inventory", headers=headers()).json()["plants"][0]
    assert plant["plantId"] == first["starterPlantId"]
    assert plant["growthMicroUnits"] == "0"
    assert plant["growthStage"] == "sprout"
    assert plant["placement"] is None
    assert not plant["contributesAttraction"]
    assert set(plant["pinnedProfiles"]) == {"growth", "behaviour", "attraction"}


def test_registration_request_reuse_rejects_changed_payload(client, headers):
    payload = body()
    assert client.post("/v1/accounts", json=payload, headers=headers()).status_code == 200
    response = client.post(
        "/v1/accounts", json={**payload, "displayName": "Changed"}, headers=headers()
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "idempotency_conflict"


def test_username_collision_rolls_back_all_provisioning(client, app, headers, register):
    register(username="ALIce")
    response = client.post("/v1/accounts", json=body(username="Alice"), headers=headers("bob"))
    assert response.status_code == 409
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 1
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 1
    assert client.get("/v1/me", headers=headers("bob")).status_code == 403


def test_no_partial_user_when_catalogue_is_missing(client, app, headers):
    with app.state.database.sessions.begin() as session:
        from forest_api.models import GameCatalogue

        session.delete(session.get(GameCatalogue, 1))
    assert client.post("/v1/accounts", json=body(), headers=headers()).status_code == 503
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 0


@pytest.mark.parametrize(
    "override",
    [
        {"username": "ab"},
        {"username": "bad name"},
        {"displayName": "  "},
        {"displayName": "bad\nname"},
        {"gameTimezone": "Not/AZone"},
        {"ownerId": str(uuid4())},
        {"growthMicroUnits": "999999999"},
        {"requestId": "bad"},
    ],
)
def test_invalid_registration_fields_do_not_provision(client, app, headers, override):
    response = client.post("/v1/accounts", json=body(**override), headers=headers())
    assert response.status_code == 422
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 0


def test_profile_update_is_owner_scoped_and_replay_safe(client, headers, register):
    alice = register()
    bob = register("bob")
    payload = {"requestId": str(uuid4()), "displayName": "New Alice"}
    first = client.patch("/v1/me", json=payload, headers=headers()).json()
    assert first["userId"] == alice["profile"]["userId"]
    assert first["displayName"] == "New Alice"
    assert client.patch("/v1/me", json=payload, headers=headers()).json() == first
    assert client.get("/v1/me", headers=headers("bob")).json() == bob["profile"]
    response = client.patch("/v1/me", json={**payload, "displayName": "Other"}, headers=headers())
    assert response.status_code == 409
    forged = client.patch(
        "/v1/me",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "displayName": "Forged",
            "userId": bob["profile"]["userId"],
        },
    )
    assert forged.status_code == 422


def test_profile_username_conflict_preserves_previous_state(client, headers, register):
    register()
    bob = register("bob")
    response = client.patch(
        "/v1/me",
        headers=headers("bob"),
        json={"requestId": str(uuid4()), "username": "ALICE", "displayName": "Should roll back"},
    )
    assert response.status_code == 409
    assert client.get("/v1/me", headers=headers("bob")).json() == bob["profile"]


def test_disabled_account_cannot_read_or_retry_onboarding(client, app, headers, register):
    account = register()
    with app.state.database.sessions.begin() as session:
        session.get(User, UUID(account["profile"]["userId"])).status = "disabled"
    assert client.get("/v1/me/inventory", headers=headers()).status_code == 403
    assert client.post("/v1/accounts", json=body(), headers=headers()).status_code == 403


def test_concurrent_onboarding_grants_one_user_garden_and_starter(app, settings):
    workers = 4
    barrier = Barrier(workers)
    payload = RegisterAccount.model_validate(body())
    identity = Identity(DEV_ISSUER, "alice")

    def provision(_):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            return register_account(session, settings, identity, payload)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(provision, range(workers)))
    assert all(result == results[0] for result in results)
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant, ApiRequest):
            assert session.scalar(select(func.count()).select_from(model)) == 1


def test_concurrent_subjects_cannot_claim_same_username(app, settings):
    barrier = Barrier(2)

    def provision(subject):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            try:
                return register_account(
                    session,
                    settings,
                    Identity(DEV_ISSUER, subject),
                    RegisterAccount.model_validate(body()),
                )
            except Exception as error:
                return error

    with ThreadPoolExecutor(max_workers=2) as pool:
        outcomes = list(pool.map(provision, ["subject_a", "subject_b"]))
    from forest_api.errors import ApiError

    assert sum(isinstance(result, ApiError) and result.status == 409 for result in outcomes) == 1
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant):
            assert session.scalar(select(func.count()).select_from(model)) == 1


def test_account_state_and_request_receipts_survive_app_recreation(
    client, settings, headers, register
):
    from fastapi.testclient import TestClient

    account = register()
    payload = {"requestId": str(uuid4()), "displayName": "Durable"}
    result = client.patch("/v1/me", json=payload, headers=headers()).json()
    with TestClient(create_app(settings)) as reopened:
        assert reopened.get("/v1/me", headers=headers()).json() == result
        assert reopened.patch("/v1/me", json=payload, headers=headers()).json() == result
        stored = reopened.get("/v1/me/inventory", headers=headers()).json()["plants"]
        assert [plant["plantId"] for plant in stored] == [account["starterPlantId"]]
