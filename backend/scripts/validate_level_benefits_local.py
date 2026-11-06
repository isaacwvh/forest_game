"""Exercise level benefits over HTTP in a disposable database; never the game DB."""

import argparse
import json
import os
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4
from zoneinfo import ZoneInfo

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.level_benefits import activate
from forest_api.main import create_app
from forest_api.seed import seed_development_catalogue

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-contract", action="store_true")
    args = parser.parse_args()
    configured = os.environ.get("FOREST_TEST_DATABASE_URL")
    if not configured:
        parser.error("Set FOREST_TEST_DATABASE_URL to a PostgreSQL test admin connection")
    url = make_url(configured)
    if url.drivername != "postgresql+psycopg":
        parser.error("PostgreSQL through psycopg is required")
    name = "forest_test_level_benefits_" + uuid4().hex
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    application = None
    previous = os.environ.get("FOREST_DATABASE_URL")
    try:
        with admin.connect() as connection:
            connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
        test_url = url.set(database=name).render_as_string(hide_password=False)
        os.environ["FOREST_DATABASE_URL"] = test_url
        command.upgrade(Config(str(ROOT / "backend/alembic.ini")), "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=test_url,
            auth_mode="development",
            dev_auth_secret="level-smoke-only-32-character-test-secret",
        )
        application = create_app(settings)
        now = datetime.now(UTC)
        application.state.clock = lambda: now
        with application.state.database.sessions() as session:
            seed_development_catalogue(session, settings)
        with TestClient(application) as client:
            headers = {
                "Authorization": "Bearer " + issue_development_token(settings, "level_smoke")
            }

            def post(path, body):
                response = client.post(path, json=body, headers=headers)
                assert response.status_code == 200, response.text
                return response.json()

            def summary():
                response = client.get("/v1/me/account-summary", headers=headers)
                assert response.status_code == 200, response.text
                return response.json()

            post(
                "/v1/accounts",
                {
                    "requestId": str(uuid4()),
                    "username": "level_smoke",
                    "displayName": "Level benefits smoke",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            installation = str(uuid4())
            device = post(
                "/v1/activity/enrolments",
                {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "observedAt": now.isoformat(),
                    "steps": 0,
                },
            )

            def sync(steps):
                body = {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "deviceId": device["device"]["deviceId"],
                    "observedAt": now.isoformat(),
                    "days": [
                        {
                            "gameDate": now.astimezone(ZoneInfo("Asia/Singapore"))
                            .date()
                            .isoformat(),
                            "steps": steps,
                        }
                    ],
                }
                return post("/v1/activity/sync", body), body

            sync(34999)
            with application.state.database.sessions() as session:
                activate(session, settings, apply=True, clock=lambda: now)
            before = summary()
            response, request = sync(35000)
            after = summary()
            assert before["levelUpNotice"] is None
            assert before["benefits"]["baseOfflineCapacity"] == 825
            assert after["benefits"]["plantLimit"] == 60
            assert after["benefits"]["baseOfflineCapacity"] == 900
            assert post("/v1/activity/sync", request) == response
            notice = after["levelUpNotice"]
            path = f"/v1/me/level-up-notices/{notice['id']}/present"
            claim = {"requestId": str(uuid4()), "installationId": installation}
            assert post(path, claim)["mayPresent"]
            assert post(path, claim)["mayPresent"]
            assert not post(path, {"requestId": str(uuid4()), "installationId": str(uuid4())})[
                "mayPresent"
            ]
            assert summary()["levelUpNotice"] is None
            if args.write_contract:
                path = (
                    ROOT / "frontend/MovementForest/Resources/Fixtures/level-benefits-contract.json"
                )
                path.write_text(
                    json.dumps({"before": before, "after": after}, indent=2) + "\n",
                    encoding="utf-8",
                )
            print(
                "PASS: real HTTP level 4 -> 5, 825 -> 900 offline, 50 -> 60 plants; "
                "sync replay and cross-device presentation claim; test DB cleaned."
            )
    finally:
        if application:
            application.state.database.engine.dispose()
        if previous is None:
            os.environ.pop("FOREST_DATABASE_URL", None)
        else:
            os.environ["FOREST_DATABASE_URL"] = previous
        assert name.startswith("forest_test_level_benefits_") and name.replace("_", "").isalnum()
        with admin.connect() as connection:
            connection.execute(text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
