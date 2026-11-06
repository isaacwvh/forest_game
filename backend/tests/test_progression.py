"""Pure v1 math and real-PostgreSQL currency, recovery and summary invariants."""

from concurrent.futures import ThreadPoolExecutor
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from test_activity import actors as actors
from test_activity import body_for, custom_rules, submit

from forest_api import progression, services
from forest_api.calculations import MAX_INTEGER
from forest_api.models import ApiRequest, PlayerProgress, RewardEvent
from forest_api.progression_models import GemGrant
from forest_api.visitor_models import VisitorWallet


@pytest.mark.parametrize(
    "steps,level,into,needed",
    [
        (0, 1, 0, 50),
        (99, 1, 0, 50),
        (5000, 2, 0, 75),
        (12500, 3, 0, 100),
        (35000, 5, 0, 150),
        (37250, 5, 22, 150),
        (50000, 6, 0, 175),
        (522500, 20, 0, 525),
    ],
)
def test_step_math(steps, level, into, needed):
    result = progression.snapshot(
        PlayerProgress(activity_steps=steps, first_maturity_count=0, progression_version=0)
    )
    assert (result.level, result.xp_into_level, result.xp_for_next_level) == (
        level,
        str(into),
        str(needed),
    )
    assert result.steps_into_next_gem == steps % 10000
    assert result.steps_to_next_gem == 10000 - steps % 10000


def test_math_at_bigint_limit():
    result = progression.snapshot(
        PlayerProgress(activity_steps=MAX_INTEGER, first_maturity_count=0, progression_version=0)
    )
    xp = MAX_INTEGER // 100
    assert progression.xp_threshold(result.level) <= xp < progression.xp_threshold(result.level + 1)
    assert 0 <= int(result.xp_into_level) < int(result.xp_for_next_level)


def test_thresholds_summary_and_replay(app, client, actors, headers):
    actor = actors(baseline=0)
    assert submit(client, headers, actor, 9999).json()["wallet"]["gemBalance"] == "0"
    body = body_for(actor, 10000)
    first = client.post("/v1/activity/sync", json=body, headers=headers())
    assert first.status_code == 200, first.text
    assert first.json()["wallet"]["gemBalance"] == "1"
    assert first.json()["progression"]["stepsIntoNextGem"] == 0
    assert first.json()["progression"]["stepsToNextGem"] == 10000
    assert submit(client, headers, actor, 37250).json()["wallet"]["gemBalance"] == "3"
    assert client.post("/v1/activity/sync", json=body, headers=headers()).json() == first.json()
    latest = client.get("/v1/me/account-summary", headers=headers()).json()
    assert latest["wallet"]["gemBalance"] == "3"
    assert latest["progression"]["level"] == 5
    assert latest["progression"]["xpIntoLevel"] == "22"
    assert latest["progression"]["stepsIntoNextGem"] == 7250
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.sum(GemGrant.amount))) == 3
        assert session.scalar(select(func.count()).select_from(GemGrant)) == 2
        assert session.scalar(
            select(RewardEvent).where(RewardEvent.request_id == UUID(body["requestId"]))
        ).payload["resourceDeltas"] == {"gems": "1"}
        progression.reconcile(session, actor["owner"], session.get(VisitorWallet, actor["owner"]))


def test_empty_and_capped_growth_still_awards(app, client, actors, headers):
    custom_rules(app, daily_cap=100)
    actor = actors(baseline=0, placed=False)
    result = submit(client, headers, actor, 35000).json()
    assert result["garden"]["plants"] == []
    assert result["wallet"]["gemBalance"] == "3"
    assert result["progression"]["totalXp"] == "350"
    assert result["days"][0]["waterSteps"] == 100
    result = submit(client, headers, actor, 20000).json()
    assert result["wallet"]["gemBalance"] == "3"
    assert result["progression"]["lifetimeRecordedSteps"] == "35000"


def test_currency_rolls_back_with_sync(app, client, actors, headers, monkeypatch):
    actor = actors(baseline=0)
    body = body_for(actor, 37250)

    def fail(*args, **kwargs):
        raise RuntimeError("forced receipt failure")

    with monkeypatch.context() as patch:
        patch.setattr(services, "record_request", fail)
        with pytest.raises(RuntimeError, match="forced receipt"):
            client.post("/v1/activity/sync", json=body, headers=headers())
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, actor["owner"]).gems == 0
        assert session.get(PlayerProgress, actor["owner"]).activity_steps == 0
        assert session.scalar(select(func.count()).select_from(GemGrant)) == 0
    assert (
        client.post("/v1/activity/sync", json=body, headers=headers()).json()["wallet"][
            "gemBalance"
        ]
        == "3"
    )


def test_concurrent_observations_mint_once(app, client, actors, headers):
    actor = actors(baseline=0)
    bodies = [body_for(actor, 37250) for _ in range(2)]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(
                lambda body: client.post("/v1/activity/sync", json=body, headers=headers()), bodies
            )
        )
    assert all(response.status_code == 200 for response in results)
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, actor["owner"]).gems == 3
        assert session.scalar(select(func.count()).select_from(GemGrant)) == 1


