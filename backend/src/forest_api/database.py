from collections.abc import Iterator
from contextlib import contextmanager

from sqlalchemy import create_engine, event, text
from sqlalchemy.orm import Session, sessionmaker

from forest_api.catalogue_cache import CatalogueCache, PackPresentationCache
from forest_api.config import Settings


class Database:
    def __init__(self, settings: Settings):
        self.engine = create_engine(
            settings.database_url.get_secret_value(),
            pool_pre_ping=True,
            pool_size=settings.db_pool_size,
            max_overflow=settings.db_max_overflow,
            pool_timeout=settings.db_pool_timeout_seconds,
            connect_args={"connect_timeout": 5},
            hide_parameters=True,
        )
        self.sessions = sessionmaker(
            self.engine,
            expire_on_commit=False,
            autoflush=False,
            info={
                "settings": settings,
                "catalogue_cache": CatalogueCache(),
                "pack_presentation_cache": PackPresentationCache(),
            },
        )
        from forest_api.operation_metrics import instrument

        instrument(self.engine)
        self.settings = settings

        from forest_api import execution_budget, maintenance

        @event.listens_for(self.sessions, "after_begin")
        def admit(session, transaction, connection):
            if not session.info.get("maintenance_guard") and execution_budget.current.get() is None:
                return
            guarded = bool(session.info.get("maintenance_guard"))
            admission = connection.execute(
                text(
                    "SELECT set_config('statement_timeout', :statement, true), "
                    "set_config('lock_timeout', :lock, true)"
                    + (", pg_try_advisory_xact_lock_shared(:key) AS acquired" if guarded else "")
                ),
                {
                    "statement": str(settings.db_statement_timeout_ms),
                    "lock": str(settings.db_lock_timeout_ms),
                    "key": maintenance.LOCK,
                },
            )
            if guarded:
                maintenance.guard(connection, acquired=admission.one().acquired)

        @event.listens_for(self.engine, "before_cursor_execute")
        def constrain(connection, cursor, statement, parameters, context, many):
            budget = execution_budget.current.get()
            if budget is not None:
                remaining = budget.remaining_ms()
                # DBAPI calls avoid recursive SQLAlchemy cursor events. Settings
                # are transaction-local and disappear before pool reuse.
                cursor.execute(
                    "SELECT set_config('statement_timeout', %s, true), "
                    "set_config('lock_timeout', %s, true)",
                    (
                        str(min(remaining, settings.db_statement_timeout_ms)),
                        str(min(remaining, settings.db_lock_timeout_ms)),
                    ),
                )

        @event.listens_for(self.sessions, "before_commit")
        def before_commit(session):
            execution_budget.checkpoint()

        @event.listens_for(self.sessions, "after_commit")
        def after_commit(session):
            budget = execution_budget.current.get()
            if budget is not None:
                budget.committed_transactions += 1

        @event.listens_for(self.sessions, "after_transaction_end")
        def release_references(session, transaction):
            if transaction.parent is None:
                session.info.pop("reference_definitions", None)
                session.info.pop("plant_definitions", None)

    @contextmanager
    def worker_session(self):
        """One pinned connection and one cross-revision lock for the entire pass."""
        from forest_api.execution_budget import cleanup_budget

        key = 711023002
        with self.engine.connect() as connection:
            try:
                acquired = connection.scalar(
                    text("SELECT pg_try_advisory_lock(:key)"), {"key": key}
                )
                connection.commit()
            except Exception:
                connection.invalidate()
                raise
            try:
                if acquired:
                    with self.sessions(
                        bind=connection,
                        info={"maintenance_guard": self.settings.maintenance_gate_enabled},
                    ) as session:
                        yield session
                else:
                    yield None
            finally:
                # Session-level locks must never leak into the connection pool.
                with cleanup_budget():
                    connection.rollback()
                    if acquired:
                        try:
                            connection.execute(
                                text("SELECT pg_advisory_unlock(:key)"), {"key": key}
                            )
                            connection.commit()
                        except Exception:
                            connection.invalidate()
                            raise

    def session(self) -> Iterator[Session]:
        # Close rolls back unfinished transactions; never commit after a response is sent.
        with self.sessions() as session:
            yield session
