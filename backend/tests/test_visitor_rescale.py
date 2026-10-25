"""Production conversion, scheduled timing, client gates and reward preservation."""

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from fractions import Fraction
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from test_activity_launch import player as player

from forest_api import services, visitor_rescale, visitor_schedule, visitors
from forest_api.calculations import MICRO, VisitorCurve, read_remainder, visitor_parameters
from forest_api.collection_models import PackDefinition
from forest_api.models import AttractionProfile, Garden, OwnedPlant, PlayerProgress, SkillPolicy
from forest_api.visitor_models import (
    VisitorContext,
    VisitorEconomyConversion,
    VisitorOpportunity,
    VisitorSchedule,
    VisitorState,
    VisitorStorageLot,
    VisitorWallet,
    VisitorWalletEntry,
)


def set_attraction(app, player, points):
    with app.state.database.sessions.begin() as session:
        key = "test_attraction_" + str(points)
        session.add(
            AttractionProfile(
                id=key,
                version=1,
                stage_attraction={
                    s: (points + index) * MICRO
                    for index, s in enumerate(["sprout", "seedling", "young", "adult"])
                },
                gameplay_tags=[],
            )
        )
        plant = session.get(OwnedPlant, UUID(player["plant"]))
        plant.attraction_profile_id, plant.attraction_profile_version = key, 1


@pytest.fixture
def scene(app, client, player, monkeypatch):
    monkeypatch.setattr(visitor_schedule, "jitter", lambda: Fraction(1))
    set_attraction(app, player, 50)
    player["now"][0] += timedelta(seconds=10)
    with app.state.database.sessions() as session:
        result = visitor_rescale.publish(
            session, app.state.settings, clock=lambda: player["now"][0]
        )

    def post(path, *, status=200, **fields):
        response = client.post(
            "/v1/me/" + path, headers=player["headers"], json={"requestId": str(uuid4()), **fields}
        )
        assert response.status_code == status, response.text
        return response.json()

    def read():
        response = client.get("/v1/me/visitors", headers=player["headers"])
        assert response.status_code == 200, response.text
        return response.json()

    def start():
        return post("visitor-sessions", installationId=player["installation"], arrivalProtocol=2)

    return {**player, "post": post, "read": read, "start": start, "publication": result}


@pytest.mark.parametrize(
    "points,active,offline",
    [
        (0, 120, 30),
        (2, 124, 31),
        (32, 184, 46),
        (50, 220, 55),
        (100, 320, 80),
        (200, 520, 130),
        (300, 720, 180),
    ],
)
def test_tenfold_curve_and_exact_relative_rates(points, active, offline):
    from forest_api.launch_balance import CURVE as OLD

    old = visitor_parameters(points * MICRO, 1, VisitorCurve.model_validate(OLD))
    new = visitor_parameters(points * MICRO, 1, VisitorCurve.model_validate(visitor_rescale.CURVE))
    assert new["active_rate"] * 3600 == active
    assert new["offline_rate"] * 3600 == offline
    assert new["active_rate"] == 10 * old["active_rate"]
    assert new["offline_rate"] == 10 * old["offline_rate"]
    assert (
        visitor_parameters(points * MICRO, 0, VisitorCurve.model_validate(visitor_rescale.CURVE))[
            "active_rate"
        ]
        == 0
    )


def test_publication_prices_milestones_caps_and_profile_preservation(scene, app, client):
    result = client.get("/v1/me/collection", headers=scene["headers"]).json()
    assert {o["offerId"]: o["tokenCost"] for o in result["offers"]} == {
        "woodland": "1200",
        "moonwillow": "2400",
    }
    assert [m["rewardTokens"] for m in result["milestones"]] == ["300", "300", "600", "300", "900"]
    summary = scene["read"]()
    assert summary["capacity"] == 1500 and summary["activeVisitsPerHour"] == "220.0"
    assert summary["offlineVisitsPerHour"] == "55.0" and summary["arrivalProtocol"] == 2
    with app.state.database.sessions() as session:
        assert (
            services.profile_refs(session.get(OwnedPlant, UUID(scene["plant"]))).behaviour.id
            == "launch_oak"
        )
        assert session.get(SkillPolicy, visitor_rescale.POLICY).rules["flatCapacity"] == 100
        assert (
            session.get(PackDefinition, ("woodland", 11)).definition
            == session.get(PackDefinition, ("woodland", 10)).definition
        )
    with app.state.database.sessions() as session:
        assert visitor_rescale.publish(session, app.state.settings)["alreadyPublished"]


