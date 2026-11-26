"""Private Cloud Run service. Google IAM, not Supabase JWTs, protects invocation."""

import json
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import JSONResponse

from forest_api import history_worker, shop_worker
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.operation_metrics import measure


def response(result, task):
    # Never send exception reasons or account/receipt data to Scheduler/logs.
    safe = {k: v for k, v in result.items() if k not in {"reason", "action"}}
    if result.get("reason") in {"busy", "maintenance"}:
        safe["reason"] = result["reason"]
    status = 200 if result["status"] in {"ok", "ready", "skipped"} else 503
    print(json.dumps({"task": task, "httpStatus": status, **safe}), flush=True)
    return JSONResponse(safe, status_code=status, headers={"Cache-Control": "no-store"})


def create_app(settings: Settings | None = None):
    settings = settings or Settings()
    database = Database(settings)

    @asynccontextmanager
    async def lifespan(app):
        yield
        database.engine.dispose()

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)
    app.state.database = database
    app.state.settings = settings

    @app.get("/health/live")
    def live():
        return {"status": "ok"}

    def measured_pass(operation, task):
        if not settings.operation_metrics_enabled:
            return response(operation(), task)
        with measure() as sample:
            result = operation()
        for key in ("queries", "dbResultValueBytes", "dbResultSampleTruncated"):
            result[key] = sample[key]
        return response(result, task)

    @app.post("/tasks/history")
    def history():
        return measured_pass(lambda: history_worker.tick(database, settings), "history")

    @app.post("/tasks/shop")
    def shop():
        return measured_pass(lambda: shop_worker.tick(database), "shop")

    return app
