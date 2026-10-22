"""Real HTTP B4/B5 walkthrough against a disposable, randomly named PostgreSQL database.

From the repository root: python backend/scripts/smoke_activity.py
Requires FOREST_TEST_DATABASE_URL with CREATEDB. Does not modify its admin database.
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
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api.auth import issue_development_token
from forest_api.config import Settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--export-frontend-contract",
        action="store_true",
        help="Write synthetic native fixtures from this disposable HTTP walkthrough",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    admin_url = make_url(os.environ["FOREST_TEST_DATABASE_URL"])
    admin = create_engine(admin_url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    database_name = "forest_test_http_" + uuid4().hex
    server = None
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{database_name}" TEMPLATE template0'))
    try:
        environment = dict(os.environ)
        environment.update(
            FOREST_DATABASE_URL=admin_url.set(database=database_name).render_as_string(
                hide_password=False
            ),
            FOREST_ENVIRONMENT="test",
            FOREST_AUTH_MODE="development",
            FOREST_DEV_AUTH_SECRET=uuid4().hex + uuid4().hex,
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
        token = issue_development_token(settings, "http_activity")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base = f"http://127.0.0.1:{port}"

        def request(path, body=None, method=None, authenticated=True):
            headers = {"Content-Type": "application/json"}
            if authenticated:
                headers["Authorization"] = "Bearer " + token
            req = urllib.request.Request(
                base + path,
                data=json.dumps(body).encode() if body is not None else None,
                headers=headers,
                method=method,
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

        with tempfile.TemporaryFile() as log:
            server = subprocess.Popen(
                [
                    sys.executable,
                    "-m",
                    "uvicorn",
                    "forest_api.main:create_app",
                    "--factory",
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
                    assert request("/health/ready", authenticated=False)["status"] == "ready"
                    break
                except (urllib.error.URLError, AssertionError):
                    if server.poll() is not None:
                        raise RuntimeError("HTTP server failed during startup") from None
                    time.sleep(0.1)
            else:
                raise RuntimeError("HTTP server did not become ready")
            account = request(
                "/v1/accounts",
                {
                    "requestId": str(uuid4()),
                    "username": "http_activity",
                    "displayName": "HTTP activity fixture",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            installation = str(uuid4())
            enrol = request(
                "/v1/activity/enrolments",
                {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "observedAt": datetime.now(UTC).isoformat(),
                    "steps": 2000,
                },
            )
            planted = request(
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
                            "rotationDegrees": 35.12,
                        }
                    ],
                },
            )
            instant = datetime.now(UTC)
            body = {
                "requestId": str(uuid4()),
                "installationId": installation,
                "deviceId": enrol["device"]["deviceId"],
                "observedAt": instant.isoformat(),
                "days": [
                    {
                        "gameDate": instant.astimezone(ZoneInfo("Asia/Singapore"))
                        .date()
                        .isoformat(),
                        "steps": 3000,
                    }
                ],
            }
            result = request("/v1/activity/sync", body)
            assert result["garden"]["plants"][0]["growthMicroUnits"] == "10000000"
            assert result["garden"]["totalAttractionMicroUnits"] == "2000000"
            assert result["garden"]["layoutVersion"] == 1
            assert request("/v1/activity/sync", body) == result
            pending = request("/v1/me/reward-recaps")
            assert pending["recaps"][0]["recapId"] == result["recapId"]
            acknowledgement = request(
                f"/v1/reward-recaps/{result['recapId']}/ack", {"requestId": str(uuid4())}
            )
            assert request("/v1/me/reward-recaps")["recaps"] == []
            status = request("/v1/me/activity")
            assert status["activitySteps"] == "1000"
            if args.export_frontend_contract:
                contract = {
                    "profile": account["profile"],
                    "catalogue": request("/v1/catalog"),
                    "gardenBeforeSync": planted["garden"],
                    "enrolment": enrol,
                    "syncRequest": body,
                    "syncResult": result,
                    "status": status,
                    "recaps": pending,
                    "acknowledgement": acknowledgement,
                }
                target = root / "frontend/MovementForest/Resources/Fixtures/activity-contract.json"
                target.write_text(json.dumps(contract, indent=2) + "\n", encoding="utf-8")
            request(
                "/v1/me/garden/edits",
                {
                    "requestId": str(uuid4()),
                    "expectedLayoutVersion": 1,
                    "catalogVersion": "development-oak-v1",
                    "actions": [{"action": "store", "plantId": account["starterPlantId"]}],
                },
            )
            assert request("/v1/me/inventory")["plants"][0]["growthMicroUnits"] == "10000000"
            assert request("/v1/activity/sync", body) == result
            assert request("/v1/me/garden")["plants"] == []
            print("HTTP walkthrough passed: readiness, account, enrolment, placement, growth,")
            print(
                "attraction, durable replay, recap recovery/ack, status and storage preservation."
            )
            server.terminate()
            server.wait(timeout=10)
            server = None
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        with admin.connect() as connection:
            connection.execute(text(f'DROP DATABASE "{database_name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
