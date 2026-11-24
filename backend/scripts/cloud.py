"""Explicit operator commands. No migration, seeding or publication on service startup."""

import argparse
import json
import os
from pathlib import Path

from alembic import command
from alembic.config import Config
from configure_supabase_runtime import configure
from sqlalchemy import create_engine, text
from sqlalchemy.orm import Session
from sqlalchemy.pool import NullPool

from forest_api.config import Settings
from forest_api.maintenance import operator_connection, set_maintenance
from forest_api.preflight import inspect
from forest_api.routes import SCHEMA_REVISION


def migrate(engine, *, bootstrap_stopped=False, expected_release=None):
    with operator_connection(engine) as connection:
        if connection.scalar(text("SELECT current_user")) == "forest_runtime":
            raise ValueError("Migration requires the operator credential")
        exists = connection.scalar(text("SELECT to_regclass('public.runtime_control') IS NOT NULL"))
        if exists:
            state = connection.execute(
                text("SELECT maintenance,release FROM runtime_control WHERE id=1")
            ).one()
            if not state.maintenance:
                raise ValueError("Enter maintenance and drain before migration")
            if expected_release and state.release != expected_release:
                raise ValueError("Maintenance belongs to a different release")
        elif not bootstrap_stopped:
            raise ValueError(
                "Initial installation requires --bootstrap-stopped and stopped writers"
            )
        connection.commit()
        configuration = Config(str(Path(__file__).resolve().parents[1] / "alembic.ini"))
        configuration.attributes["connection"] = connection
        command.upgrade(configuration, "head")
        with connection.begin():
            connection.execute(
                text("UPDATE runtime_control SET maintenance=true,release=:release WHERE id=1"),
                {"release": expected_release or ""},
            )
        with connection.begin():
            permissions = configure(connection, apply=True)
            revision = connection.scalar(text("SELECT version_num FROM alembic_version"))
            if revision != SCHEMA_REVISION:
                raise ValueError("Unexpected schema after migration")
        return {"status": "migrated", "schema": revision, "permissions": permissions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    maintenance = commands.add_parser("maintenance")
    maintenance.add_argument("state", choices=["on", "off", "status"])
    maintenance.add_argument("--release", default="")
    maintenance.add_argument(
        "--drain-timeout-ms", type=int, default=60000, choices=range(100, 120001)
    )
    migration = commands.add_parser("migrate")
    migration.add_argument("--bootstrap-stopped", action="store_true")
    migration.add_argument("--release")
    commands.add_parser("prepare-shop")
    preflight = commands.add_parser("preflight")
    preflight.add_argument("--allow-maintenance", action="store_true")
    args = parser.parse_args()
    engine = None
    try:
        if args.command == "preflight":
            result = inspect(Settings(), allow_maintenance=args.allow_maintenance)
        else:
            engine = create_engine(
                os.environ["FOREST_DATABASE_URL"],
                poolclass=NullPool,
                hide_parameters=True,
                connect_args={"connect_timeout": 5},
            )
            if args.command == "prepare-shop":
                from forest_api.shop import ensure_current

                with operator_connection(engine) as connection:
                    if (
                        connection.scalar(
                            text("SELECT maintenance FROM runtime_control WHERE id=1")
                        )
                        is not True
                    ):
                        raise ValueError("Prepare release rotations while maintenance is enabled")
                    connection.execute(text("SET statement_timeout='15s'"))
                    connection.execute(text("SET lock_timeout='3s'"))
                    connection.commit()
                    with Session(bind=connection) as session:
                        ready = ensure_current(session, upcoming=True)
                    if not ready:
                        raise ValueError("Shop catch-up committed; run another bounded preparation")
                    result = {"status": "ready"}
            elif args.command == "migrate":
                result = migrate(
                    engine, bootstrap_stopped=args.bootstrap_stopped, expected_release=args.release
                )
            elif args.state == "status":
                with engine.connect() as connection:
                    result = dict(
                        connection.execute(
                            text("SELECT maintenance,release FROM runtime_control WHERE id=1")
                        )
                        .mappings()
                        .one()
                    )
            else:
                result = set_maintenance(
                    engine,
                    args.state == "on",
                    args.release,
                    drain_timeout_ms=args.drain_timeout_ms,
                )
        print(json.dumps(result))
    except Exception as error:
        # SQLAlchemy exceptions can contain connection details or parameter values.
        result = {"status": "failed", "kind": type(error).__name__}
        if type(error) is ValueError:
            result["message"] = str(error)
        from forest_api.errors import ApiError

        if isinstance(error, ApiError):
            result["code"] = error.code
        print(json.dumps(result))
        raise SystemExit(1) from None
    finally:
        if engine is not None:
            engine.dispose()


if __name__ == "__main__":
    main()
