from typing import Literal
from urllib.parse import urlparse

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy.engine import make_url


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FOREST_", env_file=".env", extra="ignore")

    environment: Literal["local", "test", "staging", "production"] = "local"
    database_url: SecretStr
    auth_mode: Literal["development", "jwks"] = "jwks"
    dev_auth_secret: SecretStr | None = None
    auth_issuer: str | None = None
    auth_audience: str | None = None
    auth_jwks_url: str | None = None
    auth_algorithm: Literal["RS256", "ES256"] = "RS256"
    db_pool_size: int = Field(default=5, ge=1, le=50)
    db_max_overflow: int = Field(default=5, ge=0, le=50)
    operation_metrics_enabled: bool = False
    maintenance_responses_enabled: bool = False
    maintenance_visitors_enabled: bool = False
    maintenance_growth_enabled: bool = False
    maintenance_interval_seconds: int = Field(default=60, ge=60, le=86400)
    maintenance_batch_limit: int = Field(default=500, ge=1, le=5000)

    @model_validator(mode="after")
    def validate_configuration(self) -> "Settings":
        if make_url(self.database_url.get_secret_value()).drivername != "postgresql+psycopg":
            raise ValueError("Use a postgresql+psycopg database URL")
        if self.auth_mode == "development":
            if self.environment not in {"local", "test"}:
                raise ValueError("Development authentication is allowed only in local/test")
            if not self.dev_auth_secret or len(self.dev_auth_secret.get_secret_value()) < 32:
                raise ValueError(
                    "Development authentication requires a secret of at least 32 chars"
                )
        else:
            if not self.auth_audience or not self.auth_audience.strip():
                raise ValueError("JWKS authentication requires an audience")
            for value in (self.auth_issuer, self.auth_jwks_url):
                parsed = urlparse(value or "")
                if (
                    parsed.scheme != "https"
                    or not parsed.hostname
                    or parsed.username
                    or parsed.password
                    or parsed.query
                    or parsed.fragment
                ):
                    raise ValueError("JWKS authentication requires trusted HTTPS issuer/JWKS URLs")
        return self
