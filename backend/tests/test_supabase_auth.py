"""Supabase-shaped JWT integration with local keys and real PostgreSQL.

These exercise the actual verifier and game HTTP routes, not a live provider.
"""

from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec
from sqlalchemy import func, select

from forest_api.auth import TokenVerifier, issue_development_token
from forest_api.config import Settings
from forest_api.models import Garden, OwnedPlant, User

ISSUER = "https://project-test.supabase.co/auth/v1"


@pytest.fixture
def supabase(app, client, settings, monkeypatch):
    configuration = Settings(
        _env_file=None,
        environment="test",
        database_url=settings.database_url,
        auth_mode="jwks",
        auth_issuer=ISSUER,
        auth_audience="authenticated",
        auth_jwks_url=ISSUER + "/.well-known/jwks.json",
        auth_algorithm="ES256",
    )
    verifier = TokenVerifier(configuration)
    app.state.settings = configuration
    app.state.verifier = verifier
    key = ec.generate_private_key(ec.SECP256R1())
    key_id = "initial"

    def jwks():
        public = jwt.algorithms.ECAlgorithm.to_jwk(key.public_key(), as_dict=True)
        return {"keys": [{**public, "kid": key_id, "use": "sig", "alg": "ES256"}]}

    monkeypatch.setattr(verifier.jwks, "fetch_data", jwks)

    def headers(subject, provider="email", **overrides):
        payload = {
            "iss": ISSUER,
            "aud": "authenticated",
            "sub": str(subject),
            "role": "authenticated",
            "email": "relay@example.invalid" if provider == "apple" else "user@example.invalid",
            "app_metadata": {"provider": provider, "providers": ["email", "google", "apple"]},
            "exp": datetime.now(UTC) + timedelta(minutes=30),
            **overrides,
        }
        token = jwt.encode(payload, key, algorithm="ES256", headers={"kid": key_id})
        return {"Authorization": "Bearer " + token}

    def account(subject, username):
        response = client.post(
            "/v1/accounts",
            headers=headers(subject),
            json={
                "requestId": str(uuid4()),
                "username": username,
                "displayName": username.title(),
                "gameTimezone": "Asia/Singapore",
            },
        )
        assert response.status_code == 200, response.text
        return response.json()

    def rotate():
        nonlocal key, key_id
        key = ec.generate_private_key(ec.SECP256R1())
        key_id = "rotated"

    return headers, account, rotate


def test_authentication_does_not_implicitly_provision_game_state(supabase, client, app):
    headers, _, _ = supabase
    response = client.get("/v1/me", headers=headers(uuid4()))
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "account_required"
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 0


def test_linked_providers_and_token_rotation_keep_one_account_and_starter(supabase, client, app):
    headers, account, rotate = supabase
    subject = uuid4()
    created = account(subject, "linked_player")
    for provider in ["email", "google", "apple"]:
        profile = client.get("/v1/me", headers=headers(subject, provider)).json()
        assert profile["userId"] == created["profile"]["userId"]
        assert (
            client.get("/v1/me/garden", headers=headers(subject, provider)).json()["gardenId"]
            == created["gardenId"]
        )
    rotate()
    replay = account(subject, "linked_player")
    assert replay["profile"]["userId"] == created["profile"]["userId"]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(User)) == 1
        assert session.scalar(select(func.count()).select_from(Garden)) == 1
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 1
        stored = session.scalar(select(User))
        assert (stored.auth_issuer, stored.auth_subject) == (ISSUER, str(subject))


def test_activity_replay_survives_provider_and_signing_key_changes(supabase, client, app):
    headers, account, rotate = supabase
    subject = uuid4()
    created = account(subject, "walking_player")
    now = datetime.now(UTC)
    app.state.clock = lambda: now
    placed = client.post(
        "/v1/me/garden/edits",
        headers=headers(subject),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [
                {
                    "action": "plant",
                    "plantId": created["starterPlantId"],
                    "x": 2,
                    "y": 2,
                    "rotationDegrees": 0,
                }
            ],
        },
    )
    assert placed.status_code == 200, placed.text
    installation = str(uuid4())
    enrolment = client.post(
        "/v1/activity/enrolments",
        headers=headers(subject),
        json={
            "requestId": str(uuid4()),
            "installationId": installation,
            "observedAt": now.isoformat(),
            "steps": 1000,
        },
    )
    assert enrolment.status_code == 200, enrolment.text
    device = enrolment.json()["device"]["deviceId"]
    game_date = now.astimezone(ZoneInfo("Asia/Singapore")).date()
    body = {
        "requestId": str(uuid4()),
        "installationId": installation,
        "deviceId": device,
        "observedAt": now.isoformat(),
        "days": [{"gameDate": game_date.isoformat(), "steps": 2000}],
    }
    first = client.post("/v1/activity/sync", headers=headers(subject), json=body)
    assert first.status_code == 200, first.text
    rotate()
    repeated = client.post("/v1/activity/sync", headers=headers(subject, "apple"), json=body)
    assert repeated.status_code == 200, repeated.text
    assert repeated.json() == first.json()
    status = client.get("/v1/me/activity", headers=headers(subject, "google")).json()
    assert status["device"]["deviceId"] == device
    assert status["device"]["baselineSteps"] == 1000
    assert (
        client.get("/v1/me/garden", headers=headers(subject)).json()["plants"][0][
            "growthMicroUnits"
        ]
        == first.json()["garden"]["plants"][0]["growthMicroUnits"]
    )


@pytest.mark.parametrize(
    "override",
    [
        {"iss": "https://other-project.supabase.co/auth/v1"},
        {"iss": "https://accounts.google.com"},
        {"iss": "https://appleid.apple.com"},
        {"aud": "another-api"},
        {"exp": datetime.now(UTC) - timedelta(minutes=5)},
    ],
)
def test_wrong_project_provider_and_expired_tokens_cannot_access_game(supabase, client, override):
    headers, _, _ = supabase
    assert client.get("/v1/me", headers=headers(uuid4(), **override)).status_code == 401


def test_different_subjects_are_isolated_even_with_same_email(supabase, client):
    headers, account, _ = supabase
    alice, bob = uuid4(), uuid4()
    first = account(alice, "first_player")
    second = account(bob, "second_player")
    assert first["profile"]["userId"] != second["profile"]["userId"]
    response = client.get("/v1/me/plants/" + first["starterPlantId"], headers=headers(bob))
    assert response.status_code == 404


def test_disabled_game_user_cannot_use_an_unexpired_supabase_token(supabase, client, app):
    headers, account, _ = supabase
    subject = uuid4()
    created = account(subject, "disabled_player")
    with app.state.database.sessions.begin() as session:
        session.get(User, UUID(created["profile"]["userId"])).status = "disabled"
    response = client.get("/v1/me", headers=headers(subject))
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "account_disabled"


def test_development_tokens_fail_in_supabase_configuration(supabase, client, settings):
    token = issue_development_token(settings, "development_player")
    assert client.get("/v1/me", headers={"Authorization": "Bearer " + token}).status_code == 401
