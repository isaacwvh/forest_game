"""Transactional milestone rewards, progression sources and permanent eligibility."""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from fractions import Fraction
from types import SimpleNamespace
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from test_activity_launch import player as player
from test_visitor_rescale import scene as scene
from test_woodland import forest as forest

from forest_api import milestone_tracks as tracks
from forest_api import progression, recovery
from forest_api.activity_models import MilestoneClaim
from forest_api.collection_models import OwnedPack, PackDefinition
from forest_api.milestone_models import (
    MilestoneDay,
    MilestoneEntitlement,
    MilestoneEventState,
    MilestonePolicy,
    MilestoneSpecies,
    MilestoneState,
)
from forest_api.models import ApiRequest, PlayerProgress
from forest_api.visitor_models import VisitorWallet, VisitorWalletEntry


@pytest.fixture
def journey(forest, app):
    with app.state.database.sessions() as session:
        preview = tracks.activate(session, app.state.settings, clock=lambda: forest["now"][0])
    assert not preview["applied"] and preview["quests"] == 62
    with app.state.database.sessions() as session:
        assert session.get(MilestonePolicy, "milestones-woodland-v1") is None
    with app.state.database.sessions() as session:
        tracks.activate(session, app.state.settings, apply=True, clock=lambda: forest["now"][0])
    return {**forest, "headers": {**forest["headers"], "X-Forest-Milestones": "1"}}


def summary(client, journey):
    response = client.get("/v1/me/collection", headers=journey["headers"])
    assert response.status_code == 200, response.text
    return {m["milestoneId"]: m for m in response.json()["milestones"]}


def claim(client, journey, key, *, request=None, status=200):
    response = client.post(
        f"/v1/me/milestones/{key}/claim",
        headers=journey["headers"],
        json={"requestId": str(request or uuid4())},
    )
    assert response.status_code == status, response.text
    return response.json()


def step_progress(app, journey, steps):
    with app.state.database.sessions.begin() as session:
        progress = session.get(PlayerProgress, journey["owner"])
        progress.activity_steps = steps
        progression.credit_steps(session, journey["owner"], steps, uuid4(), journey["now"][0])


def test_definitions_and_opening_are_finite(journey, client, app):
    entries = summary(client, journey)
    assert set(m["track"] for m in entries.values()) == {"steps", "butterfly", "growth", "special"}
    assert entries["steps_new_beginnings"]["eligible"]
    assert not entries["steps_1000"]["eligible"]
    assert entries["discovery_epic_7"]["threshold"] == 7
    assert "discovery_epic_10" not in entries
    assert entries["discovery_legendary_3"]["rewardGems"] == "5"
    assert all(not m.get("cosmetics") for m in entries.values())
    assert all("premium-woodland" not in str(m["rewardPacks"]) for m in entries.values())
    receipt = claim(client, journey, "steps_new_beginnings")
    assert receipt["tokensEarned"] == receipt["gemsEarned"] == "0"
    assert len(receipt["packs"]) == 1 and receipt["packs"][0]["version"] == 20
    assert receipt["capacity"]["unopenedPacks"] == 1


def test_later_reward_does_not_require_claiming_earlier(journey, client, app):
    step_progress(app, journey, 10000)
    entries = summary(client, journey)
    assert all(entries[k]["eligible"] for k in ("steps_1000", "steps_5000", "steps_10000"))
    receipt = claim(client, journey, "steps_10000")
    assert receipt["tokensEarned"] == "300"
    assert summary(client, journey)["steps_new_beginnings"]["eligible"]


