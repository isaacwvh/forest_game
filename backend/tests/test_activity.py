"""B5 real-PostgreSQL invariants; no HealthKit or cloud account required."""

import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, date, datetime, timedelta
from threading import Barrier, Event
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select, text
from sqlalchemy.exc import IntegrityError

from forest_api import activity, placement, services
from forest_api.activity_schemas import SyncActivity
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.calculations import MICRO
from forest_api.errors import ApiError
from forest_api.main import create_app
from forest_api.models import (
    ActivityCredit,
    ActivityDay,
    ActivityDevice,
    ApiRequest,
    EconomyConfig,
    Garden,
    GardenPlacement,
    OwnedPlant,
    PlantGrowthCredit,
    PlayerProgress,
    RewardEvent,
    RewardRecap,
)
from forest_api.schemas import GardenEditRequest

NOW = datetime(2026, 10, 22, 4, tzinfo=UTC)


@pytest.fixture
def actors(app, client, headers, register):
    current = [NOW]
    app.state.clock = lambda: current[0]

    def make(subject="alice", baseline=2000, placed=True):
        account = register(subject)
        owner, plant = UUID(account["profile"]["userId"]), UUID(account["starterPlantId"])
        installation = str(uuid4())
        body = {
            "requestId": str(uuid4()),
            "installationId": installation,
            "observedAt": current[0].isoformat(),
            "steps": baseline,
        }
        response = client.post("/v1/activity/enrolments", json=body, headers=headers(subject))
        assert response.status_code == 200, response.text
        device = response.json()["device"]["deviceId"]
        if placed:
            response = client.post(
                "/v1/me/garden/edits",
                json={
                    "requestId": str(uuid4()),
                    "expectedLayoutVersion": 0,
                    "catalogVersion": "development-oak-v1",
                    "actions": [
                        {
                            "action": "plant",
                            "plantId": str(plant),
                            "x": 2,
                            "y": 2,
                            "rotationDegrees": 35.12,
                        }
                    ],
                },
                headers=headers(subject),
            )
            assert response.status_code == 200, response.text
        return {
            "owner": owner,
            "plant": plant,
            "device": device,
            "installation": installation,
            "subject": subject,
            "now": current,
            "enrolment": body,
        }

    return make


def body_for(actor, steps=3000, **changes):
    return {
        "requestId": str(uuid4()),
        "installationId": actor["installation"],
        "deviceId": actor["device"],
        "observedAt": actor["now"][0].isoformat(),
        "days": [
            {
                "gameDate": actor["now"][0]
                .astimezone(activity.ZoneInfo("Asia/Singapore"))
                .date()
                .isoformat(),
                "steps": steps,
            }
        ],
        **changes,
    }


def submit(client, headers, actor, steps=3000, **changes):
    return client.post(
        "/v1/activity/sync",
        json=body_for(actor, steps, **changes),
        headers=headers(actor["subject"]),
    )


def custom_rules(app, **rate_changes):
    with app.state.database.sessions.begin() as session:
        original = session.get(EconomyConfig, "development-neutral-v1")
        rules = copy.deepcopy(original.rules)
        rules["metrics"]["steps"].update(rate_changes)
        session.add(
            EconomyConfig(
                version="test-exact",
                effective_at=datetime(2020, 1, 1, tzinfo=UTC),
                is_fixture=True,
                rules=rules,
            )
        )


def test_baseline_growth_stage_attraction_and_transform(app, client, headers, actors):
    actor = actors()
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, actor["plant"]).growth_micro_units = 95 * MICRO
    response = submit(client, headers, actor)
    assert response.status_code == 200, response.text
    result = response.json()
    plant = result["garden"]["plants"][0]
    assert plant["growthMicroUnits"] == str(105 * MICRO)
    assert plant["growthStage"] == "seedling"
    assert plant["growthProgress"] == {
        "stageStartMicroUnits": str(100 * MICRO),
        "nextStageMicroUnits": str(400 * MICRO),
        "maximumGrowthMicroUnits": str(1000 * MICRO),
    }
    assert result["garden"]["totalAttractionMicroUnits"] == str(5 * MICRO)
    assert result["garden"]["layoutVersion"] == 1
    assert result["garden"]["stateVersion"] == 2
    assert plant["placement"]["rotationDegrees"] == 35.12
    assert result["activitySteps"] == "1000"
    assert result["days"][0]["newlyEligibleSteps"] == 1000
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PlantGrowthCredit)) == 1
        event = session.scalar(select(RewardEvent))
        assert event.payload["resourceDeltas"] == {}
        assert not {"wallets", "wallet_entries"} & set(services.User.metadata.tables)


