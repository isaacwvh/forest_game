from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from fractions import Fraction
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from test_activity import actors as actors
from test_activity import body_for, submit

from forest_api import level_benefits as benefits
from forest_api import services
from forest_api.errors import ApiError
from forest_api.models import PlayerProgress
from forest_api.progression_models import AccountLevelState, LevelBenefitsPolicy, LevelUpNotice
from forest_api.skill_rules import CAPS_V1, SkillCaps
from forest_api.skills import SkillSnapshot
from forest_api.visitor_models import VisitorContext, VisitorState, VisitorStorageLot


@pytest.mark.parametrize(
    "level,base,plants",
    [
        (1, 600, 50),
        (2, 675, 50),
        (4, 825, 50),
        (5, 900, 60),
        (7, 1020, 60),
        (10, 1200, 75),
        (15, 1500, 90),
        (20, 1800, 100),
        (21, 1800, 100),
    ],
)
def test_original_tiers(level, base, plants):
    assert benefits.base_capacity(level) == base
    assert benefits.plant_limit(level) == plants


def test_skill_rounding_and_dynamic_ceiling(monkeypatch):
    skills = SkillSnapshot((), SkillCaps.model_validate(CAPS_V1), "test")
    monkeypatch.setattr(
        skills,
        "total",
        lambda scope, operation="percent": Fraction(1, 4) if operation == "percent" else 0,
    )
    assert skills.capacity(600, 1800) == 750
    assert skills.capacity(825, 2475) == 1031
    assert skills.capacity(900, 2700) == 1125
    assert skills.capacity(1800, 5400) == 2250
    monkeypatch.setattr(skills, "total", lambda *args, **kwargs: Fraction(20))
    assert skills.capacity(1800, 5400) == 5400


def activate(app, actor):
    with app.state.database.sessions() as session:
        return benefits.activate(
            session, app.state.settings, apply=True, clock=lambda: actor["now"][0]
        )


def summary(client, headers):
    response = client.get("/v1/me/account-summary", headers=headers())
    assert response.status_code == 200, response.text
    return response.json()


def test_level_up_capacity_receipt_and_replay(app, client, actors, headers):
    actor = actors(baseline=0, placed=False)
    assert submit(client, headers, actor, 34999).status_code == 200
    assert activate(app, actor)["applied"]
    initial = summary(client, headers)
    assert initial["benefits"]["baseOfflineCapacity"] == 825
    assert initial["benefits"]["plantLimit"] == 50
    assert initial["levelUpNotice"] is None
    body = body_for(actor, 35000)
    result = client.post("/v1/activity/sync", json=body, headers=headers())
    assert result.status_code == 200, result.text
    current = summary(client, headers)
    assert current["benefits"]["baseOfflineCapacity"] == 900
    assert current["benefits"]["plantLimit"] == 60
    notice = current["levelUpNotice"]
    assert (notice["fromLevel"], notice["toLevel"]) == (4, 5)
    assert (notice["baseOfflineBefore"], notice["baseOfflineAfter"]) == (825, 900)
    assert (notice["plantLimitBefore"], notice["plantLimitAfter"]) == (50, 60)
    assert client.get("/v1/me/inventory", headers=headers()).json()["capacity"]["plantLimit"] == 60
    assert client.get("/v1/me/visitors", headers=headers()).json()["capacity"] == 900
    assert client.post("/v1/activity/sync", json=body, headers=headers()).json() == result.json()
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(LevelUpNotice)) == 1
        state = session.get(AccountLevelState, actor["owner"])
        assert state.reached_level == 5 and state.presented_level == 4


def test_multi_level_notice_claim_is_once_across_devices(app, client, actors, headers):
    actor = actors(baseline=0, placed=False)
    activate(app, actor)
    assert submit(client, headers, actor, 37250).status_code == 200
    notice = summary(client, headers)["levelUpNotice"]
    assert (notice["fromLevel"], notice["toLevel"]) == (1, 5)
    path = f"/v1/me/level-up-notices/{notice['id']}/present"
    requests = [{"requestId": str(uuid4()), "installationId": str(uuid4())} for _ in range(2)]

    def claim(body):
        response = client.post(path, json=body, headers=headers())
        assert response.status_code == 200, response.text
        return response.json()

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(claim, requests))
    assert sorted(result["mayPresent"] for result in results) == [False, True]
    winner = results.index(next(value for value in results if value["mayPresent"]))
    assert claim(requests[winner])["mayPresent"]
    assert summary(client, headers)["levelUpNotice"] is None
    assert summary(client, headers)["benefits"]["plantLimit"] == 60
    with app.state.database.sessions() as session:
        assert session.get(AccountLevelState, actor["owner"]).presented_level == 5