def test_claim_alias_and_compaction_never_duplicate(journey, client, app):
    journey = {**journey, "headers": {**journey["headers"], "X-Forest-Recovery": "1"}}
    request = uuid4()
    first = claim(client, journey, "steps_new_beginnings", request=request)
    assert claim(client, journey, "steps_new_beginnings", request=request) == first
    alias_id = uuid4()
    alias = claim(client, journey, "steps_new_beginnings", request=alias_id)
    assert alias["packs"] == first["packs"] and alias["requestId"] == str(alias_id)
    with app.state.database.sessions() as session:
        recovery.maintain(session, apply=True, now=journey["now"][0] + timedelta(days=90))
    result = client.post(
        "/v1/me/milestones/steps_new_beginnings/claim",
        headers={**journey["headers"], "X-Forest-Recovery": "1"},
        json={"requestId": str(request)},
    )
    assert result.status_code == 200 and result.json() == first
    with app.state.database.sessions() as session:
        assert session.get(ApiRequest, (journey["owner"], request)).response is None
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 1


def test_bonus_gems_do_not_consume_future_step_entitlement(journey, client, app):
    step_progress(app, journey, 200000)
    claim(client, journey, "steps_200000")
    step_progress(app, journey, 210000)
    with app.state.database.sessions.begin() as session:
        wallet = session.get(VisitorWallet, journey["owner"])
        assert (wallet.step_gems_earned, wallet.lifetime_gems_earned, wallet.gems) == (21, 23, 23)
        progression.reconcile(session, journey["owner"], wallet)
    account = client.get("/v1/me/account-summary", headers=journey["headers"]).json()
    assert account["wallet"]["stepGemsEarned"] == "21"
    assert account["wallet"]["bonusGemsEarned"] == "2"


def test_full_pack_storage_rolls_back_entire_bundle(journey, client, app):
    step_progress(app, journey, 500000)
    first = claim(client, journey, "steps_new_beginnings")
    with app.state.database.sessions.begin() as session:
        original = session.get(OwnedPack, UUID(first["packs"][0]["ownedPackId"]))
        for _ in range(49):
            session.add(
                OwnedPack(
                    id=uuid4(),
                    owner_id=original.owner_id,
                    pack_id=original.pack_id,
                    pack_version=original.pack_version,
                    exchange_id=original.exchange_id,
                    acquired_at=original.acquired_at,
                )
            )
        wallet = session.get(VisitorWallet, journey["owner"])
        before = wallet.tokens, wallet.gems, wallet.economy_version
    request = uuid4()
    claim(client, journey, "steps_500000", request=request, status=409)
    with app.state.database.sessions() as session:
        wallet = session.get(VisitorWallet, journey["owner"])
        assert (wallet.tokens, wallet.gems, wallet.economy_version) == before
        assert session.get(MilestoneClaim, (journey["owner"], "steps_500000")) is None
        assert session.get(MilestoneEntitlement, (journey["owner"], "steps_500000")) is not None
    assert summary(client, journey)["steps_500000"]["eligible"]
    opened = client.post(
        f"/v1/me/packs/{first['packs'][0]['ownedPackId']}/open",
        headers=journey["headers"],
        json={"requestId": str(uuid4())},
    )
    assert opened.status_code == 200, opened.text
    assert claim(client, journey, "steps_500000", request=request)["gemsEarned"] == "5"


def test_concurrent_devices_issue_one_bundle(journey, client, app):
    def take(_):
        return claim(client, journey, "steps_new_beginnings")

    with ThreadPoolExecutor(max_workers=2) as pool:
        receipts = list(pool.map(take, range(2)))
    assert receipts[0]["packs"] == receipts[1]["packs"]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 1


def test_pinned_reward_survives_new_pack_publication(journey, app, client):
    summary(client, journey)
    with app.state.database.sessions.begin() as session:
        old = session.get(PackDefinition, ("woodland", 20))
        session.add(
            PackDefinition(id="woodland", version=21, is_fixture=False, definition=old.definition)
        )
    assert claim(client, journey, "steps_new_beginnings")["packs"][0]["version"] == 20


