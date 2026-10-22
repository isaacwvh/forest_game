from contextlib import asynccontextmanager

from fastapi import FastAPI

from forest_api.auth import TokenVerifier
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.errors import install_error_handlers
from forest_api.placement import DISABLED_ACCOUNTING, utc_now
from forest_api.routes import router


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
    app.state.database = database
    app.state.verifier = TokenVerifier(settings)
    app.state.clock = utc_now
    app.state.accounting = DISABLED_ACCOUNTING
    install_error_handlers(app)
    app.include_router(router)
    return app
