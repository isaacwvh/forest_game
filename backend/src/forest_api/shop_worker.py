"""Automatic startup/retry preparation, independent of clients and retention."""

import json
import time

from forest_api.shop import ensure_current


def tick(database, *, clock=None):
    try:
        with database.sessions() as session:
            ready = ensure_current(session, clock, upcoming=True)
        return {"status": "ready" if ready else "catching_up"}
    except Exception:
        return {"status": "retry", "action": "Check database and published shop policy"}


def run(database):
    while True:
        print(json.dumps(tick(database)), flush=True)
        time.sleep(60)
