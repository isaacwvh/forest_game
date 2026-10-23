import pytest
from alembic import command
from conftest import TEST_SECRET, migration_config, migration_url
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, inspect, select, text
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
                    "0003_visitors"
                )
            engine.dispose()
            command.downgrade(configuration, "base")
            engine = create_engine(url)
            assert not set(Base.metadata.tables) & set(inspect(engine).get_table_names())
            engine.dispose()
            command.upgrade(configuration, "head")
            command.check(configuration)


def test_b6_upgrade_preserves_existing_partially_grown_account(database_factory, monkeypatch):
    from uuid import uuid4

    from forest_api import seed, services
    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.database import Database
    from forest_api.models import Garden, GardenPlacement, OwnedPlant
    from forest_api.schemas import RegisterAccount

    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "0002_b4_b5")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        database = Database(settings)
        try:
            # Reproduce the pre-B6 seeder before the new tables exist.
            with monkeypatch.context() as patch:
                patch.setattr(seed, "seed_visitor_rules", lambda session: None)
                with database.sessions() as session:
                    seed.seed_development_catalogue(session, settings)
            with database.sessions() as session:
                account = services.register_account(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "isaac_fixture"),
                    RegisterAccount(
                        request_id=uuid4(),
                        username="isaac_fixture",
                        display_name="Isaac fixture",
                        game_timezone="Asia/Singapore",
                    ),
                )
            with database.sessions() as session, session.begin():
                garden = session.scalar(select(Garden))
                plant = session.get(OwnedPlant, account.starter_plant_id)
                plant.growth_micro_units = 50_000_000
                session.add(
                    GardenPlacement(
                        plant_id=plant.id,
                        owner_id=plant.owner_id,
                        garden_id=garden.id,
                        x=2,
                        y=2,
                        rotation_degrees=123,
                    )
                )
            with database.engine.connect() as connection:
                before = {
                    table: connection.execute(text(f"SELECT to_jsonb(t) FROM {table} t")).all()
                    for table in ("users", "gardens", "owned_plants", "garden_placements")
                }
            command.upgrade(configuration, "head")
            with database.engine.connect() as connection:
                after = {
                    table: connection.execute(text(f"SELECT to_jsonb(t) FROM {table} t")).all()
                    for table in before
                }
                assert after == before
                assert connection.scalar(text("SELECT count(*) FROM garden_visitor_state")) == 0
            with database.sessions() as session:
                seed.seed_development_catalogue(session, settings)
            with database.engine.connect() as connection:
                assert connection.scalar(text("SELECT count(*) FROM visitor_rules")) == 1
                assert (
                    connection.scalar(text("SELECT growth_micro_units FROM owned_plants"))
                    == 50_000_000
                )
        finally:
            database.engine.dispose()


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
