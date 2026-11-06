"""Real HTTP smoke flow in a disposable forest_test_* database, never the game DB."""

import argparse
import json
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api import progression, recovery
from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.main import create_app
from forest_api.seed import seed_development_catalogue

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-contract", action="store_true")
    args = parser.parse_args()
    configured = os.environ.get("FOREST_TEST_DATABASE_URL")
    if not configured:
        parser.error(
            "Set FOREST_TEST_DATABASE_URL to a disposable-test PostgreSQL admin connection"
        )
    url = make_url(configured)
    if url.drivername != "postgresql+psycopg":
        parser.error("PostgreSQL through psycopg is required")
    name = "forest_test_progression_" + uuid4().hex
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    application = None
    previous_url = os.environ.get("FOREST_DATABASE_URL")
    try:
        with admin.connect() as conn:
            conn.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
        test_url = url.set(database=name).render_as_string(hide_password=False)
        os.environ["FOREST_DATABASE_URL"] = test_url
        command.upgrade(Config(str(ROOT / "backend/alembic.ini")), "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=test_url,
            auth_mode="development",
            dev_auth_secret="progression-smoke-only-32-character-secret",
        )
        application = create_app(settings)
        now = datetime(2026, 11, 6, 4, tzinfo=UTC)
        application.state.clock = lambda: now
        with application.state.database.sessions() as session:
            seed_development_catalogue(session, settings)
        with TestClient(application) as client:
            headers = {
                "Authorization": "Bearer " + issue_development_token(settings, "progression_smoke"),
                "X-Forest-Recovery": "1",
            }

            def post(path, body):
                result = client.post(path, json=body, headers=headers)
                assert result.status_code == 200, result.text
                return result.json()

            def summary():
                result = client.get("/v1/me/account-summary", headers=headers)
                assert result.status_code == 200, result.text
                assert result.headers["cache-control"] == "no-store"
                return result.json()

            account = post(
                "/v1/accounts",
                {
                    "requestId": str(uuid4()),
                    "username": "progression_smoke",
                    "displayName": "Progression smoke",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            fresh = summary()
            installation = str(uuid4())
            enrolled = post(
                "/v1/activity/enrolments",
                {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "observedAt": now.isoformat(),
                    "steps": 0,
                },
            )
            requests = []
            for steps in (9999, 10000, 37250):
                body = {
                    "requestId": str(uuid4()),
                    "installationId": installation,
                    "deviceId": enrolled["device"]["deviceId"],
                    "observedAt": now.isoformat(),
                    "days": [{"gameDate": "2026-11-06", "steps": steps}],
                }
                post("/v1/activity/sync", body)
                requests.append(body)
            grown = summary()
            assert grown["wallet"]["gemBalance"] == "3"
            assert grown["progression"]["level"] == 5
            assert grown["progression"]["xpIntoLevel"] == "22"
            assert grown["progression"]["stepsIntoNextGem"] == 7250
            post("/v1/activity/sync", requests[1])
            assert summary() == grown
            with application.state.database.sessions.begin() as session:
                progression.reconcile(
                    session,
                    UUID(account["profile"]["userId"]),
                    session.get(progression.VisitorWallet, UUID(account["profile"]["userId"])),
                )
            with application.state.database.sessions() as session:
                recovery.maintain(session, apply=True, now=datetime.now(UTC) + timedelta(days=60))
            assert "recovery" in post("/v1/activity/sync", requests[1])
            assert summary() == grown
            if args.write_contract:
                path = (
                    ROOT
                    / "frontend/MovementForest/Resources/Fixtures/account-summary-contract.json"
                )
                path.write_text(
                    json.dumps({"fresh": fresh, "grown": grown}, indent=2) + "\n", encoding="utf-8"
                )
            print(
                json.dumps(
                    {
                        "status": "passed",
                        "steps": "37250",
                        "gems": "3",
                        "level": 5,
                        "xpIntoLevel": "22",
                        "retryAndCompactedRecovery": "passed",
                    }
                )
            )
    finally:
        if application:
            application.state.database.engine.dispose()
        if previous_url is None:
            os.environ.pop("FOREST_DATABASE_URL", None)
        else:
            os.environ["FOREST_DATABASE_URL"] = previous_url
        assert name.startswith("forest_test_progression_") and name.replace("_", "").isalnum()
        with admin.connect() as conn:
            conn.execute(text(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
