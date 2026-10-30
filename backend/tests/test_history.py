"""S4-S6 retention/reconciliation invariants on actual PostgreSQL."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from fractions import Fraction
from uuid import UUID, uuid4

import pytest
from sqlalchemy import event, func, select, text
from test_activity import actors as actors
from test_activity import body_for
from test_activity_launch import player as player
from test_visitor_rescale import scene as scene
from test_visitors import forest as forest
from test_visitors import later

from forest_api import growth_history, history
from forest_api.history_models import GrowthDaySummary, GrowthProvenance, VisitorDaySummary
from forest_api.models import (
    ActivityCredit,
    Garden,
    OwnedPlant,
    PlantGrowthCredit,
    RewardEvent,
    RewardRecap,
    User,
)
from forest_api.visitor_models import (
    VisitorContext,
    VisitorOpportunity,
    VisitorSettlement,
    VisitorState,
    VisitorWallet,
)


def cleanup(app, instant, **options):
    with app.state.database.sessions() as session:
        return history.maintain(
            session,
            now=instant,
            visitor_detail=True,
            growth_detail=True,
            apply=options.pop("apply", True),
            **options,
        )


def test_paid_visitor_survives_opportunity_removal_and_alias_replay(app, client, scene):
    header = {**scene["headers"], "X-Forest-Recovery": "1"}
    start = client.post(
        "/v1/me/visitor-sessions",
        headers=header,
        json={
            "requestId": str(uuid4()),
            "installationId": scene["installation"],
            "arrivalProtocol": 2,
        },
    ).json()
    opportunity = start["opportunities"][0]
    scene["now"][0] = datetime.fromisoformat(opportunity["issuedAt"])
    path = f"/v1/me/visitor-opportunities/{opportunity['opportunityId']}/welcome"
    body = {"requestId": str(uuid4())}
    original = client.post(path, json=body, headers=header).json()
    end = client.post(
        f"/v1/me/visitor-sessions/{start['session']['sessionId']}/end",
        headers=header,
        json={"requestId": str(uuid4()), "installationId": scene["installation"]},
    )
    assert end.status_code == 200
    instant = scene["now"][0] + timedelta(days=40)
    for _ in range(3):
        cleanup(app, instant, responses=True)
    with app.state.database.sessions() as session:
        assert session.get(VisitorOpportunity, UUID(opportunity["opportunityId"])) is None
        balance = session.get(VisitorWallet, scene["owner"]).tokens
        assert (
            session.scalar(
                select(func.sum(VisitorDaySummary.tokens)).where(
                    VisitorDaySummary.kind == "active_welcome"
                )
            )
            == 1
        )
    # Same UUID and a different UUID both recover the original reward facts.
    replay = client.post(path, json=body, headers=header).json()["recovery"]
    assert replay["outcome"]["eventId"] == original["eventId"]
    alias = {"requestId": str(uuid4())}
    recovered = client.post(path, json=alias, headers=header)
    assert recovered.status_code == 200, recovered.text
    assert recovered.json()["recovery"]["outcome"]["tokens"] == original["tokens"]
    assert (
        client.post(path, json=alias, headers=header).json()["recovery"]["requestId"]
        == alias["requestId"]
    )
    assert (
        client.post(
            f"/v1/me/visitor-opportunities/{uuid4()}/welcome", json=alias, headers=header
        ).status_code
        == 409
    )
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, scene["owner"]).tokens == balance
    assert (
        client.post(path, json={"requestId": str(uuid4())}, headers=scene["headers"]).status_code
        == 426
    )


def test_growth_summary_is_exact_repeat_safe_and_pending_recap_survives(
    app, client, actors, headers
):
    actor = actors()
    header = {**headers(), "X-Forest-Recovery": "1"}
    body = body_for(actor)
    result = client.post("/v1/activity/sync", headers=header, json=body).json()
    instant = actor["now"][0] + timedelta(days=40)
    with app.state.database.sessions() as session:
        credit = session.scalar(select(PlantGrowthCredit))
        assert credit.provenance_id
        assert "profiles" in growth_history.trace(session, credit)
        original = session.get(OwnedPlant, actor["plant"]).growth_micro_units
        recap_before = session.get(RewardRecap, UUID(result["recapId"])).payload
    cleanup(app, instant)
    cleanup(app, instant)
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PlantGrowthCredit)) == 0
        assert session.scalar(select(func.count()).select_from(GrowthProvenance)) == 0
        assert session.scalar(select(func.sum(GrowthDaySummary.awarded))) == original
        assert session.scalar(select(func.sum(GrowthDaySummary.credit_count))) == 1
        assert session.get(RewardRecap, UUID(result["recapId"])).payload == recap_before
        assert not session.scalar(select(RewardEvent)).payload.get("compacted")
    ack = client.post(
        f"/v1/reward-recaps/{result['recapId']}/ack",
        headers=header,
        json={"requestId": str(uuid4())},
    )
    assert ack.status_code == 200
    cleanup(app, instant)
    with app.state.database.sessions() as session:
        assert session.get(RewardRecap, UUID(result["recapId"])).payload["compacted"] == 1
        assert session.scalar(select(RewardEvent)).payload["compacted"] == 1
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == original
    # Old request still returns its exact retained response, and never recreates traces.
    assert client.post("/v1/activity/sync", headers=header, json=body).json() == result


def test_exact_retention_boundary_dry_run_and_failure_rollback(app, client, actors, headers):
    actor = actors()
    result = client.post("/v1/activity/sync", headers=headers(), json=body_for(actor)).json()
    expiry = actor["now"][0] + timedelta(days=30)
    assert cleanup(app, expiry - timedelta(microseconds=1))["growthCredits"] == 0
    assert cleanup(app, expiry, apply=False)["growthCredits"] == 1
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PlantGrowthCredit)) == 1
    with app.state.database.sessions() as session:
        interrupted = []

        def fail_after_write(current, context):
            if current.info.get("history_owner") and current.scalar(
                select(func.count()).select_from(GrowthDaySummary)
            ):
                interrupted.append(True)
                raise RuntimeError("interrupted after rollup write")

        event.listen(session, "after_flush_postexec", fail_after_write)
        with pytest.raises(RuntimeError):
            history.maintain(session, apply=True, growth_detail=True, now=expiry)
        assert interrupted
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PlantGrowthCredit)) == 1
        assert session.scalar(select(func.count()).select_from(GrowthDaySummary)) == 0
    assert cleanup(app, expiry)["growthCredits"] == 1
    assert result["recapId"]


def test_wallet_mismatch_blocks_removal(app, forest):
    forest["place"]()
    later(forest, 400)
    forest["read"]()
    with app.state.database.sessions.begin() as session:
        wallet = session.scalar(select(VisitorWallet))
        wallet.tokens += 1
    with pytest.raises(ValueError, match="wallet"):
        cleanup(app, forest["now"][0] + timedelta(days=40))
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(VisitorSettlement)) > 0
        assert session.scalar(select(func.count()).select_from(VisitorDaySummary)) == 0


def test_shared_provenance_deduplicates_duplicate_plants(app, client, actors, headers):
    actor = actors()
    # Owned duplicate with exact pinned identities, distinct per-copy fraction/growth.
    with app.state.database.sessions.begin() as session:
        from forest_api.models import GardenPlacement

        plant = session.get(OwnedPlant, actor["plant"])
        duplicate = OwnedPlant(
            id=uuid4(),
            owner_id=plant.owner_id,
            species_id=plant.species_id,
            variant_id=plant.variant_id,
            acquisition_source="test",
            acquisition_reference="history",
            growth_micro_units=0,
            fractional_state={},
        )
        for kind in ("growth", "behaviour", "attraction"):
            for suffix in ("id", "version"):
                field = f"{kind}_profile_{suffix}"
                setattr(duplicate, field, getattr(plant, field))
        session.add(duplicate)
        session.flush()
        garden = session.scalar(select(Garden))
        session.add(
            GardenPlacement(
                plant_id=duplicate.id,
                owner_id=plant.owner_id,
                garden_id=garden.id,
                x=5,
                y=2,
                rotation_degrees=0,
            )
        )
    result = client.post("/v1/activity/sync", headers=headers(), json=body_for(actor)).json()
    assert len(result["garden"]["plants"]) == 2
    with app.state.database.sessions() as session:
        rows = list(session.scalars(select(PlantGrowthCredit)))
        assert len(rows) == 2 and len({row.provenance_id for row in rows}) == 1
        assert rows[0].after_growth == rows[1].after_growth


def test_cleanup_skips_locked_account_and_preserves_activity_watermarks(
    app, client, actors, headers
):
    actor = actors()
    client.post("/v1/activity/sync", headers=headers(), json=body_for(actor))
    expiry = actor["now"][0] + timedelta(days=40)
    with app.state.database.sessions.begin() as session:
        session.scalar(select(User).where(User.id == actor["owner"]).with_for_update())
        assert cleanup(app, expiry)["growthCredits"] == 0
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: cleanup(app, expiry), range(2)))
    assert sum(item["growthCredits"] for item in results) == 1
    with app.state.database.sessions() as session:
        assert session.scalar(text("SELECT count(*) FROM activity_days")) == 1
        assert session.scalar(select(func.count()).select_from(ActivityCredit)) == 1


def test_utc_midnight_summary_preserves_exact_capacity_overflow(app, forest):
    forest["place"]()
    with app.state.database.sessions.begin() as session:
        state = session.scalar(select(VisitorState))
        context = session.get(VisitorContext, state.context_id)
        start = datetime(2026, 1, 1, 23, 59, 59, tzinfo=UTC)
        row = VisitorSettlement(
            id=uuid4(),
            garden_id=state.garden_id,
            context_id=context.id,
            start_at=start,
            end_at=start + timedelta(seconds=2),
            mode="inactive",
            detail={
                "before": history.saved(Fraction(0)),
                "after": history.saved(Fraction(1)),
                "generated": history.saved(Fraction(2)),
                "discarded": history.saved(Fraction(1)),
            },
        )
        session.add(row)
        session.flush()
        row_id = row.id
    with app.state.database.sessions.begin() as session:
        # Reload through PostgreSQL to include the connection's session timezone.
        session.execute(text("SET LOCAL TIME ZONE 'Asia/Singapore'"))
        row = session.get(VisitorSettlement, row_id)
        context = session.get(VisitorContext, row.context_id)
        history.roll_settlement(session, row, context)
    with app.state.database.sessions() as session:
        rows = list(session.scalars(select(VisitorDaySummary).order_by(VisitorDaySummary.day)))
        assert [history.rational(row.discarded) for row in rows] == [0, 1]
        assert sum(row.microseconds for row in rows) == 2_000_000


def test_unchanged_move_reuses_context_and_does_not_cancel_schedule(app, client, scene):
    started = scene["start"]()
    garden = client.get("/v1/me/garden", headers=scene["headers"]).json()
    moved = client.post(
        "/v1/me/garden/edits",
        headers=scene["headers"],
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": garden["layoutVersion"],
            "catalogVersion": garden["catalogVersion"],
            "actions": [
                {"action": "move", "plantId": scene["plant"], "x": 3, "y": 2, "rotationDegrees": 0}
            ],
        },
    )
    assert moved.status_code == 200, moved.text
    current = scene["read"]()
    assert current["contextId"] == started["contextId"]
    assert [row["opportunityId"] for row in current["opportunities"]] == [
        row["opportunityId"] for row in started["opportunities"]
    ]


@pytest.mark.parametrize("timezone", ["Asia/Singapore", "America/New_York", "Pacific/Auckland"])
def test_activity_cutoff_covers_dst_old_observations_and_six_prior_dates(timezone):
    from zoneinfo import ZoneInfo

    instant = datetime(2026, 11, 15, 0, 1, tzinfo=UTC)
    observation = instant - timedelta(days=30)
    oldest_valid = observation.astimezone(ZoneInfo(timezone)).date() - timedelta(days=6)
    assert history.earliest_mutable_activity_date(instant, timezone) <= oldest_valid


def test_reward_core_and_completed_metadata_stay_immutable(app, client, scene):
    from sqlalchemy.exc import IntegrityError

    started = scene["start"]()
    scene["now"][0] = datetime.fromisoformat(started["opportunities"][0]["issuedAt"])
    target = started["opportunities"][0]["opportunityId"]
    scene["post"](f"visitor-opportunities/{target}/welcome")
    for expression in (
        "detail = '{}'::jsonb",
        "receipt = '{}'::jsonb",
        "owner_id = gen_random_uuid()",
    ):
        with pytest.raises(IntegrityError):
            with app.state.database.engine.begin() as connection:
                connection.execute(text(f"UPDATE visitor_reward_events SET {expression}"))


def test_downgrade_refuses_to_strand_new_compact_welcome(app, client, scene):
    from alembic import command
    from conftest import migration_config, migration_url

    started = scene["start"]()
    scene["now"][0] = datetime.fromisoformat(started["opportunities"][0]["issuedAt"])
    target = started["opportunities"][0]["opportunityId"]
    header = {**scene["headers"], "X-Forest-Recovery": "1"}
    path = f"/v1/me/visitor-opportunities/{target}/welcome"
    result = client.post(path, headers=header, json={"requestId": str(uuid4())})
    assert result.status_code == 200
    with migration_url(app.state.settings.database_url.get_secret_value()):
        with pytest.raises(RuntimeError, match="Compact visitor receipts"):
            command.downgrade(migration_config(), "0010_compact_recovery")
    alias = client.post(path, headers=header, json={"requestId": str(uuid4())})
    assert alias.json()["recovery"]["outcome"]["eventId"] == result.json()["eventId"]


def test_shared_worker_reports_reconciliation_failure_without_account_details(app, monkeypatch):
    from forest_api import history_worker

    def mismatch(*args, **kwargs):
        raise ValueError("Unreconciled wallet; history retained")

    monkeypatch.setattr(history_worker, "maintain", mismatch)
    result = history_worker.tick(app.state.database, app.state.settings)
    assert result["status"] == "reconciliation_failed"
    assert result["reason"] == "Unreconciled wallet; history retained"
    assert "owner" not in result and "payload" not in result


def test_orphan_provenance_is_collected_without_any_old_account_work(app):
    key = "a" * 64
    with app.state.database.sessions.begin() as session:
        session.add(GrowthProvenance(id=key, payload={"diagnostic": True}))
    with app.state.database.sessions.begin() as held:
        held.scalar(
            select(GrowthProvenance)
            .where(GrowthProvenance.id == key)
            .with_for_update(read=True, key_share=True)
        )
        with app.state.database.sessions() as session:
            assert history.maintain(session, apply=True, growth_detail=True)["provenance"] == 0
    with app.state.database.sessions() as session:
        assert history.maintain(session, apply=True, growth_detail=True)["provenance"] == 1
    with app.state.database.sessions() as session:
        assert session.get(GrowthProvenance, key) is None
