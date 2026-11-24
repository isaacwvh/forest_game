"""Shared bounded execution for local and HTTP worker passes."""

import time

from sqlalchemy import text
from sqlalchemy.exc import DBAPIError

from forest_api.errors import ApiError
from forest_api.execution_budget import BudgetExceeded, execution_budget
from forest_api.routes import SCHEMA_REVISION


def run_pass(database, operation):
    started = time.monotonic()
    budget = None
    try:
        with execution_budget(database.settings.worker_budget_seconds) as budget:
            with database.worker_session() as session:
                if session is None:
                    result = {"status": "skipped", "reason": "busy"}
                else:
                    with session.begin():
                        if session.scalars(
                            text("SELECT version_num FROM alembic_version")
                        ).all() != [SCHEMA_REVISION]:
                            raise ApiError(503, "schema_not_ready", "Worker schema is not ready")
                    result = operation(session)
    except ApiError as error:
        result = (
            {"status": "skipped", "reason": "maintenance"}
            if error.code == "maintenance"
            else {"status": "failed", "reason": error.code}
        )
    except BudgetExceeded:
        result = {"status": "budget_exhausted"}
    except DBAPIError as error:
        code = getattr(error.orig, "sqlstate", None)
        result = {"status": "budget_exhausted" if code == "57014" else "failed"}
    except ValueError as error:
        # Retain the existing local tick contract; HTTP/logging strips this reason.
        result = {"status": "reconciliation_failed", "reason": str(error)}
    except Exception:
        result = {"status": "failed"}
    return {
        **result,
        "elapsedSeconds": time.monotonic() - started,
        "committedTransactions": budget.committed_transactions if budget else 0,
    }
