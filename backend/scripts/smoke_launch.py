"""Real HTTP launch publication, optional activity and milestone restart recovery.

Uses only a newly created forest_test_* database, with no development catalogue.
"""

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
from zoneinfo import ZoneInfo

from alembic import command
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.launch_balance import VERSION, publish


def main():
    root = Path(__file__).resolve().parents[2]
    url = make_url(os.environ["FOREST_TEST_DATABASE_URL"])
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    name = "forest_test_launch_" + uuid4().hex
    server = database = None
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
    try:
        environment = dict(os.environ)
        environment.update(
            FOREST_DATABASE_URL=url.set(database=name).render_as_string(hide_password=False),
            FOREST_ENVIRONMENT="test",
            FOREST_AUTH_MODE="development",
            FOREST_DEV_AUTH_SECRET="launch-http-fixture-only-secret-at-least-32-characters",
        )
        previous = os.environ.get("FOREST_DATABASE_URL")
        os.environ["FOREST_DATABASE_URL"] = environment["FOREST_DATABASE_URL"]
        try:
            command.upgrade(Config(str(root / "backend/alembic.ini")), "head")
        finally:
            if previous is None:
                os.environ.pop("FOREST_DATABASE_URL", None)
            else:
                os.environ["FOREST_DATABASE_URL"] = previous
        settings = Settings(
            _env_file=None,
            **{
                key.removeprefix("FOREST_").lower(): environment[key]
                for key in [
                    "FOREST_DATABASE_URL",
                    "FOREST_ENVIRONMENT",
                    "FOREST_AUTH_MODE",
                    "FOREST_DEV_AUTH_SECRET",
                ]
            },
        )
        database = Database(settings)
        with database.sessions() as session:
            publication = publish(session, settings)
        time.sleep(
            max(
                0,
                (
                    datetime.fromisoformat(publication["effectiveAt"]) - datetime.now(UTC)
                ).total_seconds(),
            )
            + 0.1
        )
        token = issue_development_token(settings, "launch_http")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base = f"http://127.0.0.1:{port}"

        def request(path, body=None, *, authenticated=True):
            headers = {"Content-Type": "application/json"}
            if authenticated:
                headers["Authorization"] = "Bearer " + token
            req = urllib.request.Request(
                base + path,
                headers=headers,
                data=json.dumps(body).encode() if body is not None else None,
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

        with tempfile.TemporaryFile() as log:

            def start():
                process = subprocess.Popen(
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
                try:
                    for _ in range(100):
                        try:
                            if request("/health/ready", authenticated=False)["status"] == "ready":
                                return process
                        except urllib.error.URLError:
                            if process.poll() is not None:
                                raise RuntimeError("Launch smoke server failed to start") from None
                            time.sleep(0.1)
                    raise RuntimeError("Launch smoke server did not become ready")
                except BaseException:
                    process.terminate()
                    process.wait(timeout=10)
                    raise

            server = start()
            account = request(
                "/v1/accounts",
                {
                    "requestId": str(uuid4()),
                    "username": "launch_http",
                    "displayName": "Launch HTTP",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            catalog = request("/v1/catalog")
            assert catalog["catalogVersion"] == VERSION and not catalog["isFixture"]
            installation = str(uuid4())
            enrol = request(
                "/v1/activity/enrolments",
                {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "observedAt": datetime.now(UTC).isoformat(),
                    "steps": 0,
                    "walkingRunningDistanceMetres": "0.000",
                    "activeEnergyKcal": "0.000",
                    "flightsClimbed": 0,
                    "workoutsAvailable": True,
                },
            )
            request(
                "/v1/me/garden/edits",
                {
                    "requestId": str(uuid4()),
                    "catalogVersion": VERSION,
                    "expectedLayoutVersion": 0,
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
            start_time = datetime.now(UTC)
            end = start_time + timedelta(seconds=1)
            time.sleep(1.1)
            observed = datetime.now(UTC)
            body = {
                "requestId": str(uuid4()),
                "installationId": installation,
                "deviceId": enrol["device"]["deviceId"],
                "observedAt": observed.isoformat(),
                "days": [
                    {
                        "gameDate": observed.astimezone(ZoneInfo("Asia/Singapore"))
                        .date()
                        .isoformat(),
                        "steps": 10000,
                        "walkingRunningDistanceMetres": "1000.000",
                        "activeEnergyKcal": "100.000",
                        "flightsClimbed": 5,
                    }
                ],
                "workoutsAvailable": True,
                "workouts": [
                    {
                        "workoutId": str(uuid4()),
                        "originalType": 37,
                        "sourceBundleIdentifier": "example.recorded",
                        "start": start_time.isoformat(),
                        "end": end.isoformat(),
                        "durationMilliseconds": 1000,
                    }
                ],
            }
            result = request("/v1/activity/sync", body)
            assert result["garden"]["plants"][0]["growthMicroUnits"] == "100004166"
            assert result["activityMetrics"]["workout_minutes.running"] == "1/60"
            assert result["activityMetrics"]["walking_running_distance_km"] == "1"
            milestone_body = {"requestId": str(uuid4())}
            milestone = request("/v1/me/milestones/first_movement/claim", milestone_body)
            assert milestone["tokensEarned"] == "30"
            request("/v1/me/milestones/first_seedling/claim", {"requestId": str(uuid4())})
            summary = request("/v1/me/collection")
            assert summary["tokenBalance"] == "60"
            server.terminate()
            server.wait(timeout=10)
            server = start()
            assert request("/v1/activity/sync", body) == result
            assert request("/v1/me/milestones/first_movement/claim", milestone_body) == milestone
            assert request("/v1/me/collection")["tokenBalance"] == "60"
            print(
                "PASS: HTTP nonfixture launch, typed daily/workout growth, seedling, "
                "milestone ledger, restart/replay."
            )
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait(timeout=5)
        if database is not None:
            database.engine.dispose()
        with admin.connect() as connection:
            connection.execute(text(f'DROP DATABASE "{name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