def test_replay_changed_payload_and_recreated_app(app, settings, client, headers, actors):
    actor = actors()
    body = body_for(actor)
    first = submit(client, headers, actor, **body)
    assert first.status_code == 200, first.text
    newer = submit(client, headers, actor, 4000)
    assert newer.status_code == 200
    assert submit(client, headers, actor, **body).json() == first.json()
    changed = {**body, "days": [{"gameDate": "2026-10-22", "steps": 9999}]}
    assert submit(client, headers, actor, **changed).status_code == 409
    other = create_app(settings)
    with other.state.database.sessions() as session:
        replay = activity.sync(
            session,
            settings,
            Identity(DEV_ISSUER, "alice"),
            SyncActivity.model_validate(body),
            clock=lambda: NOW + timedelta(days=90),
        )
        assert replay.model_dump(mode="json", by_alias=True) == first.json()
    other.state.database.engine.dispose()
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(RewardRecap)) == 2


def test_observed_downward_watermarks_and_new_uuid_do_not_duplicate(app, client, headers, actors):
    actor = actors(baseline=0)
    for total, delta in [(4000, 4000), (6500, 2500), (6500, 0), (5000, 0), (7000, 500)]:
        response = submit(client, headers, actor, total)
        assert response.status_code == 200, response.text
        assert response.json()["days"][0]["newlyEligibleSteps"] == delta
    with app.state.database.sessions() as session:
        row = session.get(ActivityDay, (actor["owner"], date(2026, 10, 22)))
        assert row.observed_steps == row.credited_steps == 7000
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 70 * MICRO
        assert session.scalar(select(func.count()).select_from(ActivityCredit)) == 3


def test_fractional_carry_persists_and_split_matches_single(app, client, headers, actors):
    custom_rules(app, normalisation="3", water_micro_units=1, daily_cap=None)
    split = actors("split", 0)
    single = actors("single", 0)
    for amount in [1, 2, 4]:
        response = submit(client, headers, split, amount)
        assert response.status_code == 200, response.text
    assert submit(client, headers, single, 4).status_code == 200
    with app.state.database.sessions() as session:
        a, b = (session.get(OwnedPlant, actor["plant"]) for actor in [split, single])
        assert a.growth_micro_units == b.growth_micro_units == 1
        assert a.fractional_state == b.fractional_state == {"numerator": "1", "denominator": "3"}


def test_duplicate_placed_and_stored_copies(app, client, headers, actors):
    actor = actors(baseline=0)
    with app.state.database.sessions.begin() as session:
        duplicate = services.award_plant(
            session, actor["owner"], "oak", "blue", "test", str(uuid4())
        )
        duplicate_id = duplicate.id
        session.add(
            GardenPlacement(
                plant_id=duplicate.id,
                owner_id=actor["owner"],
                garden_id=session.scalar(select(Garden.id)),
                x=5,
                y=5,
                rotation_degrees=0,
            )
        )
        stored = services.award_plant(
            session, actor["owner"], "oak", "standard", "test", str(uuid4())
        )
        stored_id = stored.id
        stored.growth_micro_units = 123
        stored.fractional_state = {"numerator": "1", "denominator": "3"}
    result = submit(client, headers, actor, 1000)
    assert result.status_code == 200, result.text
    assert result.json()["garden"]["totalAttractionMicroUnits"] == str(4 * MICRO)
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 10 * MICRO
        assert session.get(OwnedPlant, duplicate_id).growth_micro_units == 10 * MICRO
        assert session.get(OwnedPlant, stored_id).growth_micro_units == 123
        assert session.get(OwnedPlant, stored_id).fractional_state == {
            "numerator": "1",
            "denominator": "3",
        }
        assert session.scalar(select(func.count()).select_from(PlantGrowthCredit)) == 2


