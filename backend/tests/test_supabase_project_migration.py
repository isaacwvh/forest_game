from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from forest_api import services
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.errors import ApiError
from forest_api.schemas import BootstrapAccount

TOKYO = "https://kagtrtnjflgkqlvgrjnk.supabase.co/auth/v1"
SINGAPORE = "https://wqtzzjkyepawuuvsaijk.supabase.co/auth/v1"
MIGRATION = (
    Path(__file__).resolve().parents[1] / "scripts" / "migrate_supabase_issuer.sql"
).read_text(encoding="utf-8")


def rebind(app, user_id, issuer, subject):
    with app.state.database.engine.begin() as connection:
        connection.execute(
            text("UPDATE users SET auth_issuer=:issuer,auth_subject=:subject WHERE id=:id"),
            {"issuer": issuer, "subject": subject, "id": user_id},
        )


def snapshot(app):
    with app.state.database.engine.connect() as connection:
        return {
            table: connection.execute(
                text(
                    f"SELECT to_jsonb(t) {"- 'auth_issuer'" if table == 'users' else ''} "
                    f"FROM {table} t ORDER BY 1"
                )
            ).all()
            for table in ("users", "gardens", "owned_plants", "api_requests")
        }


def test_migration_preserves_gardens_replay_and_unrelated_accounts(app, settings, register):
    existing = register("existing_player")
    unrelated = register("unrelated_player")
    subject = str(uuid4())
    rebind(app, existing["profile"]["userId"], TOKYO, subject)
    before = snapshot(app)
    with app.state.database.engine.begin() as connection:
        connection.exec_driver_sql(MIGRATION)
    assert snapshot(app) == before
    with app.state.database.sessions() as session:
        migrated = services.get_user(session, Identity(SINGAPORE, subject))
        assert str(migrated.id) == existing["profile"]["userId"]
        assert (
            str(services.get_user(session, Identity(DEV_ISSUER, "unrelated_player")).id)
            == (unrelated["profile"]["userId"])
        )
        with pytest.raises(ApiError, match="Complete account setup"):
            services.get_user(session, Identity(TOKYO, subject))
    with app.state.database.sessions() as session:
        restored = services.bootstrap_account(
            session,
            settings,
            Identity(SINGAPORE, subject),
            BootstrapAccount(request_id=uuid4(), game_timezone="Asia/Singapore"),
        )
        assert str(restored.profile.user_id) == existing["profile"]["userId"]
        assert str(restored.garden_id) == existing["gardenId"]
    with app.state.database.engine.connect() as connection:
        assert connection.scalar(text("SELECT count(*) FROM owned_plants")) == 2


def test_migration_is_repeat_safe(app, register):
    existing = register()
    subject = str(uuid4())
    rebind(app, existing["profile"]["userId"], TOKYO, subject)
    for _ in range(2):
        with app.state.database.engine.begin() as connection:
            connection.exec_driver_sql(MIGRATION)
    with app.state.database.engine.connect() as connection:
        assert connection.scalar(text("SELECT count(*) FROM users")) == 1
        assert connection.scalar(text("SELECT auth_issuer FROM users")) == SINGAPORE


def test_collision_rolls_back_without_merging_any_accounts(app, register):
    source = register("source_player")
    target = register("target_player")
    another = register("another_player")
    subject = str(uuid4())
    rebind(app, source["profile"]["userId"], TOKYO, subject)
    rebind(app, target["profile"]["userId"], SINGAPORE, subject)
    rebind(app, another["profile"]["userId"], TOKYO, str(uuid4()))
    before = snapshot(app)
    with pytest.raises(DBAPIError, match="Singapore identity collision"):
        with app.state.database.engine.begin() as connection:
            connection.exec_driver_sql(MIGRATION)
    assert snapshot(app) == before
    with app.state.database.engine.connect() as connection:
        assert (
            connection.scalar(
                text("SELECT count(*) FROM users WHERE auth_issuer=:issuer"), {"issuer": TOKYO}
            )
            == 2
        )
