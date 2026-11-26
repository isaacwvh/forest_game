"""Automatic startup/retry preparation, independent of clients and retention."""

import json
import time

from forest_api.shop import ensure_current
from forest_api.worker_execution import run_pass


def tick(database, *, clock=None):
    def operation(session):
        ready = ensure_current(session, clock, upcoming=True)
        return {"status": "ready" if ready else "catching_up"}

    result = run_pass(database, operation)
    if result["status"] == "failed":
        result["status"] = "retry"
    return result


def run(database):
    while True:
        print(json.dumps(tick(database)), flush=True)
        time.sleep(60)