def test_read_only_backfill_and_account_isolation(app, client, register, headers):
    owner = UUID(register()["profile"]["userId"])
    register("bob")
    with app.state.database.sessions.begin() as session:
        session.get(PlayerProgress, owner).activity_steps = 37250
        session.get(VisitorWallet, owner).progression_initialized = False
    for _ in range(2):
        response = client.get("/v1/me/account-summary", headers=headers())
        assert response.status_code == 200
        assert response.json()["wallet"]["initialized"] is False
    with app.state.database.sessions() as session:
        assert progression.backfill(session)["gems"] == "3"
        assert progression.backfill(session, apply=True)["gems"] == "3"
        assert progression.backfill(session, apply=True)["initialized"] == 0
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(GemGrant)) == 1
        assert session.get(VisitorWallet, owner).gems == 3
    assert (
        client.get("/v1/me/account-summary", headers=headers("bob")).json()["wallet"]["gemBalance"]
        == "0"
    )
    assert client.get("/v1/me/account-summary").status_code == 401


def test_compacted_sync_cannot_recredit(app, client, actors, headers):
    actor = actors(baseline=0)
    body = body_for(actor, 10000)
    response = client.post(
        "/v1/activity/sync", json=body, headers={**headers(), "X-Forest-Recovery": "1"}
    )
    assert response.status_code == 200
    with app.state.database.sessions.begin() as session:
        record = session.get(ApiRequest, (actor["owner"], UUID(body["requestId"])))
        record.response = None
    replay = client.post(
        "/v1/activity/sync", json=body, headers={**headers(), "X-Forest-Recovery": "1"}
    )
    assert replay.status_code == 200
    assert replay.json()["recovery"]["refreshRequired"] is True
    assert (
        client.get("/v1/me/account-summary", headers=headers()).json()["wallet"]["gemBalance"]
        == "1"
    )


def test_upgrade_preserves_legacy_steps_and_tokens(database_factory):
    from alembic import command
    from conftest import migration_config, migration_url
    from sqlalchemy import create_engine, text
    from sqlalchemy.orm import Session

    owner = uuid4()
    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "0012_inventory_management")
        engine = create_engine(url)
        try:
            with engine.begin() as conn:
                conn.execute(
                    text(
                        "INSERT INTO users (id, auth_issuer, auth_subject, username, display_name, "
                        "game_timezone) VALUES "
                        "(:owner, 'test', 'legacy', 'legacy', 'Legacy', 'Asia/Singapore')"
                    ),
                    {"owner": owner},
                )
                conn.execute(
                    text(
                        "INSERT INTO visitor_wallets "
                        "(owner_id, tokens, hosted_active, hosted_offline) "
                        "VALUES (:owner, 1234, 12, 34)"
                    ),
                    {"owner": owner},
                )
                conn.execute(
                    text(
                        "INSERT INTO player_progress "
                        "(owner_id, activity_steps, first_maturity_count) "
                        "VALUES (:owner, 37250, 2)"
                    ),
                    {"owner": owner},
                )
            command.upgrade(configuration, "head")
            command.check(configuration)
            with Session(engine) as session:
                result = progression.backfill(session, apply=True)
                assert result["gems"] == "3"
                assert progression.backfill(session, apply=True)["initialized"] == 0
                wallet = session.get(VisitorWallet, owner)
                assert (wallet.tokens, wallet.hosted_active, wallet.hosted_offline) == (
                    1234,
                    12,
                    34,
                )
                assert wallet.gems == 3
                progress = session.get(PlayerProgress, owner)
                assert (progress.activity_steps, progress.first_maturity_count) == (37250, 2)
                progression.reconcile(session, owner, wallet)
        finally:
            engine.dispose()


def test_backfill_racing_sync_still_mints_once(app, client, actors, headers):
    actor = actors(baseline=0)
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, actor["owner"]).progression_initialized = False

    def backfill():
        with app.state.database.sessions() as session:
            return progression.backfill(session, apply=True)

    with ThreadPoolExecutor(max_workers=2) as pool:
        initialized = pool.submit(backfill)
        synced = pool.submit(submit, client, headers, actor, 37250)
        initialized.result()
        assert synced.result().status_code == 200
    with app.state.database.sessions() as session:
        wallet = session.get(VisitorWallet, actor["owner"])
        assert wallet.gems == 3
        assert session.scalar(select(func.sum(GemGrant.amount))) == 3
        progression.reconcile(session, actor["owner"], wallet)


def test_existing_token_exchange_keeps_gems_and_hosted_counts(economy, client, actors, headers):
    actor = actors(baseline=0, placed=False)
    assert submit(client, headers, actor, 37250).json()["wallet"]["gemBalance"] == "3"
    bought = client.post(
        "/v1/me/exchanges",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "offerId": "woodland",
            "offerVersion": 1,
            "quantity": 1,
        },
    )
    assert bought.status_code == 200, bought.text
    wallet = client.get("/v1/me/account-summary", headers=headers()).json()["wallet"]
    assert wallet["gemBalance"] == "3"
    assert wallet["tokenBalance"] == "95"
    assert wallet["hostedTotal"] == "0"