def test_conversion_scales_wallet_exact_fraction_and_lots_once(player, app):
    player["now"][0] += timedelta(seconds=10)
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == player["owner"]))
        state, _ = visitors.settle(session, app.state.settings, garden, player["now"][0])
        state.stored_whole, state.remainder = 3, {"numerator": "1", "denominator": "7"}
        context = session.get(VisitorContext, state.context_id)
        old_rate = visitors.fraction_read(context.snapshot["offlineRate"])
        session.add(
            VisitorStorageLot(
                garden_id=garden.id, rule_version=context.rule_version, visits=3, tokens_per_visit=1
            )
        )
        wallet = session.get(VisitorWallet, player["owner"])
        wallet.tokens, wallet.hosted_active, wallet.hosted_offline = 205, 17, 231
    player["now"][0] += timedelta(microseconds=1)
    with app.state.database.sessions() as session:
        visitor_rescale.publish(session, app.state.settings, clock=lambda: player["now"][0])
    with app.state.database.sessions() as session:
        wallet = session.get(VisitorWallet, player["owner"])
        assert (wallet.tokens, wallet.hosted_active, wallet.hosted_offline) == (2050, 17, 231)
        state = session.get(VisitorState, garden.id)
        assert (
            Fraction(state.stored_whole) + read_remainder(state.remainder)
            == Fraction(220, 7) + old_rate / 100000
        )
        assert sum(lot.visits for lot in session.scalars(select(VisitorStorageLot))) == 31
        assert session.scalar(select(func.sum(VisitorWalletEntry.amount))) == 1845
        assert session.scalar(select(func.count()).select_from(VisitorEconomyConversion)) == 1
    with app.state.database.sessions() as session:
        visitor_rescale.publish(session, app.state.settings)
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, player["owner"]).tokens == 2050


def test_scheduled_start_advertises_future_and_rejects_early_claim(scene):
    started = scene["start"]()
    first = started["opportunities"][0]
    assert len(started["opportunities"]) == 2
    issued = datetime.fromisoformat(first["issuedAt"])
    assert issued == scene["now"][0] + timedelta(seconds=5)
    assert datetime.fromisoformat(first["expiresAt"]) - issued == timedelta(seconds=20)
    path = "visitor-opportunities/" + first["opportunityId"] + "/welcome"
    assert scene["post"](path, status=409)["error"]["code"] == "visitor_not_arrived"
    scene["now"][0] = issued
    result = scene["post"](path)
    assert result["tokens"] == result["visits"] == "1"
    assert scene["post"](path) == result


def test_old_client_is_explicitly_gated_and_new_session_is_idempotent(scene, client):
    assert (
        scene["post"]("visitor-sessions", status=409, installationId=scene["installation"])[
            "error"
        ]["code"]
        == "visitor_client_update_required"
    )
    body = {
        "requestId": str(uuid4()),
        "installationId": scene["installation"],
        "arrivalProtocol": 2,
    }
    a = client.post("/v1/me/visitor-sessions", headers=scene["headers"], json=body)
    assert a.status_code == 200, a.text
    assert (
        client.post("/v1/me/visitor-sessions", headers=scene["headers"], json=body).json()
        == a.json()
    )


def test_heartbeat_batches_multiple_without_repeating_or_extending_identity(scene):
    a = scene["start"]()
    original = {o["opportunityId"]: o for o in a["opportunities"]}
    scene["now"][0] += timedelta(seconds=10)
    b = scene["post"](
        "visitor-sessions/" + a["session"]["sessionId"] + "/heartbeat",
        installationId=scene["installation"],
    )
    assert len({o["opportunityId"] for o in b["opportunities"]}) == len(b["opportunities"])
    for row in b["opportunities"]:
        if row["opportunityId"] in original:
            assert row == original[row["opportunityId"]]


