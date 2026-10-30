from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker

from forest_api.config import Settings


class Database:
    def __init__(self, settings: Settings):
        self.engine = create_engine(
            settings.database_url.get_secret_value(),
            pool_pre_ping=True,
            pool_size=settings.db_pool_size,
            max_overflow=settings.db_max_overflow,
            connect_args={"connect_timeout": 5},
            hide_parameters=True,
        )
        self.sessions = sessionmaker(self.engine, expire_on_commit=False, autoflush=False)
        from forest_api.operation_metrics import instrument

        instrument(self.engine)

    def session(self) -> Iterator[Session]:
        # Close rolls back unfinished transactions; never commit after a response is sent.
        with self.sessions() as session:
            yield session