def test_maturity_once_caps_and_no_hidden_bank(app, client, headers, actors):
    actor = actors(baseline=0)
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, actor["plant"]).growth_micro_units = 995 * MICRO
    first = submit(client, headers, actor, 1000).json()
    assert first["garden"]["plants"][0]["growthMicroUnits"] == str(1000 * MICRO)
    assert first["firstMaturityCount"] == 1
    second = submit(client, headers, actor, 2000).json()
    assert second["firstMaturityCount"] == 1 and second["recapId"] is None
    assert second["garden"]["totalAttractionMicroUnits"] == str(20 * MICRO)
    assert second["activitySteps"] == "2000"


def test_daily_cap_and_activity_counters_are_independent(app, client, headers, actors):
    custom_rules(app, daily_cap=1000)
    actor = actors(baseline=0)
    for amount, water in [(700, 700), (1400, 300), (1700, 0)]:
        result = submit(client, headers, actor, amount).json()
        assert result["days"][0]["waterSteps"] == water
    assert result["activitySteps"] == "1700"
    assert result["garden"]["plants"][0]["growthMicroUnits"] == str(10 * MICRO)


def test_empty_garden_consumes_activity_not_future_growth(app, client, headers, actors):
    actor = actors(baseline=0, placed=False)
    assert submit(client, headers, actor, 1000).json()["garden"]["plants"] == []
    with app.state.database.sessions.begin() as session:
        session.add(
            GardenPlacement(
                plant_id=actor["plant"],
                owner_id=actor["owner"],
                garden_id=session.scalar(select(Garden.id)),
                x=2,
                y=2,
                rotation_degrees=0,
            )
        )
    assert (
        submit(client, headers, actor, 1000).json()["garden"]["plants"][0]["growthMicroUnits"]
        == "0"
    )
    assert submit(client, headers, actor, 1500).json()["garden"]["plants"][0][
        "growthMicroUnits"
    ] == str(5 * MICRO)


def test_unavailable_does_not_become_zero_and_first_available_is_baseline(
    app, client, headers, actors
):
    actor = actors(baseline=None)
    response = submit(client, headers, actor, None)
    assert response.status_code == 200, response.text
    assert not response.json()["device"]["ready"]
    first = submit(client, headers, actor, 9000).json()
    assert first["days"][0]["baselineEstablished"]
    assert first["days"][0]["newlyEligibleSteps"] == 0
    assert submit(client, headers, actor, 10000).json()["days"][0]["newlyEligibleSteps"] == 1000
    assert submit(client, headers, actor, None).json()["days"][0]["creditedSteps"] == 1000


def test_device_compare_swap_baseline_and_replays(app, client, headers, actors):
    actor = actors(baseline=0)
    old_body = body_for(actor, 1000)
    first = submit(client, headers, actor, **old_body).json()
    replacement = {
        "requestId": str(uuid4()),
        "installationId": str(uuid4()),
        "steps": 9000,
        "observedAt": NOW.isoformat(),
    }
    assert (
        client.post("/v1/activity/enrolments", json=replacement, headers=headers()).status_code
        == 409
    )
    replacement["expectedDeviceId"] = actor["device"]
    result = client.post("/v1/activity/enrolments", json=replacement, headers=headers())
    assert result.status_code == 200, result.text
    assert submit(client, headers, actor, **old_body).json() == first
    assert submit(client, headers, actor, 2000).status_code == 409
    actor["device"], actor["installation"] = (
        result.json()["device"]["deviceId"],
        replacement["installationId"],
    )
    next_result = submit(client, headers, actor, 9500).json()
    assert next_result["days"][0]["newlyEligibleSteps"] == 500
    assert next_result["activitySteps"] == "1500"
    assert next_result["garden"]["plants"][0]["growthMicroUnits"] == str(15 * MICRO)
    # Re-enrolling same installation with a fresh request must not reset its baseline.
    again = {
        **replacement,
        "requestId": str(uuid4()),
        "expectedDeviceId": actor["device"],
        "steps": 0,
    }
    assert client.post("/v1/activity/enrolments", json=again, headers=headers()).status_code == 200
    assert submit(client, headers, actor, 9500).json()["days"][0]["newlyEligibleSteps"] == 0


