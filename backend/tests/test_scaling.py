"""S1-S3 regressions on isolated PostgreSQL, including actual HTTP recovery."""

import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, func, select, text
from sqlalchemy.exc import IntegrityError
from test_activity import actors as actors
from test_activity import body_for
from test_activity_launch import player as player
from test_visitor_rescale import scene as scene
from test_visitors import forest as forest
from test_visitors import later, opportunity

from forest_api import recovery, storage_usage
from forest_api.models import ApiRequest, Base, OwnedPlant, User
from forest_api.visitor_models import VisitorControl, VisitorSession


def expire(app, *, days=31, apply=True):
    with app.state.database.sessions() as session:
        return recovery.maintain(
            session, apply=apply, now=datetime.now(UTC) + timedelta(days=days), limit=5000
        )


def enabled(headers):
    return {**headers, "X-Forest-Recovery": "1"}


def test_all_game_tables_have_a_storage_owner(app):
    assert all(
        storage_usage.category("public", name) != "unclassified" for name in Base.metadata.tables
    )
    with app.state.database.sessions() as session:
        report = storage_usage.report(session, exact=True)
    assert report["readOnly"]
    assert report["databaseBytes"] > 0
    assert all(
        row["total_bytes"] >= row["heap_bytes"] + row["index_bytes"] for row in report["tables"]
    )
    assert storage_usage.category("auth", "users") == "platform_shared"


@pytest.mark.parametrize("hours", [24, 7 * 24, 30 * 24])
def test_exact_expiry_unknown_policy_legacy_backfill_and_dry_run(app, register, hours):
    account = register()
    owner = UUID(account["profile"]["userId"])
    now = datetime.now(UTC)
    operation = {24: "visitor_end", 168: "visitor_claim", 720: "activity_sync"}[hours]
    key = uuid4()
    with app.state.database.sessions.begin() as session:
        session.add(
            ApiRequest(
                user_id=owner,
                request_id=key,
                operation=operation,
                payload_hash="a" * 64,
                response={"requestId": str(key)},
                created_at=now,
                recovery_version=1,
            )
        )
        session.add(
            ApiRequest(
                user_id=owner,
                request_id=uuid4(),
                operation="future_unknown",
                payload_hash="b" * 64,
                response={"important": True},
                created_at=now,
            )
        )
    with app.state.database.sessions() as session:
        counts = recovery.maintain(session, now=now + timedelta(hours=hours), apply=False)
        assert counts["compacted"] == 1
    with app.state.database.sessions() as session:
        assert session.get(ApiRequest, (owner, key)).completion is None
    with app.state.database.sessions() as session:
        counts = recovery.maintain(
            session, now=now + timedelta(hours=hours) - timedelta(microseconds=1), apply=True
        )
        assert counts["compacted"] == 0
    with app.state.database.sessions() as session:
        counts = recovery.maintain(session, now=now + timedelta(hours=hours), apply=True)
        assert counts["compacted"] == 1
    with app.state.database.sessions() as session:
        row = session.get(ApiRequest, (owner, key))
        assert row.response is None and row.completion is not None
        assert session.scalar(text("SELECT count(*) FROM api_requests WHERE response IS NULL")) == 1
        assert session.scalar(
            select(ApiRequest).where(ApiRequest.operation == "register_account")
        ).response
        assert (
            session.scalar(
                select(ApiRequest).where(ApiRequest.operation == "future_unknown")
            ).completion
            is None
        )


def test_compacted_zero_claim_cannot_collect_later_earnings(app, client, forest):
    forest["place"]()
    header = enabled(forest["headers"])
    body = {"requestId": str(uuid4())}
    first = client.post("/v1/me/stored-visits/claim", headers=header, json=body)
    assert first.json()["visits"] == "0"
    expire(app, days=8)
    later(forest, 3600)
    before = forest["read"]()
    retry = client.post("/v1/me/stored-visits/claim", headers=header, json=body).json()["recovery"]
    assert retry["status"] == "completed" and retry["outcome"]["visits"] == "0"
    assert forest["read"]()["claimableVisits"] == before["claimableVisits"]
    # A legacy client cannot misinterpret a compact result as a normal success.
    assert (
        client.post("/v1/me/stored-visits/claim", headers=forest["headers"], json=body).status_code
        == 426
    )