def test_activation_is_repeat_safe_preserves_over_cap_and_no_old_popups(
    app, client, actors, headers
):
    actor = actors(baseline=0, placed=False)
    submit(client, headers, actor, 37250)
    with app.state.database.sessions.begin() as session:
        state = session.scalar(select(VisitorState))
        context = session.get(VisitorContext, state.context_id)
        state.stored_whole = 1200
        session.add(
            VisitorStorageLot(
                garden_id=state.garden_id,
                rule_version=context.rule_version,
                tokens_per_visit=context.snapshot["rules"]["tokens_per_visit"],
                visits=1200,
            )
        )
    with app.state.database.sessions() as session:
        assert benefits.activate(session, app.state.settings)["applied"] is False
        assert session.scalar(select(func.count()).select_from(LevelBenefitsPolicy)) == 0
    activate(app, actor)
    assert activate(app, actor)["alreadyActive"]
    state = client.get("/v1/me/visitors", headers=headers()).json()
    assert state["claimableVisits"] == "1200" and state["capacity"] == 900
    assert summary(client, headers)["levelUpNotice"] is None


def test_inventory_enforcement_changes_at_level_milestone(app, client, actors, headers):
    actor = actors(baseline=0, placed=False)
    activate(app, actor)
    with app.state.database.sessions.begin() as session:
        for index in range(49):
            services.award_plant(session, actor["owner"], "oak", "standard", "test", str(index))
    with app.state.database.sessions.begin() as session:
        with pytest.raises(ApiError, match="Plant collection full"):
            services.award_plant(session, actor["owner"], "oak", "standard", "test", "full")
    submit(client, headers, actor, 35000)
    with app.state.database.sessions.begin() as session:
        services.award_plant(session, actor["owner"], "oak", "standard", "test", "expanded")
    assert client.get("/v1/me/inventory", headers=headers()).json()["capacity"]["ownedPlants"] == 51


def test_notice_and_benefits_roll_back_with_activity(app, client, actors, headers, monkeypatch):
    actor = actors(baseline=0, placed=False)
    activate(app, actor)
    body = body_for(actor, 5000)
    with monkeypatch.context() as patch:

        def fail(*args, **kwargs):
            raise RuntimeError("forced failure")

        patch.setattr(services, "record_request", fail)
        with pytest.raises(RuntimeError, match="forced failure"):
            client.post("/v1/activity/sync", json=body, headers=headers())
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(LevelUpNotice)) == 0
        assert session.get(PlayerProgress, actor["owner"]).activity_steps == 0
        assert session.get(AccountLevelState, actor["owner"]).reached_level == 1
    assert client.post("/v1/activity/sync", json=body, headers=headers()).status_code == 200


def test_new_account_after_activation_and_notice_ownership(app, client, actors, headers, register):
    first = actors(baseline=0, placed=False)
    activate(app, first)
    second = actors("bob", baseline=0, placed=False)
    submit(client, headers, second, 5000)
    current = client.get("/v1/me/account-summary", headers=headers("bob")).json()
    assert current["benefits"]["baseOfflineCapacity"] == 675
    notice = current["levelUpNotice"]
    response = client.post(
        f"/v1/me/level-up-notices/{notice['id']}/present",
        json={"requestId": str(uuid4()), "installationId": str(uuid4())},
        headers=headers(),
    )
    assert response.status_code == 404
    with app.state.database.sessions() as session:
        assert session.get(AccountLevelState, second["owner"]).presented_level == 1


def test_old_capacity_is_settled_before_new_level(app, client, actors, headers):
    actor = actors(baseline=0, placed=True)
    activate(app, actor)
    actor["now"][0] += timedelta(hours=1)
    submit(client, headers, actor, 5000)
    with app.state.database.sessions() as session:
        state = session.scalar(select(VisitorState))
        assert session.get(VisitorContext, state.context_id).snapshot["capacity"] == 675
        assert state.stored_whole <= 600
