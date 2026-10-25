"""Migrations need only DATABASE_URL; auth configuration is irrelevant here."""

from alembic import context
from pydantic import SecretStr
from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import create_engine, pool
from sqlalchemy.engine import make_url

from forest_api import (
    activity_models,  # noqa: F401 - register typed activity and milestone metadata
    collection_models,  # noqa: F401 - register B7 metadata
    visitor_models,  # noqa: F401 - register B6 metadata
)
from forest_api.models import Base


class MigrationSettings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="FOREST_", env_file=".env", extra="ignore")
    database_url: SecretStr


url = MigrationSettings().database_url.get_secret_value()
if make_url(url).drivername != "postgresql+psycopg":
    raise ValueError("Migrations require PostgreSQL through psycopg")
target_metadata = Base.metadata

if context.is_offline_mode():
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()
else:
    engine = create_engine(url, poolclass=pool.NullPool, hide_parameters=True)
    with engine.connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()
    engine.dispose()