def test_compact_welcome_preserves_amount_and_target_conflicts(app, client, forest):
    visitor, _ = opportunity(forest)
    body = {"requestId": str(uuid4())}
    path = f"/v1/me/visitor-opportunities/{visitor['opportunityId']}/welcome"
    header = enabled(forest["headers"])
    original = client.post(path, json=body, headers=header).json()
    expire(app, days=8)
    replay = client.post(path, json=body, headers=header).json()["recovery"]
    assert replay["outcome"]["tokens"] == original["tokens"]
    assert replay["outcome"]["eventId"] == original["eventId"]
    wrong = client.post(
        f"/v1/me/visitor-opportunities/{uuid4()}/welcome", json=body, headers=header
    )
    assert wrong.status_code == 409
    assert client.post(path, json={"requestId": str(uuid4())}, headers=header).json() == original


def test_activity_completion_never_recredits_after_device_replacement(app, client, actors, headers):
    actor = actors()
    body = body_for(actor)
    header = enabled(headers())
    original = client.post("/v1/activity/sync", json=body, headers=header).json()
    with app.state.database.sessions() as session:
        before = session.get(OwnedPlant, actor["plant"]).growth_micro_units
    expire(app)
    replacement = {
        **actor["enrolment"],
        "requestId": str(uuid4()),
        "installationId": str(uuid4()),
        "expectedDeviceId": actor["device"],
        "steps": 4000,
    }
    assert (
        client.post("/v1/activity/enrolments", json=replacement, headers=header).status_code == 200
    )
    replay = client.post("/v1/activity/sync", json=body, headers=header)
    assert replay.json()["recovery"]["outcome"]["recapId"] == original["recapId"]
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == before
    body["days"][0]["steps"] += 1
    assert client.post("/v1/activity/sync", json=body, headers=header).status_code == 409


def test_compact_edit_profile_enrolment_ack_and_account_recovery(app, client, headers):
    header = enabled(headers())
    provision = {
        "requestId": str(uuid4()),
        "username": "alice",
        "displayName": "Alice",
        "gameTimezone": "Asia/Singapore",
    }
    account = client.post("/v1/accounts", json=provision, headers=header).json()
    profile = {"requestId": str(uuid4()), "displayName": "Updated"}
    original_profile = client.patch("/v1/me", json=profile, headers=header)
    assert original_profile.status_code == 200
    edit = {
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
    }
    assert client.post("/v1/me/garden/edits", json=edit, headers=header).status_code == 200
    instant = datetime(2026, 10, 30, 4, tzinfo=UTC)
    app.state.clock = lambda: instant
    enrol = {
        "requestId": str(uuid4()),
        "installationId": str(uuid4()),
        "observedAt": instant.isoformat(),
        "steps": 1000,
    }
    enrolled = client.post("/v1/activity/enrolments", json=enrol, headers=header)
    assert enrolled.status_code == 200
    sync = {
        "requestId": str(uuid4()),
        "installationId": enrol["installationId"],
        "deviceId": enrolled.json()["device"]["deviceId"],
        "observedAt": instant.isoformat(),
        "days": [{"gameDate": "2026-10-30", "steps": 2000}],
    }
    grown = client.post("/v1/activity/sync", json=sync, headers=header).json()
    ack = {"requestId": str(uuid4())}
    ack_path = f"/v1/reward-recaps/{grown['recapId']}/ack"
    acknowledged = client.post(ack_path, json=ack, headers=header)
    assert acknowledged.status_code == 200
    expire(app)
    assert client.post("/v1/accounts", json=provision, headers=header).json() == account
    assert client.patch("/v1/me", json=profile, headers=header).json() == original_profile.json()
    recovered = client.post("/v1/me/garden/edits", json=edit, headers=header).json()["recovery"]
    assert recovered["operation"] == "garden_edits"
    assert client.get("/v1/me/garden", headers=header).json()["layoutVersion"] == 1
    assert (
        client.post("/v1/activity/enrolments", json=enrol, headers=header).json() == enrolled.json()
    )
    assert client.post(ack_path, json=ack, headers=header).json() == acknowledged.json()


def control(
    client, header, installation, sequence, *, path="visitor-sessions", request_id=None, arrival=1
):
    body = {
        "requestId": str(request_id or uuid4()),
        "installationId": installation,
        "controlProtocol": 1,
        "expectedControlSequence": sequence,
        "arrivalProtocol": arrival,
    }
    return client.post("/v1/me/" + path, headers=header, json=body), body


