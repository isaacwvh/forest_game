from contextlib import asynccontextmanager

from fastapi import FastAPI

from forest_api.auth import TokenVerifier
from forest_api.collection_routes import router as collection_router
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.errors import install_error_handlers
from forest_api.routes import router
from forest_api.visitor_routes import router as visitor_router
from forest_api.visitors import VisitorAccounting


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings()
    database = Database(settings)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        yield
        database.engine.dispose()

    app = FastAPI(
        title="Movement Forest API",
        version="0.1.0",
        lifespan=lifespan,
        docs_url="/docs" if settings.environment in {"local", "test"} else None,
        redoc_url=None,
        openapi_url="/openapi.json" if settings.environment in {"local", "test"} else None,
    )
    app.state.settings = settings
    from forest_api.operation_metrics import Collector, OperationMetrics

    app.state.metrics = Collector(enabled=settings.operation_metrics_enabled)
    app.add_middleware(OperationMetrics, collector=app.state.metrics)
    app.state.database = database
    app.state.verifier = TokenVerifier(settings)
    # Tests inject a deterministic clock. Runtime requests read PostgreSQL time
    # after acquiring accounting locks, including after lock waits.
    app.state.clock = None
    app.state.accounting = VisitorAccounting(settings)
    install_error_handlers(app)
    app.include_router(router)
    app.include_router(visitor_router)
    app.include_router(collection_router)
    return app