def test_end_resume_preserves_remaining_wait_and_cannot_farm_tutorial(scene):
    initial = scene["start"]()
    scene["now"][0] += timedelta(seconds=2)
    scene["post"](
        "visitor-sessions/" + initial["session"]["sessionId"] + "/end",
        installationId=scene["installation"],
    )
    scene["now"][0] += timedelta(hours=1)
    resumed = scene["start"]()
    first = datetime.fromisoformat(resumed["opportunities"][0]["issuedAt"])
    assert first == scene["now"][0] + timedelta(seconds=3)
    scene["post"](
        "visitor-opportunities/" + initial["opportunities"][0]["opportunityId"] + "/welcome",
        status=409,
    )


def test_no_retroactive_active_arrivals_after_lease_expiry(scene, app):
    initial = scene["start"]()
    scene["now"][0] += timedelta(days=100)
    resumed = scene["start"]()
    assert all(
        datetime.fromisoformat(o["issuedAt"]) > scene["now"][0] for o in resumed["opportunities"]
    )
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(VisitorOpportunity)) < 10
        assert session.get(VisitorWallet, scene["owner"]).hosted_active == 0
    assert initial["session"]["sessionId"] != resumed["session"]["sessionId"]


def test_offline_rate_and_storage_duration_are_scaled_consistently(scene):
    before = Fraction(scene["read"]()["storedVisitsMicroUnits"])
    scene["now"][0] += timedelta(hours=1)
    after = Fraction(scene["read"]()["storedVisitsMicroUnits"])
    assert after - before == 55 * MICRO
    scene["now"][0] += timedelta(days=365)
    full = scene["read"]()
    assert full["claimableVisits"] == "1500"
    claimed = scene["post"]("stored-visits/claim")
    assert claimed["visits"] == claimed["tokens"] == "1500"


def test_concurrent_welcomes_only_credit_one(scene):
    first = scene["start"]()["opportunities"][0]
    scene["now"][0] += timedelta(seconds=5)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(
                lambda _: scene["post"](
                    "visitor-opportunities/" + first["opportunityId"] + "/welcome"
                ),
                range(2),
            )
        )
    assert results[0] == results[1]
    assert scene["read"]()["tokenBalance"] == "1"


def test_conversion_audit_records_are_immutable(scene, app):
    with pytest.raises(IntegrityError, match="immutable"):
        with app.state.database.engine.begin() as connection:
            from sqlalchemy import text

            connection.execute(text("DELETE FROM visitor_economy_conversions"))


def test_growth_and_progress_are_unchanged_by_conversion(scene, app):
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, UUID(scene["plant"])).growth_micro_units == 0
        progress = session.get(PlayerProgress, scene["owner"])
        assert progress is None or progress.activity_steps == 0
        assert session.scalar(select(func.count()).select_from(VisitorSchedule)) == 0


def test_context_change_rescales_remaining_wait_without_duplicate_future_ids(scene, app):
    old = scene["start"]()
    old_future = old["opportunities"][1]["opportunityId"]
    scene["now"][0] += timedelta(seconds=10)
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == scene["owner"]))
        accounting = visitors.VisitorAccounting(app.state.settings)
        accounting.before_change(session, garden, scene["now"][0])
        plant = session.get(OwnedPlant, UUID(scene["plant"]))
        profile = AttractionProfile(
            id="rate_change",
            version=1,
            stage_attraction={
                "sprout": 100 * MICRO,
                "seedling": 101 * MICRO,
                "young": 102 * MICRO,
                "adult": 103 * MICRO,
            },
            gameplay_tags=[],
        )
        session.add(profile)
        session.flush()
        plant.attraction_profile_id, plant.attraction_profile_version = profile.id, 1
        session.flush()
        accounting.after_change(session, garden, scene["now"][0])
    result = scene["read"]()
    assert result["activeVisitsPerHour"] == "320.0"
    future = [
        o
        for o in result["opportunities"]
        if datetime.fromisoformat(o["issuedAt"]) > scene["now"][0]
    ]
    assert future and all(o["opportunityId"] != old_future for o in future)
    old_next = datetime.fromisoformat(old["opportunities"][1]["issuedAt"])
    expected = (old_next - scene["now"][0]).total_seconds() * 220 / 320
    assert (
        abs(
            (datetime.fromisoformat(future[0]["issuedAt"]) - scene["now"][0]).total_seconds()
            - expected
        )
        < 0.000002
    )
    # Replanning cancels future identities, so sequence modulo alone cannot
    # reserve lanes against due visitors. Repeated edits must keep them distinct.
    for _ in range(15):
        with app.state.database.sessions.begin() as session:
            garden = session.scalar(select(Garden).where(Garden.owner_id == scene["owner"]))
            visitors.VisitorAccounting(app.state.settings).after_change(
                session, garden, scene["now"][0]
            )
    rows = scene["read"]()["opportunities"]
    for index, row in enumerate(rows):
        for previous in rows[:index]:
            if row["lane"] == previous["lane"]:
                assert datetime.fromisoformat(previous["expiresAt"]) <= datetime.fromisoformat(
                    row["issuedAt"]
                )


