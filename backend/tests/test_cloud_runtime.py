"""Real PostgreSQL tests for admission, drain, worker retries and SQL cancellation."""

import importlib.util
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text
from sqlalchemy.exc import OperationalError

from forest_api import history_worker, maintenance, shop_worker, worker_app
from forest_api.database import Database
from forest_api.errors import ApiError
from forest_api.execution_budget import BudgetExceeded, execution_budget
from forest_api.models import RuntimeControl
from forest_api.worker_execution import run_pass


def load_script(name):
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).parents[1] / "scripts" / f"{name}.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_shared_maintenance_blocks_gameplay_but_not_health(app, client, headers):
    app.state.settings.maintenance_gate_enabled = True
    maintenance.set_maintenance(app.state.database.engine, True, "test-release")
    other = worker_app.create_app(app.state.settings)
    try:
        for path in ("/health/live", "/health/ready"):
            assert client.get(path).status_code == 200
        for credential in ({}, headers()):
            response = client.get("/v1/me", headers=credential)
            assert response.status_code == 503
            assert response.json()["error"]["code"] == "maintenance"
            assert response.headers["Retry-After"] == "30"
        assert client.post("/tasks/history").status_code == 404
        with TestClient(other) as worker:
            assert worker.get("/health/live").status_code == 200
            assert worker.get("/v1/me").status_code == 404
            assert worker.post("/tasks/history").json()["reason"] == "maintenance"
            assert worker.post("/tasks/shop").json()["reason"] == "maintenance"
        maintenance.set_maintenance(app.state.database.engine, False)
        assert client.get("/v1/me").status_code == 401
    finally:
        other.state.database.engine.dispose()


def test_missing_control_fails_closed(app, client):
    app.state.settings.maintenance_gate_enabled = True
    with app.state.database.engine.begin() as connection:
        connection.execute(text("DELETE FROM runtime_control"))
    assert client.get("/v1/me").status_code == 503
    assert client.get("/health/live").status_code == 200


def test_operator_drains_transactions_and_later_transactions_observe_gate(app):
    engine = app.state.database.engine
    entered, finish = Event(), Event()

    def active():
        with app.state.database.sessions(info={"maintenance_guard": True}) as session:
            with session.begin():
                session.execute(text("SELECT 1"))
                entered.set()
                assert finish.wait(5)

    with ThreadPoolExecutor(2) as pool:
        transaction = pool.submit(active)
        assert entered.wait(5)
        operator = pool.submit(maintenance.set_maintenance, engine, True, "drained")
        time.sleep(0.1)
        assert not operator.done()
        finish.set()
        transaction.result(timeout=5)
        assert operator.result(timeout=5)["maintenance"] is True
    with app.state.database.sessions(info={"maintenance_guard": True}) as session:
        with pytest.raises(ApiError):
            with session.begin():
                session.execute(text("SELECT 1"))


def test_drain_timeout_does_not_publish_a_false_success(app):
    engine = app.state.database.engine
    with app.state.database.sessions(info={"maintenance_guard": True}) as session:
        with session.begin():
            session.execute(text("SELECT 1"))
            with pytest.raises(OperationalError):
                maintenance.set_maintenance(engine, True, drain_timeout_ms=100)
    with engine.connect() as connection:
        assert connection.scalar(text("SELECT maintenance FROM runtime_control")) is False


def test_worker_overlap_is_skipped_and_lock_released_after_exception(app):
    other = Database(app.state.settings)
    try:
        with app.state.database.worker_session() as held:
            assert held is not None
            assert shop_worker.tick(other)["reason"] == "busy"

        def broken(session):
            with session.begin():
                session.execute(text("UPDATE runtime_control SET release='must-rollback'"))
                raise RuntimeError("private details")

        assert run_pass(other, broken)["status"] == "failed"
        assert shop_worker.tick(other)["status"] == "ready"
        with other.engine.connect() as connection:
            assert connection.scalar(text("SELECT release FROM runtime_control")) == ""
    finally:
        other.engine.dispose()


def test_budget_cancels_sql_rolls_back_and_keeps_prior_commits(app):
    app.state.settings.worker_budget_seconds = 1

    def slow(session):
        with session.begin():
            session.execute(text("UPDATE runtime_control SET release='committed'"))
        with session.begin():
            session.execute(text("UPDATE runtime_control SET release='rolled-back'"))
            session.execute(text("SELECT pg_sleep(4)"))
        return {"status": "ok"}

    started = time.monotonic()
    result = run_pass(app.state.database, slow)
    assert result["status"] == "budget_exhausted"
    assert time.monotonic() - started < 3
    assert result["committedTransactions"] == 2  # schema acceptance plus first work unit
    with app.state.database.engine.connect() as connection:
        assert connection.scalar(text("SELECT release FROM runtime_control")) == "committed"
    assert shop_worker.tick(app.state.database)["status"] == "ready"


def test_expired_budget_does_not_commit(app):
    with app.state.database.sessions() as session:
        with pytest.raises(BudgetExceeded), execution_budget(0):
            with session.begin():
                session.add(RuntimeControl(id=2))


@pytest.mark.parametrize(
    "status", ["retry", "catching_up", "budget_exhausted", "reconciliation_failed", "failed"]
)
def test_http_worker_returns_failure_status_and_redacts_reasons(
    settings, monkeypatch, status, capsys
):
    monkeypatch.setattr(
        history_worker,
        "tick",
        lambda *args: {"status": status, "reason": "private-account-details"},
    )
    with TestClient(worker_app.create_app(settings)) as worker:
        response = worker.post("/tasks/history")
        assert response.status_code == 503
        assert "private-account-details" not in response.text
    assert "private-account-details" not in capsys.readouterr().out


def test_hosted_smoke_checks_identity_and_never_mutates():
    smoke = load_script("smoke_hosted")
    owner = "12345678-1234-1234-1234-123456789012"
    calls = []

    def request(base, path, token=None):
        calls.append((path, token))
        if path.startswith("/health/"):
            return 200, {"status": "ok" if path.endswith("live") else "ready"}
        if token != "real-token":
            return 401, {}
        return 200, {"userId": owner}

    assert (
        smoke.run("https://test.invalid", token="real-token", expected_user=owner, request=request)[
            "status"
        ]
        == "passed"
    )
    assert {path for path, _ in calls} <= {
        "/health/live",
        "/health/ready",
        "/v1/me",
        "/v1/catalog",
        "/v1/me/inventory?limit=1",
    }
    with pytest.raises(ValueError):
        smoke.run("https://test.invalid", token="real-token", expected_user="bad", request=request)


@pytest.mark.parametrize(
    "url",
    [
        "http://example.com",
        "https://user:pass@example.com",
        "https://example.com/path",
        "https://example.com?token=x",
    ],
)
def test_hosted_smoke_rejects_unsafe_targets(url):
    with pytest.raises(ValueError):
        load_script("smoke_hosted").target_url(url)
