"""Disposable HTTP milestone walkthrough; optionally export synthetic native contracts."""

import argparse
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url

from forest_api import (
    launch_balance,
    milestone_tracks,
    progression,
    recovery,
    visitor_rescale,
    woodland,
)
from forest_api.auth import issue_development_token
from forest_api.config import Settings
from forest_api.main import create_app
from forest_api.seed import seed_development_catalogue
from forest_api.visitor_models import VisitorWallet

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-contract", action="store_true")
    args = parser.parse_args()
    url = make_url(os.environ["FOREST_TEST_DATABASE_URL"])
    if url.drivername != "postgresql+psycopg":
        raise ValueError("Use a PostgreSQL test admin connection")
    name = "forest_test_milestones_" + uuid4().hex
    admin = create_engine(url, isolation_level="AUTOCOMMIT", hide_parameters=True)
    app = None
    previous = os.environ.get("FOREST_DATABASE_URL")
    with admin.connect() as connection:
        connection.execute(text(f'CREATE DATABASE "{name}" TEMPLATE template0'))
    try:
        test_url = url.set(database=name).render_as_string(hide_password=False)
        os.environ["FOREST_DATABASE_URL"] = test_url
        command.upgrade(Config(str(ROOT / "backend/alembic.ini")), "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=test_url,
            auth_mode="development",
            dev_auth_secret="milestones-synthetic-only-secret-at-least-32-characters",
        )
        app = create_app(settings)
        with app.state.database.sessions() as session:
            seed_development_catalogue(session, settings)
        with app.state.database.sessions() as session:
            launch = launch_balance.publish(session, settings)
        now = datetime.fromisoformat(launch["effectiveAt"]) + timedelta(days=1)
        app.state.clock = lambda: now
        for publish in (visitor_rescale.publish, woodland.publish):
            with app.state.database.sessions() as session:
                if publish == woodland.publish:
                    publish(session, settings, apply=True, clock=lambda: now)
                else:
                    publish(session, settings, clock=lambda: now)
        with app.state.database.sessions() as session:
            milestone_tracks.activate(session, settings, apply=True, clock=lambda: now)
        with TestClient(app) as client:
            headers = {
                "Authorization": "Bearer " + issue_development_token(settings, "milestone_fixture"),
                "X-Forest-Woodland": "1",
                "X-Forest-Milestones": "1",
                "X-Forest-Recovery": "1",
            }

            def post(path, **body):
                result = client.post(
                    path, headers=headers, json={"requestId": str(uuid4()), **body}
                )
                assert result.status_code == 200, result.text
                return result.json()

            def get(path):
                result = client.get(path, headers=headers)
                assert result.status_code == 200, result.text
                return result.json()

            account = post(
                "/v1/accounts",
                username="milestone_fixture",
                displayName="Synthetic player",
                gameTimezone="Asia/Singapore",
            )
            fresh = get("/v1/me/collection")
            installation = str(uuid4())
            device = post(
                "/v1/activity/enrolments",
                installationId=installation,
                observedAt=now.isoformat(),
                steps=0,
            )
            post(
                "/v1/activity/sync",
                installationId=installation,
                deviceId=device["device"]["deviceId"],
                observedAt=now.isoformat(),
                days=[
                    {
                        "gameDate": now.astimezone(ZoneInfo("Asia/Singapore")).date().isoformat(),
                        "steps": 200000,
                    }
                ],
            )
            earned = get("/v1/me/collection")
            receipt = post("/v1/me/milestones/steps_200000/claim")
            pack_receipt = post("/v1/me/milestones/steps_new_beginnings/claim")
            owner = UUID(account["profile"]["userId"])
            with app.state.database.sessions.begin() as session:
                progression.reconcile(session, owner, session.get(VisitorWallet, owner))
            with app.state.database.sessions() as session:
                recovery.maintain(session, apply=True, now=now + timedelta(days=90))
            replay = client.post(
                "/v1/me/milestones/steps_200000/claim",
                headers=headers,
                json={"requestId": receipt["requestId"]},
            )
            assert replay.status_code == 200 and replay.json() == receipt
            final = get("/v1/me/account-summary")
            assert final["wallet"]["stepGemsEarned"] == "20"
            assert final["wallet"]["bonusGemsEarned"] == "2"
            if args.write_contract:
                path = ROOT / "frontend/MovementForest/Resources/Fixtures/milestones-contract.json"
                path.write_text(
                    json.dumps(
                        {
                            "synthetic": True,
                            "fresh": fresh,
                            "earned": earned,
                            "receipt": receipt,
                            "packReceipt": pack_receipt,
                            "account": final,
                        },
                        indent=2,
                    )
                    + "\n",
                    encoding="utf-8",
                )
            print(
                json.dumps(
                    {
                        "status": "passed",
                        "quests": len(fresh["milestones"]),
                        "bonusGems": "2",
                        "packVersion": 20,
                        "compactedReplay": "passed",
                    }
                )
            )
    finally:
        if app:
            app.state.database.engine.dispose()
        if previous is None:
            os.environ.pop("FOREST_DATABASE_URL", None)
        else:
            os.environ["FOREST_DATABASE_URL"] = previous
        with admin.connect() as connection:
            connection.execute(text(f'DROP DATABASE "{name}" WITH (FORCE)'))
        admin.dispose()


if __name__ == "__main__":
    main()