def test_failed_publication_rolls_back_currency_and_rules(player, app, monkeypatch):
    from forest_api.models import GameCatalogue
    from forest_api.visitor_models import VisitorRules

    def fail(*args, **kwargs):
        raise RuntimeError("deliberate publication failure")

    player["now"][0] += timedelta(seconds=10)
    with monkeypatch.context() as patch:
        patch.setattr(visitor_rescale.collection, "publish_in_transaction", fail)
        with pytest.raises(RuntimeError, match="deliberate"):
            with app.state.database.sessions() as session:
                visitor_rescale.publish(session, app.state.settings, clock=lambda: player["now"][0])
    with app.state.database.sessions() as session:
        assert session.get(GameCatalogue, 1).version == "launch-balance-v1"
        assert session.get(VisitorRules, visitor_rescale.VERSION) is None
        assert session.scalar(select(func.count()).select_from(VisitorEconomyConversion)) == 0


def test_preconversion_milestone_receipt_replays_without_another_award(player, app, client):
    player["submit"](steps=2000)
    path = "/v1/me/milestones/first_movement/claim"
    body = {"requestId": str(uuid4())}
    receipt = client.post(path, headers=player["headers"], json=body)
    assert receipt.status_code == 200, receipt.text
    assert receipt.json()["tokensEarned"] == "30"
    player["now"][0] += timedelta(seconds=10)
    with app.state.database.sessions() as session:
        visitor_rescale.publish(session, app.state.settings, clock=lambda: player["now"][0])
    assert client.post(path, headers=player["headers"], json=body).json() == receipt.json()
    assert (
        client.post(path, headers=player["headers"], json={"requestId": str(uuid4())}).json()
        == receipt.json()
    )
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, player["owner"]).tokens == 300
    bought = client.post(
        "/v1/me/exchanges",
        headers=player["headers"],
        json={"requestId": str(uuid4()), "offerId": "woodland", "offerVersion": 10},
    )
    assert bought.status_code == 409 and bought.json()["error"]["code"] == "stale_offer"


def test_jitter_has_symmetric_bounds_and_exact_unit_mean(monkeypatch):
    monkeypatch.setattr(visitor_schedule.secrets, "randbelow", lambda _: 0)
    low = visitor_schedule.jitter()
    monkeypatch.setattr(visitor_schedule.secrets, "randbelow", lambda _: 1_000_000)
    high = visitor_schedule.jitter()
    assert low == Fraction(1, 2) and high == Fraction(3, 2) and (low + high) / 2 == 1


def test_maximum_rate_batch_is_bounded_and_lanes_do_not_overlap(scene, app, monkeypatch):
    monkeypatch.setattr(visitor_schedule, "jitter", lambda: Fraction(1, 2))
    set_attraction(app, scene, 1000000)
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == scene["owner"]))
        visitors.VisitorAccounting(app.state.settings).after_change(
            session, garden, scene["now"][0]
        )
    summary = scene["start"]()
    assert 10 < len(summary["opportunities"]) < 30
    for index, row in enumerate(summary["opportunities"]):
        start = datetime.fromisoformat(row["issuedAt"])
        end = datetime.fromisoformat(row["expiresAt"])
        assert end - start == timedelta(seconds=20)
        assert 1 <= row["lane"] <= 12
        for previous in summary["opportunities"][:index]:
            if previous["lane"] == row["lane"]:
                assert datetime.fromisoformat(previous["expiresAt"]) <= start


