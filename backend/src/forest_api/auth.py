from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt
from jwt import PyJWKClient
from jwt.exceptions import PyJWTError

from forest_api.config import Settings
from forest_api.errors import ApiError

DEV_ISSUER = "urn:movement-forest:development"
DEV_AUDIENCE = "movement-forest-development"


@dataclass(frozen=True)
class Identity:
    issuer: str
    subject: str


class TokenVerifier:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.jwks = (
            PyJWKClient(settings.auth_jwks_url, timeout=5, lifespan=300)
            if settings.auth_mode == "jwks"
            else None
        )

    def verify(self, token: str) -> Identity:
        if len(token) > 16384:
            raise ApiError(401, "invalid_token", "Invalid or expired bearer token")
        try:
            algorithm = "HS256" if self.jwks is None else self.settings.auth_algorithm
            if jwt.get_unverified_header(token).get("alg") != algorithm:
                raise jwt.InvalidAlgorithmError("Unsupported signing algorithm")
            if self.jwks is None:
                key = self.settings.dev_auth_secret.get_secret_value()
                issuer, audience = DEV_ISSUER, DEV_AUDIENCE
            else:
                key = self.jwks.get_signing_key_from_jwt(token).key
                issuer, audience = self.settings.auth_issuer, self.settings.auth_audience
            claims = jwt.decode(
                token,
                key,
                algorithms=[algorithm],
                issuer=issuer,
                audience=audience,
                options={"require": ["exp", "iss", "aud", "sub"]},
            )
            subject = claims["sub"]
            if not isinstance(subject, str) or not subject.strip() or len(subject) > 255:
                raise jwt.InvalidTokenError("Invalid subject")
            return Identity(issuer=claims["iss"], subject=subject)
        except jwt.PyJWKClientConnectionError as exc:
            raise ApiError(503, "auth_unavailable", "Authentication provider unavailable") from exc
        except PyJWTError as exc:
            raise ApiError(401, "invalid_token", "Invalid or expired bearer token") from exc


def issue_development_token(settings: Settings, subject: str) -> str:
    if settings.auth_mode != "development" or settings.environment not in {"local", "test"}:
        raise ValueError("Development token issuance is disabled")
    if not subject.strip() or len(subject) > 255:
        raise ValueError("Subject must contain 1–255 characters")
    now = datetime.now(UTC)
    return jwt.encode(
        {
            "sub": subject,
            "iss": DEV_ISSUER,
            "aud": DEV_AUDIENCE,
            "iat": now,
            "exp": now + timedelta(minutes=30),
        },
        settings.dev_auth_secret.get_secret_value(),
        algorithm="HS256",
    )
