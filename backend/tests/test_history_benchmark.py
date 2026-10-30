"""Opt-in retained-state workload matrix; never connects to the game database.

FOREST_HISTORY_BENCHMARK=1 selects measured 35/90/365-day cohorts. The 1,000-MAU
projection uses a stated 12.5% DAU/MAU ratio; it is not a 1,000-client load test.
"""

import json
import math
import os
import statistics
import subprocess
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.engine import make_url
from test_activity import actors as actors
from test_activity import body_for

from forest_api import growth_history, history, services, storage_usage, visitors
from forest_api.history_models import GrowthDaySummary
from forest_api.models import (
    ActivityCredit,
    ApiRequest,
    Base,
    Garden,
    GardenPlacement,
    OwnedPlant,
    PlantGrowthCredit,
)
from forest_api.visitor_models import (
    VisitorContext,
    VisitorOpportunity,
    VisitorRewardEvent,
    VisitorSession,
    VisitorSettlement,
    VisitorState,
    VisitorWallet,
    VisitorWalletEntry,
)

pytestmark = pytest.mark.skipif(
    os.environ.get("FOREST_HISTORY_BENCHMARK") != "1", reason="opt-in physical storage benchmark"
)


def footprint(app):
    with app.state.database.sessions() as session:
        value = storage_usage.report(session, exact=True)
    with app.state.database.engine.connect() as connection:
        value["walLsn"] = str(connection.scalar(text("SELECT pg_current_wal_lsn()")))
        value["deadTuples"] = int(
            connection.scalar(text("SELECT coalesce(sum(n_dead_tup),0) FROM pg_stat_user_tables"))
        )
        value["logicalRowBytes"] = sum(
            int(
                connection.scalar(
                    text(f'SELECT coalesce(sum(pg_column_size(t)),0) FROM "{name}" t')
                )
            )
            for name in Base.metadata.tables
        )
    return value


def probe(app, client, header):
    app.state.metrics.enabled = True
    app.state.metrics.samples.clear()
    for _ in range(12):
        assert client.get("/v1/me/visitors", headers=header).status_code == 200
    samples = list(app.state.metrics.samples)
    timings = [x["requestMs"] for x in samples]
    return {
        "p50": statistics.median(timings),
        "p95": sorted(timings)[math.ceil(len(timings) * 0.95) - 1],
        "queries": sorted({x["queries"] for x in samples}),
        "responseBytes": sorted({x["responseBytes"] for x in samples}),
    }