@pytest.mark.parametrize("value", [-1, True, 1.5, "100", 1_000_000_001])
def test_invalid_steps_are_rejected_without_writes(app, client, headers, actors, value):
    actor = actors()
    response = submit(client, headers, actor, value)
    assert response.status_code == 422
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(ActivityCredit)) == 0


@pytest.mark.parametrize(
    "changes,error",
    [
        ({"deviceId": str(uuid4())}, "inactive_activity_device"),
        ({"installationId": str(uuid4())}, "inactive_activity_device"),
        ({"observedAt": (NOW + timedelta(hours=1)).isoformat()}, "future_observation"),
        ({"observedAt": (NOW - timedelta(days=31)).isoformat()}, "observation_expired"),
        ({"days": [{"gameDate": "2026-10-23", "steps": 3000}]}, "future_game_date"),
        ({"days": [{"gameDate": "2026-10-10", "steps": 3000}]}, "activity_day_expired"),
        ({"days": [{"gameDate": "2026-10-21", "steps": 3000}]}, "before_activity_baseline"),
    ],
)
def test_device_and_date_validation(client, headers, actors, changes, error):
    actor = actors()
    response = submit(client, headers, actor, **changes)
    assert response.status_code in {409, 422}, response.text
    assert response.json()["error"]["code"] == error


def test_unimplemented_metrics_duplicate_dates_and_whole_batch_validation(
    app, client, headers, actors
):
    actor = actors()
    assert submit(client, headers, actor, workouts=[]).status_code == 422
    days = [{"gameDate": "2026-10-22", "steps": 3000}] * 2
    assert submit(client, headers, actor, days=days).status_code == 422
    days = [{"gameDate": "2026-10-22", "steps": 3000}, {"gameDate": "2026-10-23", "steps": 1}]
    assert submit(client, headers, actor, days=days).status_code == 422
    assert submit(client, headers, actor).json()["days"][0]["newlyEligibleSteps"] == 1000


def test_game_calendar_dst_and_new_days(app, client, headers, actors):
    assert (
        activity.day_bounds(date(2026, 3, 8), "America/New_York")[1]
        - activity.day_bounds(date(2026, 3, 8), "America/New_York")[0]
    ).total_seconds() == 23 * 3600
    assert (
        activity.day_bounds(date(2026, 11, 1), "America/New_York")[1]
        - activity.day_bounds(date(2026, 11, 1), "America/New_York")[0]
    ).total_seconds() == 25 * 3600
    actor = actors()
    actor["now"][0] += timedelta(days=1)
    result = submit(client, headers, actor, 500).json()
    assert result["days"][0]["newlyEligibleSteps"] == 500
    assert result["garden"]["plants"][0]["growthMicroUnits"] == str(5 * MICRO)


def test_late_queued_observation_uses_current_membership(app, client, headers, actors):
    actor = actors(baseline=0)
    body = body_for(actor, 1000)
    actor["now"][0] += timedelta(days=20)
    result = submit(client, headers, actor, **body)
    assert result.status_code == 200, result.text
    assert result.json()["days"][0]["newlyEligibleSteps"] == 1000
    actor["now"][0] += timedelta(days=11)
    # Completed requests replay beyond both windows; a new expired request fails.
    assert submit(client, headers, actor, **body).json() == result.json()
    body["requestId"] = str(uuid4())
    assert submit(client, headers, actor, **body).status_code == 422


