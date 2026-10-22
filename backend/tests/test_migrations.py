import pytest
from alembic import command
from conftest import TEST_SECRET, migration_config, migration_url
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

from forest_api.config import Settings
from forest_api.main import create_app
from forest_api.models import Base


def test_upgrade_matches_models_downgrade_and_reupgrade(database_factory):
    with database_factory() as url:
        with migration_url(url):
            configuration = migration_config()
            command.upgrade(configuration, "head")
            command.check(configuration)
            engine = create_engine(url)
            with engine.connect() as connection:
                assert set(Base.metadata.tables) <= set(inspect(connection).get_table_names())
                assert connection.scalar(text("SELECT version_num FROM alembic_version")) == (
                    "0002_b4_b5"
                )
            engine.dispose()
            command.downgrade(configuration, "base")
            engine = create_engine(url)
            assert not set(Base.metadata.tables) & set(inspect(engine).get_table_names())
            engine.dispose()
            command.upgrade(configuration, "head")
            command.check(configuration)


def test_liveness_and_schema_readiness_before_and_after_migration(database_factory):
    with database_factory() as url:
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        app = create_app(settings)
        with TestClient(app) as client:
            assert client.get("/health/live").status_code == 200
            assert client.get("/health/ready").status_code == 503
            with migration_url(url):
                command.upgrade(migration_config(), "head")
            assert client.get("/health/ready").json() == {"status": "ready"}


@pytest.mark.parametrize(
    "table", ["growth_profiles", "growth_rule_profiles", "attraction_profiles"]
)
@pytest.mark.parametrize("operation", ["update", "delete"])
def test_profile_versions_are_immutable_in_postgresql(app, table, operation):
    statement = (
        f"UPDATE {table} SET version = version + 1"
        if operation == "update"
        else f"DELETE FROM {table}"
    )
    with pytest.raises(IntegrityError, match="immutable"):
        with app.state.database.engine.begin() as connection:
            connection.execute(text(statement))


def test_database_rejects_invalid_growth_and_unimplemented_behaviour(app):
    cases = [
        """INSERT INTO growth_profiles VALUES
           ('invalid', 1, '{"sprout":0,"seedling":10,"young":5,"adult":100}', 100)""",
        """INSERT INTO attraction_profiles VALUES
           ('invalid', 1, '{"sprout":0,"seedling":1,"young":1,"adult":100}', '[]')""",
        """INSERT INTO growth_rule_profiles VALUES
           ('invalid', 1, '{"schemaVersion":1,"metricMultipliers":{"steps":-1},
                            "conditionalModifiers":[],"gardenEffects":[]}')""",
        """INSERT INTO growth_rule_profiles VALUES
           ('invalid', 1, '{"schemaVersion":1,"metricMultipliers":{},
                            "conditionalModifiers":[],"gardenEffects":[{"id":"unsupported"}]}')""",
    ]
    for statement in cases:
        with pytest.raises(IntegrityError):
            with app.state.database.engine.begin() as connection:
                connection.exec_driver_sql(statement)


def test_database_accepts_qualified_workout_profile_without_enabling_rewards(app):
    with app.state.database.engine.begin() as connection:
        connection.exec_driver_sql("""
            INSERT INTO growth_rule_profiles VALUES
            ('typed_inputs', 1, '{"schemaVersion":1,
              "metricMultipliers":{"workout_minutes.running":1.5},
              "conditionalModifiers":[],"gardenEffects":[]}')
        """)
