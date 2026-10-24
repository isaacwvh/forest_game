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
                    "0006_garden_skills"
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
        command.upgrade(configuration, "head")
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
            # Bootstrap records with current models, then recreate the legacy schema.
            command.downgrade(configuration, "0002_b4_b5")
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


def test_b7_upgrade_preserves_b6_balances_and_history(database_factory):
    from uuid import uuid4

    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.database import Database
    from forest_api.schemas import RegisterAccount
    from forest_api.seed import seed_development_catalogue
    from forest_api.services import register_account

    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        database = Database(settings)
        try:
            with database.sessions() as session:
                seed_development_catalogue(session, settings)
            with database.sessions() as session:
                account = register_account(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "b7_existing"),
                    RegisterAccount(
                        request_id=uuid4(),
                        username="b7_existing",
                        display_name="Existing",
                        game_timezone="Asia/Singapore",
                    ),
                )
            command.downgrade(configuration, "0003_visitors")
            with database.engine.begin() as connection:
                connection.execute(
                    text(
                        "INSERT INTO visitor_wallets "
                        "(owner_id, tokens, hosted_active, hosted_offline) "
                        "VALUES (:owner, 37, 12, 25)"
                    ),
                    {"owner": account.profile.user_id},
                )
            tables = (
                "users",
                "gardens",
                "owned_plants",
                "api_requests",
                "visitor_reward_events",
                "visitor_wallet_entries",
            )
            with database.engine.connect() as connection:
                before = {
                    table: connection.execute(text(f"SELECT to_jsonb(t) FROM {table} t")).all()
                    for table in tables
                }
            command.upgrade(configuration, "head")
            with database.engine.connect() as connection:
                after = {
                    table: connection.execute(text(f"SELECT to_jsonb(t) FROM {table} t")).all()
                    for table in tables
                }
                assert before == after
                assert connection.execute(
                    text(
                        "SELECT tokens, hosted_active, hosted_offline, economy_version "
                        "FROM visitor_wallets"
                    )
                ).one() == (37, 12, 25, 0)
                assert connection.scalar(text("SELECT count(*) FROM owned_packs")) == 0
                assert connection.scalar(text("SELECT count(*) FROM collection_events")) == 0
        finally:
            database.engine.dispose()


def test_species_rarity_migration_preserves_b7_packs_and_receipts(database_factory):
    from datetime import UTC, datetime
    from uuid import uuid4

    from forest_api import collection, services
    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.collection_schemas import ExchangeRequest, OpenPackRequest
    from forest_api.collection_seed import seed_legacy_collection
    from forest_api.database import Database
    from forest_api.schemas import RegisterAccount
    from forest_api.seed import seed_development_catalogue
    from forest_api.visitor_models import VisitorWallet

    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        database = Database(settings)
        identity = Identity(DEV_ISSUER, "b7_pack_owner")
        try:
            with database.sessions() as session:
                seed_development_catalogue(session, settings)
                seed_legacy_collection(session, settings)
                account = services.register_account(
                    session,
                    settings,
                    identity,
                    RegisterAccount(
                        request_id=uuid4(),
                        username="b7_pack_owner",
                        display_name="Existing packs",
                        game_timezone="Asia/Singapore",
                    ),
                )
            with database.sessions.begin() as session:
                session.add(
                    VisitorWallet(
                        owner_id=account.profile.user_id,
                        tokens=20,
                        hosted_active=0,
                        hosted_offline=0,
                    )
                )
            with database.sessions() as session:
                bought = collection.mutate(
                    session,
                    settings,
                    identity,
                    ExchangeRequest(
                        request_id=uuid4(), offer_id="woodland", offer_version=1, quantity=2
                    ),
                    lambda: datetime.now(UTC),
                )
            from uuid import UUID

            body = OpenPackRequest(request_id=uuid4())
            pack = UUID(bought["packs"][0]["ownedPackId"])
            with database.sessions() as session:
                receipt = collection.mutate(
                    session, settings, identity, body, lambda: datetime.now(UTC), pack_id=pack
                )
            command.downgrade(configuration, "0004_collection")
            tables = (
                "users",
                "gardens",
                "owned_plants",
                "owned_packs",
                "pack_definitions",
                "pack_members",
                "pack_openings",
                "collection_events",
                "api_requests",
                "visitor_wallets",
            )
            with database.engine.connect() as connection:
                before = {
                    t: connection.execute(
                        text(f"SELECT to_jsonb(t) FROM {t} t ORDER BY to_jsonb(t)::text")
                    ).all()
                    for t in tables
                }
            command.upgrade(configuration, "head")
            with database.engine.connect() as connection:
                after = {
                    t: connection.execute(
                        text(f"SELECT to_jsonb(t) FROM {t} t ORDER BY to_jsonb(t)::text")
                    ).all()
                    for t in tables
                }
                assert before == after
                assert (
                    connection.scalar(text("SELECT rarity FROM plant_species WHERE id = 'oak'"))
                    == "development_unbalanced"
                )
            with database.sessions() as session:
                assert (
                    collection.mutate(
                        session, settings, identity, body, lambda: datetime.now(UTC), pack_id=pack
                    )
                    == receipt
                )
        finally:
            database.engine.dispose()


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
