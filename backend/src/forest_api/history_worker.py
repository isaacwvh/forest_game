"""One opt-in, account-independent maintenance schedule, not a game timer."""

import json
import time

from forest_api.history import maintain


def tick(database, settings):
    started = time.monotonic()
    try:
        with database.sessions() as session:
            result = maintain(
                session,
                apply=True,
                responses=settings.maintenance_responses_enabled,
                visitor_detail=settings.maintenance_visitors_enabled,
                growth_detail=settings.maintenance_growth_enabled,
                limit=settings.maintenance_batch_limit,
            )
        return {"status": "ok", "elapsedSeconds": time.monotonic() - started, **result}
    except ValueError as error:
        return {
            "status": "reconciliation_failed",
            "reason": str(error),
            "elapsedSeconds": time.monotonic() - started,
            "action": "Failed account transaction rolled back; inspect before retry",
        }
    except Exception:
        # No Health inputs or receipt/account details in infrastructure logs.
        return {
            "status": "failed",
            "elapsedSeconds": time.monotonic() - started,
            "action": "Inspect reconciliation and database health; failed transaction rolled back",
        }


def run(database, settings):
    while True:
        print(json.dumps(tick(database, settings)), flush=True)
        time.sleep(settings.maintenance_interval_seconds)