def test_capacity_skills_preserve_proportions_and_flat_value():
    from test_skills import effect, facts

    from forest_api.skill_rules import CAPS_V1, SkillCaps
    from forest_api.skills import SkillSnapshot

    source = facts(
        effects=[
            effect(
                system="visitors",
                scope="offline_capacity",
                target="garden",
                operation="flat",
                magnitude={"value": "5"},
            )
        ]
    )
    old = SkillSnapshot((source,), SkillCaps.model_validate(CAPS_V1), "old")
    new = SkillSnapshot(
        (source,), SkillCaps.model_validate({**CAPS_V1, "flatCapacity": 100}), "new"
    )
    assert old.capacity(150, 450) * 10 == new.capacity(1500, 4500, flat_multiplier=10) == 1550


def test_parallel_publications_convert_all_accounts_once(player, app, register):
    register("bob")
    player["now"][0] += timedelta(seconds=10)

    def publish():
        with app.state.database.sessions() as session:
            return visitor_rescale.publish(
                session, app.state.settings, clock=lambda: player["now"][0]
            )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: publish(), range(2)))
    assert sum(result.get("alreadyPublished", False) for result in results) == 1
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(VisitorEconomyConversion)) == 2


def test_claim_racing_conversion_has_same_purchasing_power(player, app, client):
    player["submit"](steps=2000)
    player["now"][0] += timedelta(seconds=10)

    def publish():
        with app.state.database.sessions() as session:
            visitor_rescale.publish(session, app.state.settings, clock=lambda: player["now"][0])

    def claim():
        result = client.post(
            "/v1/me/milestones/first_movement/claim",
            headers=player["headers"],
            json={"requestId": str(uuid4())},
        )
        assert result.status_code == 200, result.text

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(publish), pool.submit(claim)]
        for future in futures:
            future.result(timeout=20)
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, player["owner"]).tokens == 300


def test_conversion_overflow_rolls_back_instead_of_truncating(player, app):
    from forest_api.calculations import MAX_INTEGER
    from forest_api.errors import ApiError
    from forest_api.visitor_models import VisitorRules

    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, player["owner"]).tokens = MAX_INTEGER
    player["now"][0] += timedelta(seconds=10)
    with pytest.raises(ApiError):
        with app.state.database.sessions() as session:
            visitor_rescale.publish(session, app.state.settings, clock=lambda: player["now"][0])
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, player["owner"]).tokens == MAX_INTEGER
        assert session.get(VisitorRules, visitor_rescale.VERSION) is None


def test_baseline_schedule_preserves_expected_arrival_count_over_heartbeats(scene):
    active = scene["start"]()
    session_id = active["session"]["sessionId"]
    seen = set()
    for _ in range(60):
        scene["now"][0] += timedelta(seconds=10)
        active = scene["post"](
            "visitor-sessions/" + session_id + "/heartbeat", installationId=scene["installation"]
        )
        seen.update(
            o["opportunityId"]
            for o in active["opportunities"]
            if datetime.fromisoformat(o["issuedAt"]) <= scene["now"][0]
        )
    # 220/hour with mean jitter 1, plus the once-only 5-second tutorial arrival.
    assert len(seen) == 37


def test_maximum_jitter_pause_carries_without_rounding_past_wait_bound(scene, monkeypatch):
    monkeypatch.setattr(visitor_schedule, "jitter", lambda: Fraction(3, 2))
    active = scene["start"]()
    scene["now"][0] += timedelta(seconds=5)
    first = active["opportunities"][0]
    scene["post"]("visitor-opportunities/" + first["opportunityId"] + "/welcome")
    scene["post"](
        "visitor-sessions/" + active["session"]["sessionId"] + "/end",
        installationId=scene["installation"],
    )
    resumed = scene["start"]()
    delay = (
        datetime.fromisoformat(resumed["opportunities"][0]["issuedAt"]) - scene["now"][0]
    ).total_seconds()
    assert abs(delay - 1.5 * 3600 / 220) < 0.000002