@pytest.mark.parametrize("days,minutes,plants", [(35, 5, 10), (90, 15, 15), (365, 60, 15)])
def test_retained_state_matrix(
    app, client, actors, headers, database_factory, tmp_path, days, minutes, plants
):
    actor = actors()
    start = actor["now"][0]
    owner = actor["owner"]
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden))
        original = session.get(OwnedPlant, actor["plant"])
        maximum = (
            services.PlantPresenter(session)
            .profile("growth", original.growth_profile_id, original.growth_profile_version)
            .maximum_growth_micro_units
        )
        original.growth_micro_units = maximum
        for index in range(1, plants):
            plant = OwnedPlant(
                id=uuid4(),
                owner_id=owner,
                species_id=original.species_id,
                variant_id=original.variant_id,
                acquisition_source="benchmark",
                acquisition_reference=str(index),
                growth_micro_units=maximum,
                fractional_state={},
            )
            for kind in services.PROFILE_MODELS:
                for suffix in ("id", "version"):
                    field = f"{kind}_profile_{suffix}"
                    setattr(plant, field, getattr(original, field))
            session.add(plant)
            session.flush()
            session.add(
                GardenPlacement(
                    plant_id=plant.id,
                    owner_id=owner,
                    garden_id=garden.id,
                    x=1 + index % 4 * 2,
                    y=1 + index // 4 * 2,
                    rotation_degrees=0,
                )
            )
        session.flush()
        visitors.VisitorAccounting(app.state.settings).after_change(session, garden, start)
    # Real calculator/DTO provides full multi-recipient diagnostic shapes.
    response = client.post(
        "/v1/activity/sync",
        headers={**headers(), "X-Forest-Recovery": "1"},
        json=body_for(actor, steps=3000),
    )
    assert response.status_code == 200
    with app.state.database.sessions() as session:
        template_credit = session.scalar(select(ActivityCredit))
        traces = [
            (row.plant_id, growth_history.trace(session, row))
            for row in session.scalars(select(PlantGrowthCredit))
        ]
        state = session.scalar(select(VisitorState))
        context = session.get(VisitorContext, state.context_id)
        garden_id, context_id, rule = state.garden_id, state.context_id, context.rule_version
        profile_rule = template_credit.rule_version
    visitor_response = client.get("/v1/me/visitors", headers=headers()).json()
    # A rotating 12% daily cohort gives each monthly player roughly 3.6 sessions.
    active_days = list(range(0, days, 8))
    (
        credit_rows,
        growth_rows,
        request_rows,
        settlements,
        sessions,
        opportunities,
        rewards,
        ledger,
    ) = [], [], [], [], [], [], [], []
    count = 0
    for offset in active_days:
        instant = start + timedelta(days=offset)
        session_id = uuid4()
        sessions.append(
            dict(
                id=session_id,
                owner_id=owner,
                garden_id=garden_id,
                installation_id=uuid4(),
                started_at=instant,
                lease_expires_at=instant + timedelta(minutes=minutes),
                ended_at=instant + timedelta(minutes=minutes),
                arrival_protocol=1,
            )
        )
        # Stable legacy opportunities, half captured; high v2 traffic is projected separately.
        for tick in range(minutes * 6):
            at = instant + timedelta(seconds=tick * 10)
            settlements.append(
                dict(
                    id=uuid4(),
                    garden_id=garden_id,
                    context_id=context_id,
                    start_at=at,
                    end_at=at + timedelta(seconds=10),
                    mode="active",
                    detail={"scheduledArrivals": True},
                )
            )
            key = uuid4()
            request_rows.append(
                dict(
                    user_id=owner,
                    request_id=key,
                    operation="visitor_heartbeat",
                    payload_hash="b" * 64,
                    response={
                        **visitor_response,
                        "serverTime": at.isoformat(),
                        "session": {
                            "sessionId": str(session_id),
                            "installationId": actor["installation"],
                            "leaseExpiresAt": (at + timedelta(seconds=45)).isoformat(),
                        },
                    },
                    completion={"version": 1, "outcome": {}, "sequencedControl": True},
                    recovery_version=1,
                    created_at=at,
                    response_expires_at=at + timedelta(hours=24),
                )
            )
        for tick in range(minutes):
            at = instant + timedelta(minutes=tick)
            target, event_id, request_id = uuid4(), uuid4(), uuid4()
            count += 1
            receipt = {
                "requestId": str(request_id),
                "eventId": str(event_id),
                "tokens": "1",
                "visits": "1",
                "acceptedAt": at.isoformat(),
                "recoverable": True,
            }
            opportunities.append(
                dict(
                    id=target,
                    garden_id=garden_id,
                    session_id=session_id,
                    context_id=context_id,
                    slot=int(at.timestamp()) // 30,
                    issued_at=at,
                    expires_at=at + timedelta(seconds=20),
                    rule_version=rule,
                    tokens=1,
                    status="welcomed",
                    result={k: v for k, v in receipt.items() if k != "recoverable"},
                )
            )
            rewards.append(
                dict(
                    id=event_id,
                    owner_id=owner,
                    kind="active_welcome",
                    source_id=target,
                    created_at=at,
                    detail={
                        "visits": "1",
                        "tokens": "1",
                        "lots": [{"ruleVersion": rule, "visits": 1, "tokens": 1}],
                        "remainingFraction": {},
                    },
                    receipt=receipt,
                    summarized_at=None,
                )
            )
            ledger.append(
                dict(id=uuid4(), owner_id=owner, event_id=event_id, amount=1, created_at=at)
            )
        for sync in range(4):
            at = instant + timedelta(hours=sync)
            key, credit_id = uuid4(), uuid4()
            credit_rows.append(
                dict(
                    id=credit_id,
                    owner_id=owner,
                    game_date=at.date(),
                    device_id=actor["device"],
                    request_id=key,
                    rule_version=profile_rule,
                    start_steps=sync * 1000,
                    end_steps=(sync + 1) * 1000,
                    water_steps=1000,
                    accepted_at=at,
                    metric_quantities={
                        "walking_running_distance_metres": "1000",
                        "active_energy_kcal": "100",
                        "flights_climbed": "5",
                        "workout_minutes.running": "20",
                    },
                )
            )
            for plant, trace in traces:
                growth_rows.append(
                    dict(
                        plant_id=plant,
                        activity_credit_id=credit_id,
                        before_growth=maximum,
                        after_growth=maximum,
                        context={
                            **trace,
                            "awardedMicroUnits": "0",
                            "skillBonusGrowthMicroUnits": "0",
                        },
                        provenance_id=None,
                    )
                )
            request_rows.append(
                dict(
                    user_id=owner,
                    request_id=key,
                    operation="activity_sync",
                    payload_hash="c" * 64,
                    response={
                        **response.json(),
                        "requestId": str(key),
                        "acceptedAt": at.isoformat(),
                    },
                    completion={
                        "version": 1,
                        "outcome": {"requestId": str(key), "gardenId": str(garden_id)},
                    },
                    recovery_version=1,
                    created_at=at,
                    response_expires_at=at + timedelta(days=30),
                )
            )
    with app.state.database.sessions.begin() as session:
        from forest_api.models import ActivityDay
        from forest_api.visitor_models import VisitorControl

        for offset in active_days:
            day = (start + timedelta(days=offset)).date()
            if session.get(ActivityDay, (owner, day)) is None:
                session.add(
                    ActivityDay(
                        owner_id=owner,
                        game_date=day,
                        game_timezone="Asia/Singapore",
                        bucket_start=datetime.combine(day, datetime.min.time(), tzinfo=UTC),
                        bucket_end=datetime.combine(
                            day + timedelta(days=1), datetime.min.time(), tzinfo=UTC
                        ),
                        device_id=actor["device"],
                        rule_version=profile_rule,
                        baseline_steps=0,
                        baseline_credit_steps=0,
                        observed_steps=4000,
                        observed_at=start + timedelta(days=offset),
                        is_available=True,
                        credited_steps=4000,
                    )
                )
        session.flush()
        for model, rows in [
            (VisitorSession, sessions),
            (ActivityCredit, credit_rows),
            (PlantGrowthCredit, growth_rows),
            (ApiRequest, request_rows),
            (VisitorSettlement, settlements),
            (VisitorOpportunity, opportunities),
            (VisitorRewardEvent, rewards),
            (VisitorWalletEntry, ledger),
        ]:
            for left in range(0, len(rows), 500):
                session.execute(model.__table__.insert(), rows[left : left + 500])
        state = session.get(VisitorState, garden_id)
        state.settled_at = start + timedelta(days=days)
        state.last_slot = int(state.settled_at.timestamp()) // 30
        state.ever_issued = True
        wallet = session.get(VisitorWallet, owner)
        wallet.tokens, wallet.hosted_active = count, count
        session.add(VisitorControl(owner_id=owner, sequence=len(request_rows)))
    now = start + timedelta(days=days)
    app.state.clock = lambda: now
    # Real exchanges/openings grow storage while retaining immutable receipts.
    from forest_api.collection_seed import seed_legacy_collection

    with app.state.database.sessions() as session:
        seed_legacy_collection(session, app.state.settings)
    quantity = min(20, len(active_days))
    header = {**headers(), "X-Forest-Recovery": "1"}
    purchased = client.post(
        "/v1/me/exchanges",
        headers=header,
        json={
            "requestId": str(uuid4()),
            "offerId": "woodland",
            "offerVersion": 1,
            "quantity": quantity,
        },
    )
    assert purchased.status_code == 200, purchased.text
    for pack in purchased.json()["packs"][: quantity // 2]:
        opened = client.post(
            f"/v1/me/packs/{pack['ownedPackId']}/open",
            headers=header,
            json={"requestId": str(uuid4())},
        )
        assert opened.status_code == 200, opened.text
    expected_balance = count - int(purchased.json()["tokensSpent"])
    before_latency = probe(app, client, headers())
    before = footprint(app)
    started = time.monotonic()
    batches = 0
    for _ in range(300):
        with app.state.database.sessions() as session:
            result = history.maintain(
                session,
                apply=True,
                responses=True,
                visitor_detail=True,
                growth_detail=True,
                now=now,
                limit=5000,
            )
        batches += 1
        work = sum(
            v
            for k, v in result.items()
            if type(v) is int and k not in {"skipped", "legacyProtected"}
        ) + sum(result["responses"][k] for k in ("compacted", "deletedControls", "backfilled"))
        if work == 0:
            break
    else:
        pytest.fail("Maintenance did not converge")
    after = footprint(app)
    maintenance_seconds = time.monotonic() - started
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, owner).tokens == expected_balance
        assert session.scalar(select(func.sum(GrowthDaySummary.awarded))) in (None, 0)
        history.reconcile(session, owner, garden_id)
    # Request latency/query samples on identical confirmed state, not a client load test.
    after_latency = probe(app, client, headers())
    # A real custom-format backup/restore also measures fresh physical allocation.
    # Normal vacuum reuses pages; it does not promise an immediate file shrink.
    from forest_api.database import Database

    tools = Path(__file__).resolve().parents[1] / ".local-postgres/pgsql/bin"
    dump = tools / "pg_dump.exe"
    restore = tools / "pg_restore.exe"
    if not dump.exists():
        import shutil

        dump, restore = (
            Path(shutil.which("pg_dump") or "pg_dump"),
            Path(shutil.which("pg_restore") or "pg_restore"),
        )
    source = make_url(app.state.settings.database_url.get_secret_value())
    environment = {**os.environ, "PGPASSWORD": source.password or ""}
    connection_args = ["-h", source.host, "-p", str(source.port or 5432), "-U", source.username]
    archive = tmp_path / "history.dump"
    subprocess.run(
        [str(dump), *connection_args, "-d", source.database, "-Fc", "-f", str(archive)],
        env=environment,
        check=True,
        capture_output=True,
    )
    with database_factory() as restored_url:
        target = make_url(restored_url)
        subprocess.run(
            [
                str(restore),
                *connection_args,
                "-d",
                target.database,
                "--no-owner",
                "--no-privileges",
                "--exit-on-error",
                str(archive),
            ],
            env=environment,
            check=True,
            capture_output=True,
        )
        restored = Database(
            app.state.settings.model_copy(
                update={"database_url": type(app.state.settings.database_url)(restored_url)}
            )
        )
        try:
            from types import SimpleNamespace

            restored_app = SimpleNamespace(state=SimpleNamespace(database=restored))
            restored_size = footprint(restored_app)
            assert {x["name"]: x["exact_rows"] for x in after["tables"]} == {
                x["name"]: x["exact_rows"] for x in restored_size["tables"]
            }
            with restored.sessions() as session:
                history.reconcile(session, owner, garden_id)
                assert session.get(VisitorWallet, owner).tokens == expected_balance
            assert restored_size["logicalRowBytes"] == after["logicalRowBytes"]
            for name in (
                "owned_plants",
                "garden_placements",
                "visitor_wallets",
                "garden_visitor_state",
                "visitor_storage_lots",
                "pack_openings",
                "collection_events",
            ):
                statement = text(
                    "SELECT md5(coalesce(string_agg(to_jsonb(t)::text, '' "
                    f"ORDER BY to_jsonb(t)::text), '')) FROM {name} t"
                )
                with (
                    app.state.database.engine.connect() as original_connection,
                    restored.engine.connect() as restored_connection,
                ):
                    assert original_connection.scalar(statement) == restored_connection.scalar(
                        statement
                    )
        finally:
            restored.engine.dispose()
    result = {
        "days": days,
        "gardenMinutes": minutes,
        "plants": plants,
        "activeDays": len(active_days),
        "model": {
            "MAU": 1000,
            "DAU": 125,
            "additionalDormantAccounts": 500,
            "dailySyncs": 4,
            "capturePolicy": "One welcome/minute; high-v2 volume projected separately.",
            "growthInputs": "Four quantities plus workout fixtures; ingestion tested separately.",
        },
        "before": before,
        "after": after,
        "restored": restored_size,
        "backupRestoreVerified": True,
        "maintenanceSeconds": maintenance_seconds,
        "batches": batches,
        "readLatencyMs": after_latency,
        "readLatencyBeforeMs": before_latency,
        "packsPurchased": quantity,
        "packsOpened": quantity // 2,
        "physicalTableBytesBefore": sum(x["total_bytes"] for x in before["tables"]),
        "physicalTableBytesAfter": sum(x["total_bytes"] for x in after["tables"]),
        "restoredPhysicalBytes": sum(x["total_bytes"] for x in restored_size["tables"]),
        "logicalRowBytesSaved": before["logicalRowBytes"] - after["logicalRowBytes"],
    }
    with app.state.database.engine.connect() as connection:
        result["walBytesDuringMaintenance"] = int(
            connection.scalar(
                text("SELECT pg_wal_lsn_diff(:after, :before)"),
                {"after": after["walLsn"], "before": before["walLsn"]},
            )
        )
    assert result["logicalRowBytesSaved"] > 0
    assert result["restoredPhysicalBytes"] < result["physicalTableBytesBefore"]
    directory = Path(os.environ.get("FOREST_HISTORY_REPORT_DIR", "backend/benchmarks"))
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"history-{days}d.json").write_text(json.dumps(result, indent=2))