def test_legacy_mapping_preserves_receipts_without_extra_opening(forest, app, client):
    forest["submit"](steps=2000)
    old = claim(client, forest, "first_movement")
    with app.state.database.sessions() as session:
        tracks.activate(session, app.state.settings, apply=True, clock=lambda: forest["now"][0])
    journey = {**forest, "headers": {**forest["headers"], "X-Forest-Milestones": "1"}}
    entries = summary(client, journey)
    assert entries["steps_1000"]["claimed"] and entries["steps_new_beginnings"]["claimed"]
    with app.state.database.sessions() as session:
        assert session.get(MilestoneClaim, (journey["owner"], "first_movement")).receipt == old
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 0
    with app.state.database.sessions() as session:
        result = tracks.backfill(session, apply=True, clock=lambda: journey["now"][0])
    assert result["accounts"] == 0


@pytest.mark.parametrize(
    "minutes,metres,keys",
    [
        (60, "5000", {"special_run_5km", "special_workout_60min"}),
        (60, "10000", {"special_run_10km", "special_workout_60min"}),
        (59, "4999.999", set()),
    ],
)
def test_running_and_duration_boundary_and_supersession(
    journey, app, client, minutes, metres, keys
):
    journey["now"][0] += timedelta(hours=2)
    end = journey["now"][0]
    workout = {
        "workoutId": str(uuid4()),
        "originalType": 37,
        "start": (end - timedelta(minutes=minutes)).isoformat(),
        "end": end.isoformat(),
        "durationMilliseconds": minutes * 60000,
        "sourceBundleIdentifier": "test.watch",
        "distanceMetres": metres,
    }
    journey["submit"](workouts=[workout])
    entries = summary(client, journey)
    ready = {
        k
        for k, e in entries.items()
        if k.startswith("special_run_") or k == "special_workout_60min"
        if e["eligible"]
    }
    assert ready == keys
    if metres == "10000":
        assert entries["special_run_5km"]["supersededBy"] == "special_run_10km"
        claim(client, journey, "special_run_5km", status=409)
    for key in keys:
        claim(client, journey, key)
    journey["submit"](workouts=[workout])
    assert not any(summary(client, journey)[key]["eligible"] for key in keys)


def test_daily_and_rolling_progress_survives_lower_observations(journey, client, app):
    journey["submit"](steps=21000)
    entries = summary(client, journey)
    assert entries["special_day_10000"]["eligible"] and entries["special_day_20000"]["eligible"]
    claim(client, journey, "special_day_10000")
    claim(client, journey, "special_day_20000")
    journey["submit"](steps=1500)
    with app.state.database.sessions() as session:
        state = session.get(MilestoneState, journey["owner"])
        assert state.progress["activity_days"] == 1
        assert session.scalar(select(MilestoneDay.steps)) == 20000
        assert session.scalar(select(func.sum(VisitorWalletEntry.amount))) == 900


def test_permanent_discovery_deduplicates_species_and_freezes_rarity(journey, app, client):
    with app.state.database.sessions.begin() as session:
        published = tracks.policy(session)
        for species, rarity in published.definition["species"].items():
            session.add(
                MilestoneSpecies(owner_id=journey["owner"], species_id=species, rarity=rarity)
            )
    entries = summary(client, journey)
    assert entries["discovery_epic_7"]["eligible"] and entries["discovery_legendary_3"]["eligible"]
    assert entries["discovery_common_10"]["progress"] == "10"


def test_old_client_cannot_claim_new_bundle(journey, client):
    old = {
        **journey,
        "headers": {k: v for k, v in journey["headers"].items() if k != "X-Forest-Milestones"},
    }
    assert summary(client, old) == {}
    claim(client, old, "steps_new_beginnings", status=426)


