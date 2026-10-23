"""Real HTTP B6 walkthrough using disposable PostgreSQL and an injected test clock.

Run from repository root with FOREST_TEST_DATABASE_URL. --export-frontend-contract
writes synthetic responses, never personal data. The test app factory is outside
the production package and refuses to run outside FOREST_ENVIRONMENT=test.
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.main import create_app


def create_smoke_app():
    settings = Settings(_env_file=None)
    if settings.environment != "test":
        raise RuntimeError("Smoke clock is restricted to an isolated test environment")
    app = create_app(settings)
    clock_file = Path(os.environ["FOREST_SMOKE_CLOCK_FILE"])
    app.state.clock = lambda: datetime.fromisoformat(clock_file.read_text())
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export-frontend-contract", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    url = make_url(os.environ["FOREST_TEST_DATABASE_URL"])
    admin = create_engine(url, isolation_level="AUTOCOMMIT")
    name = "forest_test_visitor_http_" + uuid4().hex
    server = None
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
    try:
        with tempfile.TemporaryDirectory(dir=root / "backend/.local-tmp") as temporary:
            clock_file = Path(temporary) / "clock.txt"
            instant = datetime(2026, 10, 23, 4, tzinfo=UTC)
            clock_file.write_text(instant.isoformat())
            environment = dict(os.environ)
            environment.update(
                FOREST_DATABASE_URL=url.set(database=name).render_as_string(hide_password=False),
                FOREST_ENVIRONMENT="test",
                FOREST_AUTH_MODE="development",
                FOREST_DEV_AUTH_SECRET=uuid4().hex + uuid4().hex,
                FOREST_SMOKE_CLOCK_FILE=str(clock_file),
            )
            os.environ.update(environment)
            command.upgrade(Config(str(root / "backend/alembic.ini")), "head")
            subprocess.run(
                [sys.executable, "-m", "forest_api.cli", "seed-dev"],
                cwd=root / "backend",
                env=environment,
                check=True,
                capture_output=True,
            )
            settings = Settings(_env_file=None)
            token = issue_development_token(settings, "visitor_http")
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            base = f"http://127.0.0.1:{port}"

            def request(path, body=None):
                headers = {"Content-Type": "application/json", "Authorization": "Bearer " + token}
                req = urllib.request.Request(
                    base + path,
                    data=json.dumps(body).encode() if body is not None else None,
                    headers=headers,
                )
                with urllib.request.urlopen(req, timeout=10) as response:
                    return json.load(response)

            def advance(seconds):
                nonlocal instant
                instant += timedelta(seconds=seconds)
                clock_file.write_text(instant.isoformat())

            with tempfile.TemporaryFile() as log:

                def start_server():
                    process = subprocess.Popen(
                        [
                            sys.executable,
                            "-m",
                            "uvicorn",
                            "smoke_visitors:create_smoke_app",
                            "--factory",
                            "--app-dir",
                            str(root / "backend/scripts"),
                            "--host",
                            "127.0.0.1",
                            "--port",
                            str(port),
                            "--no-access-log",
                        ],
                        cwd=root / "backend",
                        env=environment,
                        stdout=log,
                        stderr=log,
                        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                    )
                    for _ in range(100):
                        try:
                            if request("/health/ready")["status"] == "ready":
                                return process
                        except urllib.error.URLError:
                            if process.poll() is not None:
                                log.seek(0)
                                raise RuntimeError(log.read().decode()) from None
                            time.sleep(0.1)
                    process.terminate()
                    process.wait(timeout=10)
                    raise RuntimeError("Visitor smoke server did not start")

                server = start_server()
                account = request(
                    "/v1/accounts",
                    {
                        "requestId": str(uuid4()),
                        "username": "visitor_http",
                        "displayName": "Visitor HTTP fixture",
                        "gameTimezone": "Asia/Singapore",
                    },
                )
                request(
                    "/v1/me/garden/edits",
                    {
                        "requestId": str(uuid4()),
                        "expectedLayoutVersion": 0,
                        "catalogVersion": "development-oak-v1",
                        "actions": [
                            {
                                "action": "plant",
                                "plantId": account["starterPlantId"],
                                "x": 2,
                                "y": 2,
                                "rotationDegrees": 0,
                            }
                        ],
                    },
                )
                initial = request("/v1/me/visitors")
                assert initial["storedVisitsMicroUnits"] == "0"
                installation = str(uuid4())
                active = request(
                    "/v1/me/visitor-sessions",
                    {"requestId": str(uuid4()), "installationId": installation},
                )
                session_id = active["session"]["sessionId"]
                for _ in range(9):
                    advance(10)
                    active = request(
                        f"/v1/me/visitor-sessions/{session_id}/heartbeat",
                        {"requestId": str(uuid4()), "installationId": installation},
                    )
                    if active["opportunities"]:
                        break
                assert len(active["opportunities"]) == 1
                opportunity_id = active["opportunities"][0]["opportunityId"]
                welcome_body = {"requestId": str(uuid4())}
                welcome_path = f"/v1/me/visitor-opportunities/{opportunity_id}/welcome"
                welcome = request(welcome_path, welcome_body)
                assert welcome["tokens"] == "1" and welcome["summary"]["hostedActive"] == "1"
                request(
                    f"/v1/me/visitor-sessions/{session_id}/end",
                    {"requestId": str(uuid4()), "installationId": installation},
                )
                advance(600)
                stored = request("/v1/me/visitors")
                assert stored["storedVisitsMicroUnits"] == "2500000"
                claim_body = {"requestId": str(uuid4())}
                claim = request("/v1/me/stored-visits/claim", claim_body)
                assert claim["tokens"] == "2" and claim["summary"]["tokenBalance"] == "3"
                assert claim["summary"]["storedVisitsMicroUnits"] == "500000"
                server.terminate()
                server.wait(timeout=10)
                server = None
                advance(240)
                server = start_server()
                assert request(welcome_path, welcome_body) == welcome
                assert request("/v1/me/stored-visits/claim", claim_body) == claim
                assert request("/v1/me/visitors")["claimableVisits"] == "1"
                if args.export_frontend_contract:
                    target = (
                        root / "frontend/MovementForest/Resources/Fixtures/visitor-contract.json"
                    )
                    target.write_text(
                        json.dumps(
                            {
                                "initial": initial,
                                "active": active,
                                "welcome": welcome,
                                "stored": stored,
                                "claim": claim,
                            },
                            indent=2,
                        )
                        + "\n"
                    )
                print(
                    "PASS: visitor HTTP activation, session/heartbeat, welcome, end, "
                    "stored fraction, claim and restart replay."
                )
    finally:
        if server is not None:
            server.terminate()
            server.wait(timeout=10)
        with admin.connect() as connection:
            connection.execute(text(f'DROP DATABASE "{name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
