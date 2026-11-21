from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select

from forest_api import services
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.models import ApiRequest, GameCatalogue, Garden, OwnedPlant, User
from forest_api.schemas import BootstrapAccount, RegisterAccount


def body(**overrides):
    return {"requestId": str(uuid4()), "gameTimezone": "Asia/Singapore", **overrides}


def test_bootstrap_grants_one_starter_and_preserves_generated_profile(client, app, headers):
    payload = body()
    response = client.post("/v1/accounts/bootstrap", json=payload, headers=headers())
    assert response.status_code == 200, response.text
    first = response.json()
    assert first["profile"]["username"].startswith("gardener_")
    assert first["profile"]["displayName"] == "New Gardener"
    assert client.post("/v1/accounts/bootstrap", json=payload, headers=headers()).json() == first
    assert client.post("/v1/accounts/bootstrap", json=body(), headers=headers()).json() == first
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant):
            assert session.scalar(select(func.count()).select_from(model)) == 1
    plant = client.get("/v1/me/inventory", headers=headers()).json()["plants"][0]
    assert plant["plantId"] == first["starterPlantId"]
    assert plant["growthMicroUnits"] == "0"
    assert plant["placement"] is None


def test_bootstrap_preserves_existing_account_and_does_not_mutate_reads(
    client, app, headers, register
):
    assert client.get("/v1/me", headers=headers()).json()["error"]["code"] == "account_required"
    existing = register(displayName="My garden")
    assert (
        client.post(
            "/v1/accounts/bootstrap", json=body(gameTimezone="Europe/London"), headers=headers()
        ).json()
        == existing
    )
    assert client.get("/v1/me", headers=headers()).json() == existing["profile"]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 1


def test_changed_request_and_cross_operation_id_conflict(client, headers):
    payload = body()
    assert client.post("/v1/accounts/bootstrap", json=payload, headers=headers()).status_code == 200
    changed = client.post(
        "/v1/accounts/bootstrap", json={**payload, "gameTimezone": "UTC"}, headers=headers()
    )
    assert changed.status_code == 409
    manual = client.post(
        "/v1/accounts",
        json={**payload, "username": "alice", "displayName": "Alice"},
        headers=headers(),
    )
    assert manual.status_code == 409


@pytest.mark.parametrize(
    "override",
    [
        {"gameTimezone": "Not/AZone"},
        {"requestId": "bad"},
        {"username": "forged"},
        {"ownerId": str(uuid4())},
    ],
)
def test_invalid_bootstrap_never_provisions(client, app, headers, override):
    assert (
        client.post("/v1/accounts/bootstrap", json=body(**override), headers=headers()).status_code
        == 422
    )
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 0


def test_bootstrap_catalogue_failure_rolls_back(client, app, headers):
    with app.state.database.sessions.begin() as session:
        session.delete(session.get(GameCatalogue, 1))
    assert client.post("/v1/accounts/bootstrap", json=body(), headers=headers()).status_code == 503
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant, ApiRequest):
            assert session.scalar(select(func.count()).select_from(model)) == 0


def test_bootstrap_retries_generated_name_collision(client, headers, register, monkeypatch):
    register(username="collision")
    names = iter(["collision", "gardener_unique"])
    monkeypatch.setattr(services, "generated_username", lambda: next(names))
    result = client.post("/v1/accounts/bootstrap", json=body(), headers=headers("bob"))
    assert result.status_code == 200, result.text
    assert result.json()["profile"]["username"] == "gardener_unique"


def test_disabled_user_cannot_bootstrap_or_replay(client, app, headers):
    payload = body()
    result = client.post("/v1/accounts/bootstrap", json=payload, headers=headers()).json()
    with app.state.database.sessions.begin() as session:
        session.get(User, UUID(result["profile"]["userId"])).status = "disabled"
    assert client.post("/v1/accounts/bootstrap", json=payload, headers=headers()).status_code == 403


def test_bootstrap_and_manual_registration_share_identity_lock(app, settings):
    barrier = Barrier(4)
    identity = Identity(DEV_ISSUER, "alice")

    def provision(index):
        with app.state.database.sessions() as session:
            barrier.wait(timeout=10)
            if index % 2:
                return services.register_account(
                    session,
                    settings,
                    identity,
                    RegisterAccount.model_validate(
                        {**body(), "username": "alice", "displayName": "Alice"}
                    ),
                )
            return services.bootstrap_account(
                session, settings, identity, BootstrapAccount.model_validate(body())
            )

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(provision, range(4)))
    assert all(result == results[0] for result in results)
    with app.state.database.sessions() as session:
        for model in (User, Garden, OwnedPlant):
            assert session.scalar(select(func.count()).select_from(model)) == 1


def test_compacted_bootstrap_receipt_replays_without_regrant(client, app, headers):
    payload = body()
    auth = {**headers(), "X-Forest-Recovery": "1"}
    result = client.post("/v1/accounts/bootstrap", json=payload, headers=auth)
    assert result.status_code == 200, result.text
    with app.state.database.sessions.begin() as session:
        record = session.scalar(
            select(ApiRequest).where(ApiRequest.request_id == UUID(payload["requestId"]))
        )
        assert record.completion["outcome"] == result.json()
        record.response = None
    assert client.post("/v1/accounts/bootstrap", json=payload, headers=auth).json() == result.json()
    assert client.post("/v1/accounts/bootstrap", json=body(), headers=auth).json() == result.json()