def test_old_controls_cannot_restart_renew_or_end_current_session(app, client, forest):
    header = enabled(forest["headers"])
    first, start = control(client, header, forest["device"], 0)
    session_id = first.json()["session"]["sessionId"]
    assert first.json()["controlSequence"] == 1
    beat, _ = control(
        client, header, forest["device"], 1, path=f"visitor-sessions/{session_id}/heartbeat"
    )
    assert beat.json()["controlSequence"] == 2
    expire(app, days=2)
    owner = UUID(forest["account"]["profile"]["userId"])
    with app.state.database.sessions() as session:
        assert (
            session.scalar(
                select(func.count())
                .select_from(ApiRequest)
                .where(ApiRequest.operation.in_(recovery.CONTROLS))
            )
            == 0
        )
        lease = session.get(VisitorSession, UUID(session_id)).lease_expires_at
    retry = client.post("/v1/me/visitor-sessions", headers=header, json=start)
    assert retry.json()["recovery"]["status"] == "stale_control"
    obsolete, _ = control(
        client, header, forest["device"], 0, path=f"visitor-sessions/{session_id}/end"
    )
    assert obsolete.json()["recovery"]["status"] == "stale_control"
    with app.state.database.sessions() as session:
        assert session.get(VisitorSession, UUID(session_id)).lease_expires_at == lease
        assert session.get(VisitorSession, UUID(session_id)).ended_at is None
        assert session.get(VisitorControl, owner).sequence == 2


def test_latest_control_completion_conflicts_and_survives_restart(app, client, forest):
    header = enabled(forest["headers"])
    first, body = control(client, header, forest["device"], 0)
    assert first.status_code == 200
    expire(app, days=25 / 24)
    from fastapi.testclient import TestClient

    from forest_api.main import create_app

    restarted = create_app(app.state.settings)
    with TestClient(restarted) as other:
        retry = other.post("/v1/me/visitor-sessions", headers=header, json=body)
        assert retry.json()["recovery"]["status"] == "completed"
        body["installationId"] = str(uuid4())
        assert other.post("/v1/me/visitor-sessions", headers=header, json=body).status_code == 409


def test_control_race_and_cleanup_locking(app, client, forest):
    header = enabled(forest["headers"])

    def start(_):
        return control(client, header, str(uuid4()), 0)[0].json()

    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(start, range(2)))
    assert sum("session" in row for row in results) == 1
    assert sum(row.get("recovery", {}).get("status") == "stale_control" for row in results) == 1
    owner = UUID(forest["account"]["profile"]["userId"])
    with app.state.database.sessions.begin() as locked:
        locked.scalar(select(User).where(User.id == owner).with_for_update())
        assert expire(app)["examined"] == 0
    assert expire(app)["deletedControls"] == 1


def test_cleanup_failure_rolls_back_and_legacy_receipts_stay_full(app, client, forest):
    header = enabled(forest["headers"])
    client.post("/v1/me/stored-visits/claim", headers=header, json={"requestId": str(uuid4())})
    with app.state.database.sessions() as session:

        def fail(_):
            raise RuntimeError("injected cleanup interruption")

        event.listen(session, "before_commit", fail)
        with pytest.raises(RuntimeError):
            recovery.maintain(session, apply=True, now=datetime.now(UTC) + timedelta(days=8))
    with app.state.database.sessions() as session:
        assert all(row.response is not None for row in session.scalars(select(ApiRequest)))


def test_compact_collection_uses_original_immutable_receipts(app, economy):
    client, header = economy["client"], enabled(economy["headers"])
    body = {"requestId": str(uuid4()), "offerId": "woodland", "offerVersion": 1, "quantity": 1}
    bought = client.post("/v1/me/exchanges", json=body, headers=header)
    assert bought.status_code == 200, bought.text
    expire(app)
    assert client.post(bought.request.url.path, json=body, headers=header).json() == bought.json()
    path = f"/v1/me/packs/{bought.json()['packs'][0]['ownedPackId']}/open"
    body = {"requestId": str(uuid4())}
    opened = client.post(path, json=body, headers=header)
    assert opened.status_code == 200
    expire(app)
    assert client.post(path, json=body, headers=header).json() == opened.json()