def test_rule_versions_pin_days_and_do_not_reprice(app, client, headers, actors):
    actor = actors(baseline=0)
    custom_rules(app, water_micro_units=20 * MICRO)
    # Even though a newly inserted config sorts later, today's existing bucket remains pinned.
    first = submit(client, headers, actor, 1000).json()
    assert first["days"][0]["ruleVersion"] == "development-neutral-v1"
    actor["now"][0] += timedelta(days=1)
    second = submit(client, headers, actor, 1000).json()
    assert second["days"][0]["ruleVersion"] == "test-exact"
    assert second["garden"]["plants"][0]["growthMicroUnits"] == str(30 * MICRO)


def test_recaps_recovery_owner_access_and_ack_no_reward(app, client, headers, actors):
    actor = actors()
    recap = submit(client, headers, actor).json()["recapId"]
    actors("bob")
    assert client.get("/v1/me/reward-recaps", headers=headers("bob")).json()["recaps"] == []
    path = f"/v1/reward-recaps/{recap}/ack"
    ack = {"requestId": str(uuid4())}
    assert client.post(path, json=ack, headers=headers("bob")).status_code == 404
    pending = client.get("/v1/me/reward-recaps", headers=headers()).json()
    assert pending["recaps"][0]["recapId"] == recap
    first = client.post(path, json=ack, headers=headers())
    assert first.status_code == 200, first.text
    assert client.post(path, json=ack, headers=headers()).json() == first.json()
    assert client.get("/v1/me/reward-recaps", headers=headers()).json()["recaps"] == []
    assert submit(client, headers, actor).json()["recapId"] is None
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 10 * MICRO


def test_sync_failure_rolls_back_everything(app, settings, client, headers, actors):
    actor = actors()
    body = body_for(actor)

    class FailAfter:
        def before_change(self, *args):
            pass

        def after_change(self, *args):
            raise RuntimeError("injected")

    with app.state.database.sessions() as session, pytest.raises(RuntimeError, match="injected"):
        activity.sync(
            session,
            settings,
            Identity(DEV_ISSUER, "alice"),
            SyncActivity.model_validate(body),
            accounting=FailAfter(),
            clock=lambda: NOW,
        )
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 0
        assert session.get(ActivityDay, (actor["owner"], date(2026, 10, 22))).credited_steps == 0
        for model in [ActivityCredit, PlantGrowthCredit, RewardEvent, RewardRecap, PlayerProgress]:
            assert session.scalar(select(func.count()).select_from(model)) == 0
        assert session.get(ApiRequest, (actor["owner"], UUID(body["requestId"]))) is None
    assert submit(client, headers, actor, **body).status_code == 200


@pytest.mark.parametrize("same_id", [True, False])
def test_concurrent_syncs_cannot_duplicate(app, settings, client, headers, actors, same_id):
    actor = actors(baseline=0)
    first = body_for(actor, 1000)
    second = first if same_id else body_for(actor, 1500)
    barrier = Barrier(2)

    def run(body):
        barrier.wait(timeout=10)
        with app.state.database.sessions() as session:
            return activity.sync(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                SyncActivity.model_validate(body),
                clock=lambda: NOW,
            )

    with ThreadPoolExecutor(2) as pool:
        futures = [pool.submit(run, body) for body in [first, second]]
        results = [future.result(timeout=15) for future in futures]
    with app.state.database.sessions() as session:
        amount = 1000 if same_id else 1500
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == amount * 10_000
        assert session.get(PlayerProgress, actor["owner"]).activity_steps == amount
    if same_id:
        assert results[0] == results[1]


