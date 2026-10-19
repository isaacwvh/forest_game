from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from pydantic import ValidationError

from forest_api.auth import DEV_AUDIENCE, DEV_ISSUER, TokenVerifier, issue_development_token
from forest_api.config import Settings
from forest_api.errors import ApiError

SECRET = "unit-test-only-secret-at-least-32-characters"
DATABASE = "postgresql+psycopg://unused:unused@localhost/unused"


def development_settings(**overrides):
    return Settings(
        _env_file=None,
        **{
            "environment": "test",
            "database_url": DATABASE,
            "auth_mode": "development",
            "dev_auth_secret": SECRET,
            **overrides,
        },
    )


def claims(**overrides):
    return {
        "iss": DEV_ISSUER,
        "aud": DEV_AUDIENCE,
        "sub": "alice",
        "exp": datetime.now(UTC) + timedelta(minutes=5),
        **overrides,
    }


def test_development_token_is_signed_and_scoped():
    settings = development_settings()
    identity = TokenVerifier(settings).verify(issue_development_token(settings, "alice"))
    assert (identity.issuer, identity.subject) == (DEV_ISSUER, "alice")


@pytest.mark.parametrize(
    "overrides",
    [
        {"iss": "attacker"},
        {"aud": "different-app"},
        {"sub": ""},
        {"sub": " "},
        {"exp": datetime.now(UTC) - timedelta(seconds=1)},
        {"nbf": datetime.now(UTC) + timedelta(hours=1)},
    ],
)
def test_invalid_claims_are_rejected(overrides):
    token = jwt.encode(claims(**overrides), SECRET, algorithm="HS256")
    with pytest.raises(ApiError) as error:
        TokenVerifier(development_settings()).verify(token)
    assert error.value.status == 401


@pytest.mark.parametrize("kind", ["unsigned", "wrong_key", "malformed", "missing_exp"])
def test_unsigned_wrongly_signed_and_incomplete_tokens_are_rejected(kind):
    payload = claims()
    if kind == "unsigned":
        token = jwt.encode(payload, "", algorithm="none")
    elif kind == "wrong_key":
        token = jwt.encode(payload, SECRET + "wrong", algorithm="HS256")
    elif kind == "missing_exp":
        payload.pop("exp")
        token = jwt.encode(payload, SECRET, algorithm="HS256")
    else:
        token = "not-a-jwt"
    with pytest.raises(ApiError, match="Invalid or expired"):
        TokenVerifier(development_settings()).verify(token)


@pytest.mark.parametrize("environment", ["staging", "production"])
def test_development_auth_fails_closed_outside_local_test(environment):
    with pytest.raises(ValidationError, match="local/test"):
        development_settings(environment=environment)


def test_jwks_settings_require_trusted_https_and_audience():
    for extra in ({}, {"auth_issuer": "http://insecure", "auth_jwks_url": "http://insecure"}):
        with pytest.raises(ValidationError):
            development_settings(auth_mode="jwks", **extra)
    with pytest.raises(ValidationError, match="postgresql"):
        development_settings(database_url="sqlite:///test.db")


@pytest.mark.parametrize("algorithm", ["RS256", "ES256"])
def test_provider_verifier_checks_actual_asymmetric_signatures_and_claims(monkeypatch, algorithm):
    settings = development_settings(
        environment="production",
        auth_mode="jwks",
        auth_issuer="https://issuer.example/",
        auth_jwks_url="https://issuer.example/jwks",
        auth_audience="forest",
        auth_algorithm=algorithm,
    )
    key = (
        rsa.generate_private_key(public_exponent=65537, key_size=2048)
        if algorithm == "RS256"
        else ec.generate_private_key(ec.SECP256R1())
    )
    verifier = TokenVerifier(settings)
    monkeypatch.setattr(
        verifier.jwks,
        "get_signing_key_from_jwt",
        lambda token: SimpleNamespace(key=key.public_key()),
    )
    payload = claims(iss=settings.auth_issuer, aud="forest")
    valid = jwt.encode(payload, key, algorithm=algorithm, headers={"kid": "test-key"})
    assert verifier.verify(valid).subject == "alice"
    for update in (
        {"iss": "https://other.example/"},
        {"aud": "other"},
        {"exp": datetime.now(UTC) - timedelta(seconds=1)},
    ):
        invalid = jwt.encode({**payload, **update}, key, algorithm=algorithm)
        with pytest.raises(ApiError):
            verifier.verify(invalid)
    other = (
        rsa.generate_private_key(public_exponent=65537, key_size=2048)
        if algorithm == "RS256"
        else ec.generate_private_key(ec.SECP256R1())
    )
    with pytest.raises(ApiError):
        verifier.verify(jwt.encode(payload, other, algorithm=algorithm))


def test_jwks_connection_failure_is_retryable(monkeypatch):
    verifier = TokenVerifier(
        development_settings(
            auth_mode="jwks",
            auth_issuer="https://issuer.example/",
            auth_jwks_url="https://issuer.example/jwks",
            auth_audience="forest",
        )
    )

    def unavailable(token):
        raise jwt.PyJWKClientConnectionError("offline")

    monkeypatch.setattr(verifier.jwks, "get_signing_key_from_jwt", unavailable)
    with pytest.raises(ApiError) as error:
        verifier.verify(
            jwt.encode(
                claims(),
                rsa.generate_private_key(public_exponent=65537, key_size=2048),
                algorithm="RS256",
            )
        )
    assert error.value.status == 503


def test_provider_verifier_rejects_algorithm_confusion_before_network_lookup(monkeypatch):
    verifier = TokenVerifier(
        development_settings(
            auth_mode="jwks",
            auth_issuer="https://issuer.example/",
            auth_jwks_url="https://issuer.example/jwks",
            auth_audience="forest",
        )
    )

    def must_not_fetch(token):
        pytest.fail("Unsupported algorithms must not cause provider network calls")

    monkeypatch.setattr(verifier.jwks, "get_signing_key_from_jwt", must_not_fetch)
    for token in (
        jwt.encode(claims(), SECRET, algorithm="HS256"),
        jwt.encode(claims(), "", algorithm="none"),
        "not-a-jwt",
    ):
        with pytest.raises(ApiError) as error:
            verifier.verify(token)
        assert error.value.status == 401
