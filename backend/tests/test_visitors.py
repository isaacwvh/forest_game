"""B6 accounting, API ownership, replay and real PostgreSQL races."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError

from forest_api import visitors
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.main import create_app
from forest_api.models import OwnedPlant
from forest_api.visitor_models import (
    VisitorContext,
    VisitorRewardEvent,
    VisitorRules,
    VisitorSettlement,
    VisitorState,
    VisitorStorageLot,
    VisitorWallet,
    VisitorWalletEntry,
)
from forest_api.visitor_schemas import VisitorRequest

NOW = datetime(2026, 10, 23, 4, tzinfo=UTC)


@pytest.fixture
def forest(app, client, headers, register):
    current = [NOW]
    app.state.clock = lambda: current[0]
    account = register()
    header = headers()
    device = str(uuid4())

    def post(path, body=None, status=200):
        response = client.post(
            "/v1/me/" + path, headers=header, json={"requestId": str(uuid4()), **(body or {})}
        )
        assert response.status_code == status, response.text
        return response.json()

    def read():
        response = client.get("/v1/me/visitors", headers=header)
        assert response.status_code == 200, response.text
        return response.json()

    def place():
        response = client.post(
            "/v1/me/garden/edits",
            headers=header,
            json={
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
            },
        )
        assert response.status_code == 200, response.text

    return {
        "now": current,
        "account": account,
        "post": post,
        "read": read,
        "place": place,
        "device": device,
        "headers": header,
    }


def later(forest, seconds):
    forest["now"][0] += timedelta(seconds=float(seconds))


def heartbeat(forest, session):
    return forest["post"](
        "visitor-sessions/" + session + "/heartbeat", {"installationId": forest["device"]}
    )


def opportunity(forest):
    forest["place"]()
    summary = forest["post"]("visitor-sessions", {"installationId": forest["device"]})
    session = summary["session"]["sessionId"]
    for _ in range(9):
        later(forest, 10)
        summary = heartbeat(forest, session)
        if summary["opportunities"]:
            return summary["opportunities"][0], session
    pytest.fail("Durable gap protection must issue within three eligible slots")


def add_rules(app, when, name="next", *, reward=1, capacity=30):
    with app.state.database.sessions() as session, session.begin():
        rule = session.get(VisitorRules, "development-visitors-v1")
        data = {
            **rule.rules,
            "tokens_per_visit": reward,
            "curve": {**rule.rules["curve"], "base_capacity": capacity},
        }
        session.add(VisitorRules(version=name, effective_at=when, is_fixture=True, rules=data))


def test_activation_preserves_existing_growth_and_no_history(app, forest):
    forest["place"]()
    with app.state.database.sessions() as session, session.begin():
        plant = session.get(OwnedPlant, UUID(forest["account"]["starterPlantId"]))
        plant.growth_micro_units = 100
    summary = forest["read"]()
    assert summary["storedVisitsMicroUnits"] == "0"
    assert summary["tokenBalance"] == "0"
    with app.state.database.sessions() as session:
        assert (
            session.get(OwnedPlant, UUID(forest["account"]["starterPlantId"])).growth_micro_units
            == 100
        )


def test_empty_garden_produces_nothing(forest):
    forest["read"]()
    later(forest, 86400 * 365)
    assert forest["read"]()["storedVisitsMicroUnits"] == "0"


@pytest.mark.parametrize("splits", [1, 3, 7, 23])
def test_storage_fraction_is_reconciliation_invariant(forest, splits):
    forest["place"]()
    for index in range(splits):
        later(forest, 239 // splits + (1 if index < 239 % splits else 0))
        summary = forest["read"]()
    assert summary["storedVisitsMicroUnits"] == "995833"


def test_claim_whole_visits_retains_fraction_and_receipt(forest):
    forest["place"]()
    later(forest, 600)
    request = {"requestId": str(uuid4())}
    result = forest["post"]("stored-visits/claim", request)
    assert result["visits"] == "2" and result["tokens"] == "2"
    assert result["summary"]["storedVisitsMicroUnits"] == "500000"
    later(forest, 240)
    assert forest["post"]("stored-visits/claim", request) == result
    assert forest["read"]()["claimableVisits"] == "1"


def test_cap_discards_overflow_without_hidden_backlog(forest):
    forest["place"]()
    later(forest, 86400 * 3650)
    assert forest["read"]()["claimableVisits"] == "30"
    assert forest["post"]("stored-visits/claim")["visits"] == "30"
    assert forest["read"]()["storedVisitsMicroUnits"] == "0"
    later(forest, 120)
    assert forest["read"]()["storedVisitsMicroUnits"] == "500000"


def test_config_boundary_reward_lots_and_shared_fraction(app, forest):
    forest["place"]()
    add_rules(app, NOW + timedelta(seconds=360), reward=7)
    later(forest, 600)
    result = forest["post"]("stored-visits/claim")
    # First whole completes at 240 under old rule; next completes at 480 under new.
    assert result["visits"] == "2" and result["tokens"] == "8"
    assert result["summary"]["storedVisitsMicroUnits"] == "500000"
    with app.state.database.sessions() as session:
        event = session.get(VisitorRewardEvent, UUID(result["eventId"]))
        assert len(event.detail["lots"]) == 2


def test_lower_capacity_preserves_earned_storage(app, forest):
    forest["place"]()
    add_rules(app, NOW + timedelta(seconds=1200), capacity=2)
    later(forest, 2400)
    summary = forest["read"]()
    assert summary["claimableVisits"] == "5" and summary["capacity"] == 2
    assert forest["post"]("stored-visits/claim")["visits"] == "5"
    later(forest, 120)
    assert forest["read"]()["storedVisitsMicroUnits"] == "500000"


def test_session_excludes_offline_and_expiry_is_durable(forest):
    forest["place"]()
    forest["post"]("visitor-sessions", {"installationId": forest["device"]})
    later(forest, 285)
    # 45 active seconds, then 240 inactive seconds.
    summary = forest["read"]()
    assert summary["session"] is None
    assert summary["claimableVisits"] == "1"
    assert summary["opportunities"] == []


def test_welcome_replay_after_expiry_and_new_uuid(app, forest):
    visitor, session = opportunity(forest)
    path = "visitor-opportunities/" + visitor["opportunityId"] + "/welcome"
    request = {"requestId": str(uuid4())}
    result = forest["post"](path, request)
    assert result["tokens"] == "1" and result["summary"]["hostedActive"] == "1"
    later(forest, 1000)
    assert forest["post"](path, request) == result
    assert forest["post"](path) == result
    assert forest["read"]()["tokenBalance"] == "1"
    with app.state.database.sessions() as db:
        assert db.scalar(select(func.count()).select_from(VisitorWalletEntry)) == 1


def test_expired_and_foreign_welcome_rejected(forest, register, client, headers):
    visitor, session = opportunity(forest)
    register("other")
    path = "/v1/me/visitor-opportunities/" + visitor["opportunityId"] + "/welcome"
    assert (
        client.post(path, headers=headers("other"), json={"requestId": str(uuid4())}).status_code
        == 404
    )
    later(forest, 21)
    forest["post"](path.removeprefix("/v1/me/"), status=409)
    assert forest["read"]()["tokenBalance"] == "0"


def test_second_device_cannot_take_over_or_heartbeat(forest):
    result = forest["post"]("visitor-sessions", {"installationId": forest["device"]})
    other = {"installationId": str(uuid4())}
    forest["post"]("visitor-sessions", other, status=409)
    forest["post"](
        "visitor-sessions/" + result["session"]["sessionId"] + "/heartbeat", other, status=409
    )
    later(forest, 46)
    assert (
        forest["post"]("visitor-sessions", other)["session"]["installationId"]
        == other["installationId"]
    )


def test_same_slot_reconnect_and_new_heartbeat_never_reroll(forest):
    visitor, session = opportunity(forest)
    assert heartbeat(forest, session)["opportunities"][0] == visitor
    forest["post"]("visitor-sessions/" + session + "/end", {"installationId": forest["device"]})
    new = forest["post"]("visitor-sessions", {"installationId": forest["device"]})
    assert heartbeat(forest, new["session"]["sessionId"])["opportunities"] == []


def test_clock_regression_never_rewinds(forest):
    forest["place"]()
    later(forest, 120)
    original = forest["read"]()
    later(forest, -60)
    after = forest["read"]()
    assert after["storedVisitsMicroUnits"] == original["storedVisitsMicroUnits"]
    assert after["serverTime"] == original["serverTime"]


def test_concurrent_claims_serialize_in_postgresql(app, forest):
    forest["place"]()
    later(forest, 600)

    def claim(_):
        with app.state.database.sessions() as session:
            return visitors.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                VisitorRequest(request_id=uuid4()),
                "visitor_claim",
                app.state.clock,
            )

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(claim, range(4)))
    assert sum(int(row["visits"]) for row in results) == 2
    assert forest["read"]()["tokenBalance"] == "2"


def test_restart_uses_persisted_receipt(app, forest):
    forest["place"]()
    later(forest, 240)
    request = {"requestId": str(uuid4())}
    result = forest["post"]("stored-visits/claim", request)
    other = create_app(app.state.settings)
    try:
        with other.state.database.sessions() as session:
            replay = visitors.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                VisitorRequest.model_validate(request),
                "visitor_claim",
                app.state.clock,
            )
        assert replay == result
    finally:
        other.state.database.engine.dispose()


def test_reward_failure_rolls_back_storage_wallet_and_receipt(app, forest, monkeypatch):
    forest["place"]()
    later(forest, 240)
    original = visitors.summary
    monkeypatch.setattr(
        visitors, "summary", lambda *args: (_ for _ in ()).throw(RuntimeError("injected"))
    )
    with pytest.raises(RuntimeError, match="injected"):
        forest["post"]("stored-visits/claim")
    monkeypatch.setattr(visitors, "summary", original)
    summary = forest["read"]()
    assert summary["claimableVisits"] == "1" and summary["tokenBalance"] == "0"


@pytest.mark.parametrize(
    "table",
    [
        "visitor_rules",
        "visitor_contexts",
        "visitor_settlements",
        "visitor_reward_events",
        "visitor_wallet_entries",
    ],
)
def test_visitor_history_is_immutable(app, forest, table):
    forest["place"]()
    later(forest, 240)
    forest["post"]("stored-visits/claim")
    with pytest.raises(IntegrityError):
        with app.state.database.engine.begin() as connection:
            connection.execute(
                text(
                    f'UPDATE "{table}" SET '
                    + ("version=version" if table == "visitor_rules" else "id=id")
                )
            )


def test_wallet_and_lots_reconcile(app, forest):
    forest["place"]()
    later(forest, 1300)
    forest["post"]("stored-visits/claim")
    later(forest, 700)
    forest["read"]()
    with app.state.database.sessions() as session:
        wallet = session.scalar(select(VisitorWallet))
        assert wallet.tokens == session.scalar(select(func.sum(VisitorWalletEntry.amount)))
        state = session.scalar(select(VisitorState))
        assert state.stored_whole == session.scalar(select(func.sum(VisitorStorageLot.visits)))
        settlements = session.scalars(
            select(VisitorSettlement).order_by(VisitorSettlement.start_at)
        ).all()
        assert all(
            a.end_at == b.start_at for a, b in zip(settlements, settlements[1:], strict=False)
        )


def test_late_growth_settles_old_attraction_before_advancing_stage(app, forest, client):
    forest["place"]()
    enrol = client.post(
        "/v1/activity/enrolments",
        headers=forest["headers"],
        json={
            "requestId": str(uuid4()),
            "installationId": forest["device"],
            "observedAt": NOW.isoformat(),
            "steps": 0,
        },
    )
    assert enrol.status_code == 200, enrol.text
    later(forest, 600)
    body = {
        "requestId": str(uuid4()),
        "installationId": forest["device"],
        "deviceId": enrol.json()["device"]["deviceId"],
        "observedAt": forest["now"][0].isoformat(),
        "days": [{"gameDate": "2026-10-23", "steps": 10000}],
    }
    response = client.post("/v1/activity/sync", headers=forest["headers"], json=body)
    assert response.status_code == 200, response.text
    assert response.json()["garden"]["plants"][0]["growthStage"] == "seedling"
    summary = forest["read"]()
    assert summary["storedVisitsMicroUnits"] == "2500000"
    assert summary["totalAttractionMicroUnits"] == "5000000"
    assert summary["tokenBalance"] == "0"
    with app.state.database.sessions() as session:
        settlement = session.scalar(select(VisitorSettlement))
        old = session.get(VisitorContext, settlement.context_id)
        assert old.snapshot["attraction"] == "2000000"
    assert (
        client.post("/v1/activity/sync", headers=forest["headers"], json=body).json()
        == response.json()
    )


def test_store_settles_old_membership_then_stops_production(forest, client):
    forest["place"]()
    later(forest, 240)
    response = client.post(
        "/v1/me/garden/edits",
        headers=forest["headers"],
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 1,
            "catalogVersion": "development-oak-v1",
            "actions": [{"action": "store", "plantId": forest["account"]["starterPlantId"]}],
        },
    )
    assert response.status_code == 200, response.text
    later(forest, 2400)
    assert forest["read"]()["claimableVisits"] == "1"
    assert forest["post"]("stored-visits/claim")["tokens"] == "1"


def test_concurrent_welcomes_with_distinct_request_ids_pay_once(app, forest):
    visitor, _ = opportunity(forest)

    def welcome(_):
        with app.state.database.sessions() as session:
            return visitors.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                VisitorRequest(request_id=uuid4()),
                "visitor_welcome",
                app.state.clock,
                target=UUID(visitor["opportunityId"]),
            )

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(welcome, range(4)))
    assert all(row == results[0] for row in results)
    assert forest["read"]()["tokenBalance"] == "1"


def test_request_id_cannot_change_operation_or_target(forest):
    visitor, _ = opportunity(forest)
    request = {"requestId": str(uuid4())}
    forest["post"]("visitor-opportunities/" + visitor["opportunityId"] + "/welcome", request)
    forest["post"]("stored-visits/claim", request, status=409)
    forest["post"]("visitor-opportunities/" + str(uuid4()) + "/welcome", request, status=409)


def test_same_request_uuid_is_independent_between_accounts(forest, register, client, headers):
    forest["place"]()
    other = register("other")
    response = client.post(
        "/v1/me/garden/edits",
        headers=headers("other"),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [
                {
                    "action": "plant",
                    "plantId": other["starterPlantId"],
                    "x": 2,
                    "y": 2,
                    "rotationDegrees": 0,
                }
            ],
        },
    )
    assert response.status_code == 200, response.text
    later(forest, 240)
    request = {"requestId": str(uuid4())}
    assert forest["post"]("stored-visits/claim", request)["tokens"] == "1"
    response = client.post("/v1/me/stored-visits/claim", headers=headers("other"), json=request)
    assert response.status_code == 200, response.text
    assert response.json()["tokens"] == "1"


def test_backdated_rule_publication_rejected_by_postgresql(app, forest):
    forest["read"]()
    with pytest.raises(IntegrityError, match="settled history"):
        add_rules(app, NOW - timedelta(seconds=1))


def test_controlled_rule_publication_rejects_past_and_accepts_future(app, forest):
    from forest_api.visitor_schemas import VisitorRuleDefinition

    forest["read"]()
    with app.state.database.sessions() as session:
        rule = session.get(VisitorRules, "development-visitors-v1")
        definition = VisitorRuleDefinition.model_validate(rule.rules)
    with app.state.database.sessions() as session, pytest.raises(ValueError, match="future"):
        visitors.publish_rules(
            session, app.state.settings, "past", definition, NOW, is_fixture=True
        )
    with app.state.database.sessions() as session:
        visitors.publish_rules(
            session,
            app.state.settings,
            "future",
            definition,
            datetime.now(UTC) + timedelta(hours=1),
            is_fixture=True,
        )
    assert forest["read"]()["ruleVersion"] == "development-visitors-v1"


def test_visitor_polling_is_rate_limited_without_affecting_replay(forest, client):
    forest["read"]()
    request = {"requestId": str(uuid4())}
    result = forest["post"]("stored-visits/claim", request)
    response = None
    for _ in range(100):
        response = client.get("/v1/me/visitors", headers=forest["headers"])
        if response.status_code == 429:
            break
    assert response.status_code == 429
    assert forest["post"]("stored-visits/claim", request) == result


def test_native_http_fixture_matches_current_schema():
    import json
    from pathlib import Path

    from forest_api.visitor_schemas import VisitorRewardResult, VisitorSummary

    path = (
        Path(__file__).resolve().parents[2]
        / "frontend/MovementForest/Resources/Fixtures/visitor-contract.json"
    )
    data = json.loads(path.read_text())
    for name in ("initial", "active", "stored"):
        VisitorSummary.model_validate(data[name])
    for name in ("welcome", "claim"):
        VisitorRewardResult.model_validate(data[name])


@pytest.mark.parametrize(
    "attraction,count", [(0, 0), (2_000_000, 1), (20_000_000, 1), (300_000_000, 15), (10**12, 1000)]
)
def test_development_pacing_model(app, attraction, count):
    import importlib.util
    from pathlib import Path

    from forest_api.visitor_schemas import VisitorRuleDefinition

    path = Path(__file__).resolve().parents[1] / "scripts/simulate_visitors.py"
    spec = importlib.util.spec_from_file_location("simulate_visitors", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with app.state.database.sessions() as session:
        definition = VisitorRuleDefinition.model_validate(
            session.get(VisitorRules, "development-visitors-v1").rules
        )
    result = module.simulate(definition, attraction, count, slots=10_000)
    if count:
        assert result["activeWelcomesPerHour"] > result["offlineVisitsPerHour"]
    else:
        assert result["activeWelcomesPerHour"] == result["offlineVisitsPerHour"] == 0
    assert result["issuedPerHour"] <= 120