def test_event_parallel_progress_claim_grace_and_retained_rewards(journey, app, client):
    start = journey["now"][0] + timedelta(minutes=1)
    end = start + timedelta(days=7)
    with app.state.database.sessions() as session:
        preview = tracks.schedule_event(
            session,
            event_id="woodland_week",
            name="Woodland Week",
            starts_at=start,
            ends_at=end,
            claim_until=end + timedelta(days=7),
            attribution="collection_time",
        )
    assert not preview["applied"]
    with app.state.database.sessions() as session:
        tracks.schedule_event(
            session,
            event_id="woodland_week",
            name="Woodland Week",
            starts_at=start,
            ends_at=end,
            claim_until=end + timedelta(days=7),
            attribution="collection_time",
            apply=True,
        )
    assert not any(e["track"] == "event" for e in summary(client, journey).values())
    journey["now"][0] = start
    entries = summary(client, journey)
    assert sum(e["track"] == "event" for e in entries.values()) == 4
    for index in range(5):
        journey["now"][0] = start + timedelta(days=index)
        journey["submit"](steps=2000)
    entries = summary(client, journey)
    assert entries["event_woodland_week_days_3"]["eligible"]
    assert entries["event_woodland_week_days_5"]["eligible"]
    assert not entries["event_woodland_week_butterflies"]["eligible"]
    with app.state.database.sessions() as session:
        state = session.get(MilestoneEventState, (journey["owner"], "woodland_week"))
        assert state.progress["activity_days"] == 5
    journey["now"][0] = end + timedelta(days=1)
    assert claim(client, journey, "event_woodland_week_days_5")["packs"]
    journey["now"][0] = end + timedelta(days=8)
    entries = summary(client, journey)
    assert entries["event_woodland_week_days_3"]["earnedAt"]
    assert entries["event_woodland_week_days_3"]["unavailableReason"]
    claim(client, journey, "event_woodland_week_days_3", status=409)


def test_rolling_days_is_not_a_consecutive_streak(journey, app, client):
    start = journey["now"][0]
    for index in range(7):
        journey["now"][0] = start + timedelta(days=index * 2)
        journey["submit"](steps=2000)
    entries = summary(client, journey)
    assert entries["special_days_7_in_14"]["eligible"]
    assert entries["special_days_30"]["progress"] == "7"
    journey["now"][0] += timedelta(days=20)
    assert summary(client, journey)["special_days_7_in_14"]["eligible"]


def test_workout_history_and_manual_distance_never_earn_running_rewards(journey, client):
    end = journey["now"][0] + timedelta(hours=2)
    start = end - timedelta(minutes=60)
    journey["now"][0] = end
    for user_entered, before in ((True, False), (False, True)):
        shift = timedelta(days=2) if before else timedelta(0)
        workout = {
            "workoutId": str(uuid4()),
            "originalType": 37,
            "start": (start - shift).isoformat(),
            "end": (end - shift).isoformat(),
            "durationMilliseconds": 3600000,
            "sourceBundleIdentifier": "test.watch",
            "distanceMetres": "10000",
            "wasUserEntered": user_entered,
        }
        journey["submit"](workouts=[workout])
    entries = summary(client, journey)
    assert not any(
        entries[key]["eligible"]
        for key in ("special_run_5km", "special_run_10km", "special_workout_60min")
    )


def test_earlier_5km_entitlement_survives_later_10km_run(journey, client):
    for distance in ("5000", "10000"):
        journey["now"][0] += timedelta(hours=2)
        end = journey["now"][0]
        journey["submit"](
            workouts=[
                {
                    "workoutId": str(uuid4()),
                    "originalType": 37,
                    "start": (end - timedelta(minutes=30)).isoformat(),
                    "end": end.isoformat(),
                    "durationMilliseconds": 1800000,
                    "sourceBundleIdentifier": "test.watch",
                    "distanceMetres": distance,
                }
            ]
        )
    entries = summary(client, journey)
    assert entries["special_run_5km"]["eligible"]
    assert entries["special_run_10km"]["eligible"]
    claim(client, journey, "special_run_10km")
    assert summary(client, journey)["special_run_5km"]["eligible"]


