import os
from contextlib import contextmanager
from pathlib import Path
from uuid import uuid4

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.main import create_app
from forest_api.models import Base
from forest_api.seed import seed_development_catalogue

BACKEND = Path(__file__).resolve().parents[1]
TEST_SECRET = "test-only-signing-key-32-characters-minimum"


def migration_config() -> Config:
    return Config(str(BACKEND / "alembic.ini"))


@contextmanager
def migration_url(url: str):
    previous = os.environ.get("FOREST_DATABASE_URL")
    os.environ["FOREST_DATABASE_URL"] = url
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop("FOREST_DATABASE_URL", None)
        else:
            os.environ["FOREST_DATABASE_URL"] = previous


@pytest.fixture(scope="session")
def database_factory():
    connection_url = os.environ.get("FOREST_TEST_DATABASE_URL")
    if not connection_url:
        raise pytest.UsageError(
            "Set FOREST_TEST_DATABASE_URL to a PostgreSQL admin connection. "
            "Tests create/drop only randomly named forest_test_* databases; SQLite is unsupported."
        )
    url = make_url(connection_url)
    if url.drivername != "postgresql+psycopg":
        raise pytest.UsageError("PostgreSQL through psycopg is required")
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)

    @contextmanager
    def isolated_database():
        name = "forest_test_" + uuid4().hex
        assert name.startswith("forest_test_") and name.replace("_", "").isalnum()
        with admin.connect() as connection:
            connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
        try:
            yield url.set(database=name).render_as_string(hide_password=False)
        finally:
            # Only the generated name above is dropped, never the configured admin database.
            with admin.connect() as connection:
                connection.execute(text(f'DROP DATABASE "{name}" WITH (FORCE)'))

    yield isolated_database
    admin.dispose()


@pytest.fixture(scope="session")
def migrated_url(database_factory):
    with database_factory() as url:
        with migration_url(url):
            command.upgrade(migration_config(), "head")
        yield url


@pytest.fixture
def settings(migrated_url):
    return Settings(
        _env_file=None,
        environment="test",
        database_url=migrated_url,
        auth_mode="development",
        dev_auth_secret=TEST_SECRET,
    )


@pytest.fixture
def app(settings):
    application = create_app(settings)
    database = application.state.database
    with database.engine.begin() as connection:
        names = ", ".join(f'"{table}"' for table in Base.metadata.tables)
        connection.execute(text(f"TRUNCATE {names} CASCADE"))
    with database.sessions() as session:
        seed_development_catalogue(session, settings)
    yield application
    database.engine.dispose()


@pytest.fixture
def client(app):
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def headers(settings):
    def for_subject(subject="alice"):
        return {"Authorization": "Bearer " + issue_development_token(settings, subject)}

    return for_subject


@pytest.fixture
def register(client, headers):
    def account(subject="alice", **overrides):
        payload = {
            "requestId": str(uuid4()),
            "username": subject,
            "displayName": subject.title(),
            "gameTimezone": "Asia/Singapore",
            **overrides,
        }
        response = client.post("/v1/accounts", json=payload, headers=headers(subject))
        assert response.status_code == 200, response.text
        return response.json()

    return account


@pytest.fixture
def economy(app, client, register, headers):
    from uuid import UUID

    from forest_api.collection_seed import seed_legacy_collection
    from forest_api.visitor_models import VisitorWallet

    account = register()
    owner = UUID(account["profile"]["userId"])
    with app.state.database.sessions() as session:
        seed_legacy_collection(session, app.state.settings)
    # Synthetic initial funds are deliberately local to tests, never a runtime API.
    with app.state.database.sessions.begin() as session:
        session.add(VisitorWallet(owner_id=owner, tokens=100, hosted_active=0, hosted_offline=0))
    return {"owner": owner, "headers": headers(), "client": client, "app": app}
