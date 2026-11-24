"""Test actual RLS/grants as a restricted login, including migration retries."""

import importlib.util
import os
import time
from pathlib import Path

import pytest
from alembic import command
from conftest import TEST_SECRET, migration_config, migration_url
from pydantic import SecretStr
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import ProgrammingError

from forest_api.config import Settings
from forest_api.database import Database
from forest_api.maintenance import set_maintenance
from forest_api.models import Base

SCRIPTS = Path(__file__).parents[1] / "scripts"


def script(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def roles():
    engine = create_engine(os.environ["FOREST_TEST_DATABASE_URL"], hide_parameters=True)
    try:
        with engine.begin() as connection:
            for name in ("anon", "authenticated", "service_role", "forest_runtime"):
                if not connection.scalar(
                    text("SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=:name)"),
                    {"name": name},
                ):
                    connection.execute(text(f'CREATE ROLE "{name}"'))
            connection.execute(text("ALTER ROLE forest_runtime LOGIN PASSWORD 'ci-runtime-only'"))
        yield
    finally:
        engine.dispose()


def test_permissions_idempotent_and_runtime_cannot_control_release(app, roles):
    configure = script("configure_supabase_runtime").configure
    with app.state.database.engine.begin() as connection:
        configure(connection, apply=True)
        configure(connection, apply=True)
        for table in Base.metadata.tables:
            for role in ("anon", "authenticated", "service_role"):
                assert not connection.scalar(
                    text("SELECT has_table_privilege(:role,:table,'SELECT')"),
                    {"role": role, "table": table},
                )
    url = make_url(app.state.settings.database_url.get_secret_value()).set(
        username="forest_runtime", password="ci-runtime-only"
    )
    settings = app.state.settings.model_copy(
        update={"database_url": SecretStr(url.render_as_string(hide_password=False))}
    )
    runtime = Database(settings)
    try:
        with runtime.sessions(info={"maintenance_guard": True}) as session, session.begin():
            assert session.scalar(text("SELECT count(*) FROM users")) == 0
            session.execute(text("UPDATE users SET display_name=display_name WHERE false"))
        for sql in (
            "UPDATE runtime_control SET maintenance=true",
            "UPDATE alembic_version SET version_num='bad'",
            "CREATE TABLE public.forbidden(id integer)",
        ):
            with pytest.raises(ProgrammingError), runtime.engine.begin() as connection:
                connection.execute(text(sql))
        set_maintenance(app.state.database.engine, True)
        assert runtime.settings.maintenance_gate_enabled is False  # Explicit test fixture only.
        from forest_api.errors import ApiError

        with pytest.raises(ApiError), runtime.sessions(info={"maintenance_guard": True}) as session:
            session.execute(text("SELECT 1"))
    finally:
        runtime.engine.dispose()


def test_migrator_leaves_gate_closed_and_permission_failure_is_retryable(
    database_factory, roles, monkeypatch
):
    monkeypatch.syspath_prepend(str(SCRIPTS))
    cloud = script("cloud")
    with database_factory() as url, migration_url(url):
        engine = create_engine(url, hide_parameters=True)
        try:
            with pytest.raises(ValueError, match="bootstrap"):
                cloud.migrate(engine)
            original = cloud.configure

            def fail(*args, **kwargs):
                raise RuntimeError("permissions unavailable")

            monkeypatch.setattr(cloud, "configure", fail)
            with pytest.raises(RuntimeError):
                cloud.migrate(engine, bootstrap_stopped=True)
            with engine.connect() as connection:
                assert connection.scalar(text("SELECT maintenance FROM runtime_control")) is True
            monkeypatch.setattr(cloud, "configure", original)
            assert cloud.migrate(engine)["schema"] == "0023_cloud_runtime"
            set_maintenance(engine, False)
            with pytest.raises(ValueError, match="maintenance"):
                cloud.migrate(engine)
        finally:
            engine.dispose()


def test_production_preflight_with_published_content_and_restricted_role(database_factory, roles):
    from forest_api import item_catalogue, launch_balance, preflight, shop

    with database_factory() as url, migration_url(url):
        command.upgrade(migration_config(), "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        database = Database(settings)
        runtime = None
        try:
            with database.sessions() as session:
                publication = launch_balance.publish(session, settings)
            with database.sessions() as session:
                item_catalogue.publish(session, apply=True)
            with database.sessions() as session:
                assert shop.ensure_current(session, upcoming=True)
            from datetime import UTC, datetime

            time.sleep(
                max(
                    0,
                    (
                        datetime.fromisoformat(publication["effectiveAt"]) - datetime.now(UTC)
                    ).total_seconds(),
                )
                + 0.05
            )
            with database.engine.begin() as connection:
                script("configure_supabase_runtime").configure(connection, apply=True)
            restricted = make_url(url).set(username="forest_runtime", password="ci-runtime-only")
            production = Settings(
                _env_file=None,
                environment="production",
                database_url=restricted.render_as_string(hide_password=False),
                auth_mode="jwks",
                auth_algorithm="ES256",
                auth_issuer="https://test.invalid/auth/v1",
                auth_audience="authenticated",
                auth_jwks_url="https://test.invalid/auth/v1/.well-known/jwks.json",
            )
            runtime = Database(production)
            with runtime.sessions() as session, session.begin():
                assert preflight.database_report(session, production)["status"] == "ready"
            set_maintenance(database.engine, True)
            with (
                runtime.sessions() as session,
                session.begin(),
                pytest.raises(ValueError, match="Maintenance"),
            ):
                preflight.database_report(session, production)
            with runtime.sessions() as session, session.begin():
                assert (
                    preflight.database_report(session, production, allow_maintenance=True)[
                        "maintenance"
                    ]
                    is True
                )
            with pytest.raises(ValueError, match="verify-full"):
                preflight.inspect(production)
        finally:
            database.engine.dispose()
            if runtime:
                runtime.engine.dispose()