@pytest.mark.parametrize("store_first", [True, False])
def test_sync_store_race_follows_locked_membership(
    app, settings, client, headers, actors, store_first
):
    actor = actors(baseline=0)
    entered, release = Event(), Event()

    class Hold:
        def before_change(self, *args):
            entered.set()
            assert release.wait(10)

        def after_change(self, *args):
            pass

    sync_body = SyncActivity.model_validate(body_for(actor, 1000))
    edit_body = GardenEditRequest.model_validate(
        {
            "requestId": str(uuid4()),
            "catalogVersion": "development-oak-v1",
            "expectedLayoutVersion": 1,
            "actions": [{"action": "store", "plantId": str(actor["plant"])}],
        }
    )

    def run_sync(hold=False):
        with app.state.database.sessions() as session:
            return activity.sync(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                sync_body,
                accounting=Hold() if hold else placement.DISABLED_ACCOUNTING,
                clock=lambda: NOW,
            )

    def run_store(hold=False):
        with app.state.database.sessions() as session:
            return placement.edit_garden(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                edit_body,
                accounting=Hold() if hold else placement.DISABLED_ACCOUNTING,
                clock=lambda: NOW,
            )

    first, second = (run_store, run_sync) if store_first else (run_sync, run_store)
    with ThreadPoolExecutor(2) as pool:
        f1 = pool.submit(first, True)
        assert entered.wait(10)
        f2 = pool.submit(second)
        release.set()
        f1.result(timeout=15)
        f2.result(timeout=15)
    with app.state.database.sessions() as session:
        assert session.get(GardenPlacement, actor["plant"]) is None
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == (
            0 if store_first else 10 * MICRO
        )


def test_configuration_immutability_and_single_active_device(app, client, headers, actors):
    actor = actors()
    with pytest.raises(IntegrityError):
        with app.state.database.engine.begin() as connection:
            connection.execute(text("UPDATE economy_configs SET rules = '{}'::jsonb"))
    with pytest.raises(IntegrityError):
        with app.state.database.sessions.begin() as session:
            session.add(
                ActivityDevice(
                    id=uuid4(), owner_id=actor["owner"], installation_id=uuid4(), enrolled_at=NOW
                )
            )


def test_api_status_and_strict_body_limits(client, headers, actors):
    actor = actors()
    result = client.get("/v1/me/activity", headers=headers()).json()
    assert result["supportedMetrics"] == ["steps"] and result["device"]["ready"]
    assert result["queuedUploadMaxAgeDays"] == 30
    assert (
        client.post(
            "/v1/activity/sync", headers=headers(), content=b'{"requestId":"a","requestId":"b"}'
        ).status_code
        == 422
    )
    assert (
        client.post("/v1/activity/sync", headers=headers(), content=b" " * 65537).status_code == 413
    )
    assert submit(client, headers, actor).status_code == 200


def test_older_observation_cannot_overwrite_latest_observed_value(app, client, headers, actors):
    actor = actors(baseline=0)
    older = body_for(actor, 1000)
    actor["now"][0] += timedelta(minutes=1)
    assert submit(client, headers, actor, 500).status_code == 200
    # Forgiving watermark policy accepts the previously uncredited higher observation,
    # while preserving the more recent corrected observed total for diagnostics.
    assert submit(client, headers, actor, **older).json()["days"][0]["newlyEligibleSteps"] == 500
    with app.state.database.sessions() as session:
        row = session.get(ActivityDay, (actor["owner"], date(2026, 10, 22)))
        assert (row.observed_steps, row.credited_steps) == (500, 1000)


def test_concurrent_conflicting_payload_same_request_id(app, settings, client, headers, actors):
    actor = actors(baseline=0)
    body = body_for(actor, 1000)
    changed = copy.deepcopy(body)
    changed["days"][0]["steps"] = 1500
    barrier = Barrier(2)

    def run(payload):
        barrier.wait(timeout=10)
        try:
            with app.state.database.sessions() as session:
                activity.sync(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "alice"),
                    SyncActivity.model_validate(payload),
                    clock=lambda: NOW,
                )
                return 200
        except ApiError as error:
            return error.status

    with ThreadPoolExecutor(2) as pool:
        results = list(pool.map(run, [body, changed]))
    assert sorted(results) == [200, 409]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(ActivityCredit)) == 1
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units in {
            10 * MICRO,
            15 * MICRO,
        }


