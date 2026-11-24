"""One opt-in, account-independent maintenance schedule, not a game timer."""

import json
import time

from forest_api.history import maintain
from forest_api.worker_execution import run_pass


def tick(database, settings):
    def operation(session):
        result = maintain(
            session,
            apply=True,
            responses=settings.maintenance_responses_enabled,
            visitor_detail=settings.maintenance_visitors_enabled,
            growth_detail=settings.maintenance_growth_enabled,
            limit=settings.maintenance_batch_limit,
        )
        return {"status": "ok", **result}

    return run_pass(database, operation)


def run(database, settings):
    while True:
        print(json.dumps(tick(database, settings)), flush=True)
        time.sleep(settings.maintenance_interval_seconds)
