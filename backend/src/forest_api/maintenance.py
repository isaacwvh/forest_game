"""Cross-revision admission and a transaction fence for controlled schema releases."""

from contextlib import contextmanager

from fastapi import Request
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from forest_api.errors import ApiError

LOCK = 711023001
OPERATOR_LOCK = 711023003
MESSAGE = "The garden is being updated. Your saved requests are safe; please retry shortly."


def unavailable(code="maintenance"):
    return ApiError(503, code, MESSAGE)


def guard(connection):
    # Try rather than wait behind the operator's exclusive lock. The shared
    # transaction lock is held until commit/rollback, across all game SQL.
    if not connection.scalar(text("SELECT pg_try_advisory_xact_lock_shared(:key)"), {"key": LOCK}):
        raise unavailable()
    state = connection.execute(
        text("SELECT maintenance FROM runtime_control WHERE id=1")
    ).one_or_none()
    if state is None or state.maintenance:
        raise unavailable()


def check_gameplay(request: Request):
    if not request.url.path.startswith("/v1/"):
        return
    database = request.app.state.database
    if not request.app.state.settings.maintenance_gate_enabled:
        return
    try:
        with database.sessions(info={"maintenance_guard": True}) as session, session.begin():
            session.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        raise unavailable("maintenance_state_unavailable") from exc


def set_maintenance(engine, enabled, release="", *, drain_timeout_ms=60000):
    """Privileged transaction: drain holders, publish state, then release the fence."""
    with engine.begin() as connection:
        if not connection.scalar(
            text("SELECT pg_try_advisory_xact_lock(:key)"), {"key": OPERATOR_LOCK}
        ):
            raise ValueError("Another backup, migration or control command is running")
        connection.execute(
            text("SELECT set_config('lock_timeout', :timeout, true)"),
            {"timeout": str(drain_timeout_ms)},
        )
        connection.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": LOCK})
        result = (
            connection.execute(
                text(
                    "UPDATE runtime_control SET maintenance=:enabled, release=:release, "
                    "updated_at=clock_timestamp() WHERE id=1 RETURNING maintenance,release"
                ),
                {"enabled": enabled, "release": release},
            )
            .mappings()
            .one()
        )
        return dict(result)


@contextmanager
def operator_connection(engine):
    """Serialize privileged commands, including across independent job executions."""
    with engine.connect() as connection:
        acquired = False
        try:
            try:
                acquired = connection.scalar(
                    text("SELECT pg_try_advisory_lock(:key)"), {"key": OPERATOR_LOCK}
                )
                connection.commit()
            except Exception:
                connection.invalidate()
                raise
            if not acquired:
                raise ValueError("Another backup, migration or control command is running")
            yield connection
        finally:
            connection.rollback()
            if acquired:
                try:
                    connection.execute(
                        text("SELECT pg_advisory_unlock(:key)"), {"key": OPERATOR_LOCK}
                    )
                    connection.commit()
                except Exception:
                    connection.invalidate()
                    raise
