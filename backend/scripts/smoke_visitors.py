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
from zoneinfo import ZoneInfo

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
        with tempfile.TemporaryDirectory(prefix="forest-visitor-http-") as temporary:
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
                        "catalogVersion": request("/v1/catalog")["catalogVersion"],
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
                # Complete the collection loop using actually earned visitor tokens.
                advance(2400)
                earned = request("/v1/me/stored-visits/claim", {"requestId": str(uuid4())})
                assert int(earned["summary"]["tokenBalance"]) >= 10
                shop = request("/v1/me/collection")
                exchange_body = {
                    "requestId": str(uuid4()),
                    "offerId": "woodland",
                    "offerVersion": 2,
                    "quantity": 2,
                }
                exchanged = request("/v1/me/exchanges", exchange_body)
                assert int(exchanged["tokenBalance"]) == int(shop["tokenBalance"]) - 10
                assert request("/v1/me/exchanges", exchange_body) == exchanged
                owned_pack = exchanged["packs"][0]["ownedPackId"]
                opening_path = f"/v1/me/packs/{owned_pack}/open"
                opening_body = {"requestId": str(uuid4())}
                opening = request(opening_path, opening_body)
                assert opening["plant"]["growthMicroUnits"] == "0"
                assert opening["plant"]["placement"] is None
                assert request(opening_path, {"requestId": str(uuid4())}) == opening
                assert opening["plant"]["plantId"] in [
                    p["plantId"] for p in request("/v1/me/inventory")["plants"]
                ]
                server.terminate()
                server.wait(timeout=10)
                server = start_server()
                assert request(opening_path, opening_body) == opening
                assert request("/v1/me/exchanges", exchange_body) == exchanged
                # Use a guaranteed-species offer to exercise Moonwillow's assets,
                # storage, placement and growth without forcing a random result.
                advance(2400)
                request("/v1/me/stored-visits/claim", {"requestId": str(uuid4())})
                moon_purchase = request(
                    "/v1/me/exchanges",
                    {
                        "requestId": str(uuid4()),
                        "offerId": "moonwillow",
                        "offerVersion": 1,
                        "quantity": 1,
                    },
                )
                moon_path = f"/v1/me/packs/{moon_purchase['packs'][0]['ownedPackId']}/open"
                moon = request(moon_path, {"requestId": str(uuid4())})
                assert moon["plant"]["speciesId"] == "moonwillow"
                assert moon["plant"]["placement"] is None
                enrolled = request(
                    "/v1/activity/enrolments",
                    {
                        "requestId": str(uuid4()),
                        "installationId": installation,
                        "observedAt": instant.isoformat(),
                        "steps": 0,
                    },
                )
                garden = request("/v1/me/garden")
                request(
                    "/v1/me/garden/edits",
                    {
                        "requestId": str(uuid4()),
                        "expectedLayoutVersion": garden["layoutVersion"],
                        "catalogVersion": garden["catalogVersion"],
                        "actions": [
                            {
                                "action": "plant",
                                "plantId": moon["plant"]["plantId"],
                                "x": 6,
                                "y": 6,
                                "rotationDegrees": 0,
                            }
                        ],
                    },
                )
                advance(10)
                grown = request(
                    "/v1/activity/sync",
                    {
                        "requestId": str(uuid4()),
                        "installationId": installation,
                        "deviceId": enrolled["device"]["deviceId"],
                        "observedAt": instant.isoformat(),
                        "days": [
                            {
                                "gameDate": instant.astimezone(ZoneInfo("Asia/Singapore"))
                                .date()
                                .isoformat(),
                                "steps": 10000,
                            }
                        ],
                    },
                )
                assert (
                    next(
                        p
                        for p in grown["garden"]["plants"]
                        if p["plantId"] == moon["plant"]["plantId"]
                    )["growthStage"]
                    == "seedling"
                )
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
                    collection_target = (
                        root / "frontend/MovementForest/Resources/Fixtures/collection-contract.json"
                    )
                    collection_target.write_text(
                        json.dumps(
                            {
                                "summary": shop,
                                "exchange": exchanged,
                                "opening": opening,
                                "packs": request("/v1/me/packs"),
                                "catalogue": request("/v1/catalog"),
                                "moonwillowOpening": moon,
                            },
                            indent=2,
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                print(
                    "PASS: visitor HTTP activation, session/heartbeat, welcome, end, "
                    "stored fraction, claim, token exchange, pack opening and restart replay."
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