def test_pinned_coefficients_omitted_metrics_and_maturity_profiles(app, client, headers, actors):
    from forest_api.models import BehaviourProfile, GrowthProfile, Species

    actor = actors(baseline=0)
    with app.state.database.sessions.begin() as session:
        original = session.get(BehaviourProfile, ("dev_oak_behaviour", 1))
        rules = copy.deepcopy(original.rules)
        rules["metricMultipliers"] = {}
        session.add(BehaviourProfile(id="no_steps", version=1, rules=rules))
        session.flush()
        session.get(Species, "oak").behaviour_profile_id = "no_steps"
    # Changing a species default cannot change the already awarded copy.
    assert submit(client, headers, actor, 1000).json()["garden"]["plants"][0][
        "growthMicroUnits"
    ] == str(10 * MICRO)
    with app.state.database.sessions.begin() as session:
        copy_plant = services.award_plant(
            session, actor["owner"], "oak", "standard", "test", str(uuid4())
        )
        copy_id = copy_plant.id
        session.add(
            GardenPlacement(
                plant_id=copy_id,
                owner_id=actor["owner"],
                garden_id=session.scalar(select(Garden.id)),
                x=5,
                y=5,
                rotation_degrees=0,
            )
        )
    assert submit(client, headers, actor, 2000).status_code == 200
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, copy_id).growth_micro_units == 0
    with app.state.database.sessions.begin() as session:
        original = session.get(GrowthProfile, ("dev_oak_growth", 1))
        session.add(
            GrowthProfile(
                id="post_adult",
                version=1,
                thresholds=original.thresholds,
                maximum_growth_micro_units=original.maximum_growth_micro_units + 1,
            )
        )
        session.flush()
        session.get(OwnedPlant, copy_id).growth_profile_id = "post_adult"
    assert (
        submit(client, headers, actor, 3000).json()["error"]["code"]
        == "unsupported_maturity_profile"
    )
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 20 * MICRO


def test_b6_boundary_old_new_snapshots_and_replays(app, settings, client, headers, actors):
    actor = actors(baseline=0)
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, actor["plant"]).growth_micro_units = 95 * MICRO
    calls = []

    class Observe:
        def before_change(self, session, garden, boundary):
            calls.append(
                ("before", boundary, session.get(OwnedPlant, actor["plant"]).growth_micro_units)
            )

        def after_change(self, session, garden, boundary):
            calls.append(
                ("after", boundary, session.get(OwnedPlant, actor["plant"]).growth_micro_units)
            )

    body = SyncActivity.model_validate(body_for(actor, 1000))
    for _ in range(2):
        with app.state.database.sessions() as session:
            activity.sync(
                session,
                settings,
                Identity(DEV_ISSUER, "alice"),
                body,
                accounting=Observe(),
                clock=lambda: NOW,
            )
    assert calls == [("before", NOW, 95 * MICRO), ("after", NOW, 105 * MICRO)]


def test_ack_and_credit_payloads_are_database_immutable(app, client, headers, actors):
    actor = actors()
    recap = submit(client, headers, actor).json()["recapId"]
    client.post(
        f"/v1/reward-recaps/{recap}/ack", json={"requestId": str(uuid4())}, headers=headers()
    )
    for statement in [
        "UPDATE reward_recaps SET payload = '{}'::jsonb",
        "UPDATE reward_recaps SET acknowledged_at = NULL",
        "UPDATE reward_events SET payload = '{}'::jsonb",
        "UPDATE plant_growth_credits SET after_growth=after_growth+1",
        "UPDATE activity_credits SET end_steps=end_steps+1",
    ]:
        with pytest.raises(IntegrityError):
            with app.state.database.engine.begin() as connection:
                connection.execute(text(statement))


def test_enrolment_history_no_reset_and_pending_day_boundary(client, headers, actors):
    actor = actors(baseline=2000)
    assert submit(client, headers, actor, 3000).json()["activitySteps"] == "1000"
    body = {**actor["enrolment"], "requestId": str(uuid4()), "steps": 0}
    assert (
        client.post("/v1/activity/enrolments", json=body, headers=headers()).json()["device"][
            "baselineSteps"
        ]
        == 2000
    )
    assert submit(client, headers, actor, 3000).json()["days"][0]["newlyEligibleSteps"] == 0
    actor["now"][0] += timedelta(days=1)
    body = {
        **actor["enrolment"],
        "requestId": str(uuid4()),
        "installationId": str(uuid4()),
        "expectedDeviceId": actor["device"],
        "observedAt": (actor["now"][0] - timedelta(minutes=1)).isoformat(),
    }
    # A valid fresh observation on the replacement day establishes that day's baseline.
    assert client.post("/v1/activity/enrolments", json=body, headers=headers()).status_code == 200