def test_bonus_gems_reconcile_after_gem_purchase(journey, client, app):
    step_progress(app, journey, 200000)
    claim(client, journey, "steps_200000")
    receipt = client.post(
        "/v1/me/exchanges",
        headers=journey["headers"],
        json={
            "requestId": str(uuid4()),
            "offerId": "premium-woodland",
            "offerVersion": 20,
            "quantity": 1,
        },
    )
    assert receipt.status_code == 200, receipt.text
    with app.state.database.sessions.begin() as session:
        wallet = session.get(VisitorWallet, journey["owner"])
        assert wallet.gems == 17 and wallet.lifetime_gems_earned == 22
        progression.reconcile(session, journey["owner"], wallet)


def test_generated_offline_visitors_count_only_after_collection(journey, client):
    journey["now"][0] += timedelta(hours=2)
    generated = client.get("/v1/me/visitors", headers=journey["headers"])
    assert generated.status_code == 200, generated.text
    assert not summary(client, journey)["butterfly_1"]["eligible"]
    body = {"requestId": str(uuid4())}
    collected = client.post("/v1/me/stored-visits/claim", headers=journey["headers"], json=body)
    assert collected.status_code == 200 and int(collected.json()["visits"]) > 0, collected.text
    entries = summary(client, journey)
    count = entries["butterfly_1"]["progress"]
    assert entries["butterfly_1"]["eligible"]
    assert (
        client.post("/v1/me/stored-visits/claim", headers=journey["headers"], json=body).status_code
        == 200
    )
    claim(client, journey, "butterfly_1")
    assert summary(client, journey)["butterfly_1"]["progress"] == count


def test_running_qualification_survives_exhausted_daily_workout_growth_cap(journey, client):
    for kind, minutes, distance in ((52, 180, None), (37, 60, "5000")):
        journey["now"][0] += timedelta(minutes=minutes + 10)
        end = journey["now"][0]
        workout = {
            "workoutId": str(uuid4()),
            "originalType": kind,
            "start": (end - timedelta(minutes=minutes)).isoformat(),
            "end": end.isoformat(),
            "durationMilliseconds": minutes * 60000,
            "sourceBundleIdentifier": "test.watch",
        }
        if distance:
            workout["distanceMetres"] = distance
        journey["submit"](workouts=[workout])
    assert summary(client, journey)["special_run_5km"]["eligible"]


def test_backfill_preview_lists_exact_rewards_without_persisting(journey, app):
    step_progress(app, journey, 10000)
    with app.state.database.sessions() as session:
        preview = tracks.backfill(session, clock=lambda: journey["now"][0])
    assert preview["accounts"] == 1 and not preview["applied"] and not preview["granted"]
    rewards = {e["milestoneId"]: e for e in preview["preview"][0]["entitlements"]}
    assert rewards["steps_10000"]["rewardTokens"] == "300"
    assert rewards["steps_1000"]["rewardPacks"][0]["version"] == 20
    with app.state.database.sessions() as session:
        assert session.get(MilestoneState, journey["owner"]) is None
        assert session.scalar(select(func.count()).select_from(MilestoneEntitlement)) == 0
    with app.state.database.sessions() as session:
        result = tracks.backfill(session, apply=True, clock=lambda: journey["now"][0])
    assert result["preview"] == preview["preview"]


def test_exact_workout_day_fractions_survive_without_string_truncation(journey, app):
    minutes = Fraction(1, 10**160 + 7)
    day = SimpleNamespace(
        game_date=journey["now"][0].date(),
        newly_eligible_steps=0,
        metrics={"workout_minutes.running": {"newlyEligible": str(minutes)}},
    )
    with app.state.database.sessions.begin() as session:
        tracks.observe_activity(session, journey["owner"], journey["now"][0], [day])
    with app.state.database.sessions() as session:
        row = session.get(MilestoneDay, (journey["owner"], day.game_date))
        assert Fraction(row.workout_minutes) == minutes
        assert not row.active
