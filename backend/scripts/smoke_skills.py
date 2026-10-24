"""Real HTTP Sleeping Dew walkthrough on a disposable PostgreSQL database."""

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
from forest_api.collection_seed import seed_collection
from forest_api.config import Settings
from forest_api.database import Database
from forest_api.seed import seed_development_catalogue
from forest_api.skill_seed import grant_adult_moonwillow, seed_skills


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--export-frontend-contract", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    url = make_url(os.environ["FOREST_TEST_DATABASE_URL"])
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    name = "forest_test_skills_" + uuid4().hex
    server = database = None
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
    try:
        environment = dict(os.environ)
        environment.update(
            FOREST_DATABASE_URL=url.set(database=name).render_as_string(hide_password=False),
            FOREST_ENVIRONMENT="test",
            FOREST_AUTH_MODE="development",
            FOREST_DEV_AUTH_SECRET="skills-http-fixture-only-secret-at-least-32-characters",
        )
        settings = Settings(
            _env_file=None,
            **{
                key.removeprefix("FOREST_").lower(): value
                for key, value in environment.items()
                if key
                in {
                    "FOREST_DATABASE_URL",
                    "FOREST_ENVIRONMENT",
                    "FOREST_AUTH_MODE",
                    "FOREST_DEV_AUTH_SECRET",
                }
            },
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
        database = Database(settings)
        with database.sessions() as session:
            seed_development_catalogue(session, settings)
            seed_collection(session, settings)
            seed_skills(session, settings)
        token = issue_development_token(settings, "skills_http")
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
                for _ in range(100):
                    try:
                        if request("/health/ready", authenticated=False)["status"] == "ready":
                            return process
                    except urllib.error.URLError:
                        if process.poll() is not None:
                            raise RuntimeError("Skills smoke server failed to start") from None
                        time.sleep(0.1)
                process.terminate()
                process.wait(timeout=10)
                raise RuntimeError("Skills smoke server did not become ready")

            server = start()
            account = request(
                "/v1/accounts",
                {
                    "requestId": str(uuid4()),
                    "username": "skills_http",
                    "displayName": "Skills HTTP fixture",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            with database.sessions() as session:
                grant = grant_adult_moonwillow(session, settings, "skills_http")
                assert grant_adult_moonwillow(session, settings, "skills_http") == grant
            inventory = request("/v1/me/inventory")
            catalogue = request("/v1/catalog")
            installation = str(uuid4())
            enrol = request(
                "/v1/activity/enrolments",
                {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "observedAt": datetime.now(UTC).isoformat(),
                    "steps": 0,
                },
            )
            empty = request("/v1/me/garden")
            assert empty["skillSummary"]["activeSkills"] == []
            planted = request(
                "/v1/me/garden/edits",
                {
                    "requestId": str(uuid4()),
                    "catalogVersion": catalogue["catalogVersion"],
                    "expectedLayoutVersion": 0,
                    "actions": [
                        {"action": "plant", "plantId": plant, "x": x, "y": x, "rotationDegrees": 0}
                        for plant, x in [(account["starterPlantId"], 2), (grant["plantId"], 6)]
                    ],
                },
            )
            assert len(planted["garden"]["skillSummary"]["activeSkills"]) == 1
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
                        "steps": 1000,
                    }
                ],
            }
            result = request("/v1/activity/sync", body)
            oak = next(p for p in result["garden"]["plants"] if p["speciesId"] == "oak")
            assert oak["growthMicroUnits"] == "10400000"
            recaps = request("/v1/me/reward-recaps")
            server.terminate()
            server.wait(timeout=10)
            server = start()
            assert request("/v1/activity/sync", body) == result
            stored = request(
                "/v1/me/garden/edits",
                {
                    "requestId": str(uuid4()),
                    "catalogVersion": catalogue["catalogVersion"],
                    "expectedLayoutVersion": 1,
                    "actions": [{"action": "store", "plantId": grant["plantId"]}],
                },
            )
            assert stored["garden"]["skillSummary"]["activeSkills"] == []
            assert request("/v1/activity/sync", body) == result
            body.update(requestId=str(uuid4()))
            body["days"][0]["steps"] = 2000
            neutral = request("/v1/activity/sync", body)
            assert neutral["garden"]["plants"][0]["growthMicroUnits"] == "20400000"
            if args.export_frontend_contract:
                target = root / "frontend/MovementForest/Resources/Fixtures/skills-contract.json"
                target.write_text(
                    json.dumps(
                        {
                            "catalogue": catalogue,
                            "inventory": inventory,
                            "emptyGarden": empty,
                            "plantedGarden": planted["garden"],
                            "syncResult": result,
                            "storedGarden": stored["garden"],
                            "recaps": recaps,
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            print(
                "PASS: HTTP Sleeping Dew grant/storage/activation, exact 4% growth, recap, "
                "server restart/replay, source storage and neutral subsequent growth."
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