def test_invalid_rules_fail_closed_and_production_fixtures_are_refused(
    app, settings, client, headers, actors
):
    from forest_api.calculations import CalculationRules

    actors(baseline=0)
    with app.state.database.sessions() as session:
        config = session.get(EconomyConfig, "development-neutral-v1")
        production = settings.model_copy(update={"environment": "production"})
        with pytest.raises(ApiError, match="Development rules"):
            activity.rules_for(config, production)
        invalid = EconomyConfig(version="invalid", is_fixture=False, rules={})
        with pytest.raises(ApiError, match="maintenance"):
            activity.rules_for(invalid, settings)
        assert CalculationRules.model_validate(config.rules).metrics["steps"].daily_cap == 100000


def test_multi_day_atomic_reconciliation_and_noop_versions(app, client, headers, actors):
    actor = actors(baseline=0)
    actor["now"][0] += timedelta(days=1)
    days = [{"gameDate": "2026-10-22", "steps": 1000}, {"gameDate": "2026-10-23", "steps": 2000}]
    result = submit(client, headers, actor, days=days).json()
    assert result["activitySteps"] == "3000"
    assert result["garden"]["stateVersion"] == 2 and result["garden"]["layoutVersion"] == 1
    assert result["garden"]["plants"][0]["growthMicroUnits"] == str(30 * MICRO)
    repeat = submit(client, headers, actor, days=days).json()
    assert repeat["recapId"] is None and repeat["garden"]["stateVersion"] == 2


def test_recaps_pagination_and_request_id_cross_operation(client, headers, actors):
    actor = actors(baseline=0)
    for amount in [1000, 2000, 3000]:
        assert submit(client, headers, actor, amount).status_code == 200
    first = client.get("/v1/me/reward-recaps?limit=2", headers=headers()).json()
    assert len(first["recaps"]) == 2 and first["nextCursor"]
    second = client.get(
        f"/v1/me/reward-recaps?limit=2&after={first['nextCursor']}", headers=headers()
    ).json()
    assert len(second["recaps"]) == 1 and second["nextCursor"] is None
    request = body_for(actor, 4000, requestId=actor["enrolment"]["requestId"])
    assert (
        submit(client, headers, actor, **request).json()["error"]["code"] == "idempotency_conflict"
    )


def test_replacement_with_unavailable_steps_stays_pending(app, client, headers, actors):
    actor = actors(baseline=0)
    assert submit(client, headers, actor, 1000).status_code == 200
    replacement = {
        "requestId": str(uuid4()),
        "installationId": str(uuid4()),
        "expectedDeviceId": actor["device"],
        "steps": None,
        "observedAt": NOW.isoformat(),
    }
    result = client.post("/v1/activity/enrolments", json=replacement, headers=headers())
    assert result.status_code == 200, result.text
    actor["device"], actor["installation"] = (
        result.json()["device"]["deviceId"],
        replacement["installationId"],
    )
    pending = submit(client, headers, actor, None)
    assert pending.status_code == 200, pending.text
    assert not pending.json()["device"]["ready"]
    assert submit(client, headers, actor, 9000).json()["days"][0]["newlyEligibleSteps"] == 0
    assert submit(client, headers, actor, 9500).json()["activitySteps"] == "1500"
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == 15 * MICRO


def test_pending_device_baseline_requires_a_fresh_snapshot(client, headers, actors):
    actor = actors(baseline=None)
    response = submit(
        client, headers, actor, 9000, observedAt=(NOW - timedelta(hours=1)).isoformat()
    )
    assert response.status_code == 422, response.text
    assert response.json()["error"]["code"] == "observation_expired"
    assert submit(client, headers, actor, 9000).json()["days"][0]["newlyEligibleSteps"] == 0