def test_operation_baseline_and_bounded_control_cache(app, client, scene):
    app.state.metrics.enabled = True
    header = enabled(scene["headers"])
    first, _ = control(client, header, scene["installation"], 0, arrival=2)
    assert first.status_code == 200
    session_id = first.json()["session"]["sessionId"]
    scene["now"][0] += timedelta(seconds=5)
    visitor = first.json()["opportunities"][0]["opportunityId"]
    samples = {}
    for name, path, body in [
        (
            "heartbeat",
            f"visitor-sessions/{session_id}/heartbeat",
            {
                "requestId": str(uuid4()),
                "installationId": scene["installation"],
                "controlProtocol": 1,
                "expectedControlSequence": 1,
            },
        ),
        ("welcome", f"visitor-opportunities/{visitor}/welcome", {"requestId": str(uuid4())}),
        ("claim", "stored-visits/claim", {"requestId": str(uuid4())}),
    ]:
        with app.state.database.sessions() as session:
            before = storage_usage.report(session, exact=True)
        response = client.post("/v1/me/" + path, json=body, headers=header)
        assert response.status_code == 200, response.text
        samples[name] = dict(app.state.metrics.samples[-1])
        with app.state.database.sessions() as session:
            after = storage_usage.report(session, exact=True)
        previous = {row["name"]: row for row in before["tables"]}
        samples[name]["tableDeltas"] = {
            row["name"]: {
                "rows": row["exact_rows"] - previous[row["name"]]["exact_rows"],
                "allocatedBytes": row["total_bytes"] - previous[row["name"]]["total_bytes"],
            }
            for row in after["tables"]
            if row["exact_rows"] != previous[row["name"]]["exact_rows"]
            or row["total_bytes"] != previous[row["name"]]["total_bytes"]
        }
        assert samples[name]["queries"] > 0 and samples[name]["responseBytes"] > 0
    assert samples["heartbeat"]["rowsWritten"] > 0
    # Full activity handler, measured independently of HealthKit/network input.
    with app.state.database.sessions() as session:
        before = storage_usage.report(session, exact=True)
    result, _ = scene["submit"](steps=2000)
    assert result["activitySteps"] != "0"
    samples["activity_sync"] = dict(app.state.metrics.samples[-1])
    with app.state.database.sessions() as session:
        after = storage_usage.report(session, exact=True)
    previous = {row["name"]: row for row in before["tables"]}
    samples["activity_sync"]["tableDeltas"] = {
        row["name"]: {
            "rows": row["exact_rows"] - previous[row["name"]]["exact_rows"],
            "allocatedBytes": row["total_bytes"] - previous[row["name"]]["total_bytes"],
        }
        for row in after["tables"]
        if row["exact_rows"] != previous[row["name"]]["exact_rows"]
        or row["total_bytes"] != previous[row["name"]]["total_bytes"]
    }
    for name, maximum in {
        "heartbeat": 40,
        "welcome": 40,
        "claim": 35,
        "activity_sync": 100,
    }.items():
        assert samples[name]["queries"] <= maximum
    for row in samples.values():
        assert "Authorization" not in json.dumps(row) and scene["installation"] not in json.dumps(
            row
        )
        assert row["transactionMs"] > 0
    for sequence in range(2, 12):
        response, _ = control(
            client,
            header,
            scene["installation"],
            sequence,
            path=f"visitor-sessions/{session_id}/heartbeat",
        )
        assert response.status_code == 200
    counts = expire(app, days=2)
    assert counts["deletedControls"] == 12
    with app.state.database.sessions() as session:
        report = storage_usage.report(session, exact=True)
    if os.environ.get("FOREST_SCALING_REPORT"):
        Path(os.environ["FOREST_SCALING_REPORT"]).write_text(
            json.dumps({"operations": samples, "storage": report}, indent=2)
        )


def test_no_growth_sync_compaction_and_cleanup_retry_race(app, client, actors, headers):
    actor = actors()
    header = enabled(headers())
    body = body_for(actor, steps=2000)
    original = client.post("/v1/activity/sync", json=body, headers=header).json()
    assert original["recapId"] is None
    with ThreadPoolExecutor(max_workers=2) as workers:
        cleanup = workers.submit(expire, app)
        replay = workers.submit(client.post, "/v1/activity/sync", json=body, headers=header)
        assert replay.result().status_code == 200
        cleanup.result()
    recovered = client.post("/v1/activity/sync", json=body, headers=header).json()["recovery"]
    assert recovered["outcome"]["recapId"] is None
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 0


def test_database_requires_recovery_proof_and_bounds_completion(app, register):
    owner = UUID(register()["profile"]["userId"])
    for response, facts in [(None, None), ({}, {"outcome": "x" * 8192})]:
        with pytest.raises(IntegrityError):
            with app.state.database.sessions.begin() as session:
                session.add(
                    ApiRequest(
                        user_id=owner,
                        request_id=uuid4(),
                        operation="visitor_claim",
                        payload_hash="c" * 64,
                        response=response,
                        completion=facts,
                    )
                )
