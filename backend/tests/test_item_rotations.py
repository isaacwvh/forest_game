from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from fractions import Fraction
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select

from forest_api import item_catalogue, items, services, shop
from forest_api.calculations import MICRO
from forest_api.item_models import (
    DailyItemGrant,
    ItemDefinition,
    ItemSkillProfile,
    ShopAllowance,
    ShopDay,
    ShopOfferWindow,
    ShopWeek,
)
from forest_api.models import Garden, OwnedPlant
from forest_api.schemas import BehaviourDefinition
from forest_api.skill_rules import CAPS_V1, SkillCaps, SkillEffect
from forest_api.skills import ItemFacts, PlantFacts, SkillSnapshot
from forest_api.visitor_models import VisitorWallet


def plant(i="p", species="oak", stage="sprout"):
    return PlantFacts(
        i,
        species,
        "standard",
        stage,
        (),
        20 * MICRO,
        "neutral",
        1,
        BehaviourDefinition(schemaVersion=1, metricMultipliers={}, gardenEffects=[]),
    )


def source(skill, id="item"):
    effects = item_catalogue.profile(skill)["effects"]
    if skill == "sporeline_surge":
        from forest_api.activity_inputs import WORKOUT_TYPES

        effects = [
            {**effects[0], "metric": "workout_minutes." + kind}
            for kind in set(WORKOUT_TYPES.values())
        ]
    return ItemFacts(id, skill, 1, skill, 1, tuple(SkillEffect.model_validate(e) for e in effects))


def snap(plants, sources):
    return SkillSnapshot(
        tuple(plants), SkillCaps.model_validate(CAPS_V1), "test", items=tuple(sources)
    )


@pytest.mark.parametrize("seed", range(20))
def test_pure_week_counts_variety_and_reproducibility(seed):
    result = shop.generate(item_catalogue.catalogue(), seed=seed)
    assert result == shop.generate(list(reversed(item_catalogue.catalogue())), seed=seed)
    assert len(set(result["rareDays"])) == 3
    assert len(set(result["epicDays"])) == 2
    assert sum(len(d["slots"]) for d in result["days"]) == 26
    seen = {"rare": [], "epic": []}
    previous = None
    for day in result["days"]:
        slots = day["slots"]
        ids = [s["item"]["id"] for s in slots]
        assert len(ids) == len(set(ids))
        common = {s["item"]["id"] for s in slots if s["slot"].startswith("common")}
        assert len(common) == 3 and common != previous
        previous = common
        for s in slots:
            assert s["item"]["rarity"] == (
                "common" if s["slot"].startswith("common") else s["slot"]
            )
            if s["slot"] in seen:
                seen[s["slot"]].append(s["item"]["id"])
    assert len(set(seen["rare"])) == 3 and len(set(seen["epic"])) == 2


@pytest.mark.parametrize("common_count", [0, 1, 2, 3])
def test_small_pools_never_duplicate_or_move_features(common_count):
    candidates = [r for r in item_catalogue.catalogue() if r["rarity"] == "common"][:common_count]
    result = shop.generate(candidates, seed=4)
    assert sum(len(d["slots"]) for d in result["days"]) == 26
    for d in result["days"]:
        filled = [s for s in d["slots"] if s["item"]]
        assert len(filled) == common_count
        assert all(s["reason"] for s in d["slots"] if not s["item"])


def test_all_overlap_counts_are_possible_and_invalid_pools_fail():
    overlap = {
        len(set(p["rareDays"]) & set(p["epicDays"]))
        for p in (shop.generate(item_catalogue.catalogue(), seed=i) for i in range(100))
    }
    assert overlap == {0, 1, 2}
    data = item_catalogue.catalogue()
    with pytest.raises(ValueError):
        shop.generate([*data, data[0]], seed=1)
    with pytest.raises(ValueError):
        shop.generate([{**data[0], "weight": 0}], seed=1)


def test_percentage_skills_use_correct_layers_and_duplicate_groups():
    plants = [plant(), plant("p2", "fern"), plant("copy", "fern", "adult")]
    skills = [source(s, s) for s in item_catalogue.SKILLS]
    skills += [source(s, s + "duplicate") for s in item_catalogue.SKILLS]
    snapshot = snap(plants, skills)
    activity, water = snapshot.growth(
        plants[0], ["steps", "active_energy_kcal", "workout_minutes.running", "flights_climbed"]
    )
    assert activity["steps"] == activity["flights_climbed"] == 1
    assert activity["active_energy_kcal"] == Fraction(105, 100)
    assert activity["workout_minutes.running"] == Fraction(104, 100)
    assert water == Fraction(102, 100)
    assert snapshot.attraction() == int(60 * MICRO * Fraction(1075, 1000))
    assert snapshot.capacity(100, 300) == 105
    assert snapshot.welcome_seconds(20) == 24
    assert len(snapshot.selected(None)) == 3
    assert all("sourceItemId" in row for row in snapshot.summary()["activeSkills"])
    assert snap(plants, []).growth(plants[0], ["steps"])[1] == 1


def test_species_cap_and_welcome_cap():
    plants = [plant(str(i), str(i)) for i in range(8)]
    assert snap(plants, [source("borrowed_wisdom")]).growth(plants[0], ["steps"])[1] == Fraction(
        105, 100
    )
    strong = source("gentle_hold")
    effect = strong.effects[0].model_copy(
        update={"magnitude": strong.effects[0].magnitude.model_copy(update={"value": "9"})}
    )
    strong = ItemFacts("i", "kite", 1, "test", 1, (effect,))
    assert snap(plants, [strong]).welcome_seconds(20) == 25


@pytest.fixture
def rotating(app, client, register, headers):
    clock = [datetime(2030, 1, 7, 12, tzinfo=UTC)]
    app.state.clock = lambda: clock[0]
    account = register()
    owner = UUID(account["profile"]["userId"])
    with app.state.database.sessions() as session:
        item_catalogue.publish(session, apply=True, clock=lambda: clock[0])
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, owner).tokens = 100000
    h = {
        **headers(),
        "X-Forest-Items": "1",
        "X-Forest-Item-Commerce": "1",
        "X-Forest-Item-Rotations": "1",
        "X-Forest-Recovery": "1",
    }
    return {
        "clock": clock,
        "owner": owner,
        "garden": UUID(account["gardenId"]),
        "plant": account["starterPlantId"],
        "headers": h,
        "client": client,
        "app": app,
    }


def summary(r):
    response = r["client"].get("/v1/me/collection", headers=r["headers"])
    assert response.status_code == 200, response.text
    return response.json()


def purchase(r, offer, *, request=None, quantity=1):
    body = {
        "requestId": str(request or uuid4()),
        "offerId": offer["offerId"],
        "offerVersion": offer["offerVersion"],
        "quantity": quantity,
    }
    return r["client"].post("/v1/me/item-purchases", headers=r["headers"], json=body)


def featured(r):
    summary(r)
    with r["app"].state.database.sessions.begin() as session:
        window = session.scalar(
            select(ShopOfferWindow)
            .where(ShopOfferWindow.purchase_limit == 1)
            .order_by(ShopOfferWindow.starts_at)
        )
        r["clock"][0] = window.starts_at + timedelta(hours=12)
    return next(o for o in summary(r)["itemOffers"] if o["rarity"] != "common")


def test_preview_publication_is_read_only_and_idempotent(app):
    now = datetime(2030, 1, 7, tzinfo=UTC)
    with app.state.database.sessions() as session:
        result = item_catalogue.publish(session, clock=lambda: now)
        assert result["items"] == 15 and not result["applied"]
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemDefinition)) == 0
    with app.state.database.sessions() as session:
        item_catalogue.publish(session, apply=True, clock=lambda: now)
        item_catalogue.publish(session, apply=True, clock=lambda: now)
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemSkillProfile)) == 8


def test_saved_week_reset_and_completed_replay(rotating):
    r = rotating
    first = summary(r)
    offer = first["itemOffers"][0]
    key = uuid4()
    paid = purchase(r, offer, request=key)
    assert paid.status_code == 200, paid.text
    boundary = datetime.fromisoformat(first["shop"]["endsAt"])
    r["clock"][0] = boundary - timedelta(microseconds=1)
    assert summary(r)["shop"]["rotationId"] == first["shop"]["rotationId"]
    r["clock"][0] = boundary
    assert summary(r)["shop"]["rotationId"] != first["shop"]["rotationId"]
    assert purchase(r, offer).json()["error"]["code"] == "stale_offer"
    assert purchase(r, offer, request=key).json() == paid.json()
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ShopWeek)) == 1
        assert session.scalar(select(func.count()).select_from(ShopDay)) == 7
        assert session.scalar(select(func.count()).select_from(ShopOfferWindow)) == 26


def test_featured_allowance_is_atomic_and_replay_does_not_spend_twice(rotating):
    r = rotating
    offer = featured(r)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: purchase(r, offer), range(2)))
    assert sorted(p.status_code for p in results) == [200, 409]
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(ShopAllowance.purchased)) == 1
    assert (
        next(o for o in summary(r)["itemOffers"] if o["offerId"] == offer["offerId"])[
            "remainingAllowance"
        ]
        == 0
    )


def test_failure_does_not_consume_allowance(rotating):
    r = rotating
    offer = featured(r)
    with r["app"].state.database.sessions.begin() as session:
        session.get(VisitorWallet, r["owner"]).tokens = 0
    assert purchase(r, offer).status_code == 409
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ShopAllowance)) == 0


def test_unattended_runner_restart_and_downtime_recovery(rotating):
    from forest_api.shop_worker import tick

    r = rotating
    r["clock"][0] += timedelta(days=6)
    assert tick(r["app"].state.database, clock=lambda: r["clock"][0])["status"] == "ready"
    with r["app"].state.database.sessions.begin() as session:
        plans = {w.week_start: w.plan for w in session.scalars(select(ShopWeek))}
        assert len(plans) == 2
    assert tick(r["app"].state.database, clock=lambda: r["clock"][0])["status"] == "ready"
    r["clock"][0] += timedelta(days=22)
    current = summary(r)
    assert current["shop"]["rotationId"] == r["clock"][0].date().isoformat()
    with r["app"].state.database.sessions.begin() as session:
        assert all(session.get(ShopWeek, week).plan == plan for week, plan in plans.items())


def test_clients_cannot_reroll_stock_and_legacy_client_requires_update(rotating, register, headers):
    r = rotating
    a = summary(r)
    register("bob", gameTimezone="America/New_York")
    b = (
        r["client"]
        .get("/v1/me/collection", headers={**headers("bob"), "X-Forest-Item-Rotations": "1"})
        .json()
    )
    assert a["itemOffers"] == b["itemOffers"]
    assert r["client"].get("/v1/me/collection", headers=headers()).status_code == 426


def edit(r, *, actions=(), item_actions=()):
    current = r["client"].get("/v1/me/garden", headers=r["headers"]).json()
    response = r["client"].post(
        "/v1/me/garden/edits",
        headers=r["headers"],
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": current["layoutVersion"],
            "catalogVersion": current["catalogVersion"],
            "actions": list(actions),
            "itemActions": list(item_actions),
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def put_harps(r, quantity=1):
    with r["app"].state.database.sessions.begin() as session:
        ids = items.grant(
            session, r["owner"], "rainharp", 1, source="test", reference="rain", quantity=quantity
        )
    edit(
        r,
        actions=[{"action": "plant", "plantId": r["plant"], "x": 2, "y": 2, "rotationDegrees": 0}],
        item_actions=[
            {"action": "place", "itemId": str(id), "x": 6 + i * 2, "y": 6, "rotationDegrees": 0}
            for i, id in enumerate(ids)
        ],
    )
    return ids


def test_morning_rain_catches_missed_midnights_once_and_duplicates_do_not_stack(rotating):
    r = rotating
    put_harps(r, 2)
    r["clock"][0] += timedelta(days=3)
    for _ in range(2):
        response = r["client"].get("/v1/me/garden", headers=r["headers"])
        assert response.status_code == 200, response.text
        assert response.json()["plants"][0]["growthMicroUnits"] == str(75 * MICRO // 10)
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(DailyItemGrant)) == 3
        assert session.get(OwnedPlant, UUID(r["plant"])).fractional_state == {}


def test_harp_store_replant_does_not_backfill_absent_days(rotating):
    r = rotating
    harp = put_harps(r)[0]
    r["clock"][0] += timedelta(days=2)
    edit(r, item_actions=[{"action": "store", "itemId": str(harp)}])
    r["clock"][0] += timedelta(days=3)
    edit(
        r,
        item_actions=[
            {"action": "place", "itemId": str(harp), "x": 6, "y": 6, "rotationDegrees": 0}
        ],
    )
    assert r["client"].get("/v1/me/garden", headers=r["headers"]).json()["plants"][0][
        "growthMicroUnits"
    ] == str(5 * MICRO)
    r["clock"][0] += timedelta(days=1)
    assert r["client"].get("/v1/me/garden", headers=r["headers"]).json()["plants"][0][
        "growthMicroUnits"
    ] == str(75 * MICRO // 10)


def test_morning_rain_clamps_maturity_and_keeps_discovery(rotating):
    r = rotating
    put_harps(r)
    with r["app"].state.database.sessions.begin() as session:
        p = session.get(OwnedPlant, UUID(r["plant"]))
        limit = (
            services.PlantPresenter(session)
            .profile("growth", p.growth_profile_id, p.growth_profile_version)
            .thresholds["adult"]
        )
        p.growth_micro_units = limit - MICRO
    r["clock"][0] += timedelta(days=3650)
    response = r["client"].get("/v1/me/garden", headers=r["headers"])
    assert response.status_code == 200, response.text
    assert response.json()["plants"][0]["growthMicroUnits"] == str(limit)
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(DailyItemGrant.awarded)) == MICRO


def test_item_skill_snapshot_tracks_placement_and_visitor_duration(rotating):
    from forest_api import visitors

    r = rotating
    with r["app"].state.database.sessions.begin() as session:
        ids = items.grant(
            session, r["owner"], "cloud-shepherds-kite", 1, source="test", reference="kite"
        )
    edit(
        r,
        item_actions=[
            {"action": "place", "itemId": str(ids[0]), "x": 6, "y": 6, "rotationDegrees": 0}
        ],
    )
    with r["app"].state.database.sessions.begin() as session:
        garden = session.get(Garden, r["garden"])
        context = visitors.create_context(session, r["app"].state.settings, garden, r["clock"][0])
        assert visitors.welcome_lifetime(context) == timedelta(seconds=24)
    edit(r, item_actions=[{"action": "store", "itemId": str(ids[0])}])
    with r["app"].state.database.sessions.begin() as session:
        assert (
            services.skill_snapshot(session, session.get(Garden, r["garden"])).welcome_seconds(20)
            == 20
        )


def test_concurrent_missing_week_is_generated_once(rotating):
    r = rotating

    def prepare(_):
        with r["app"].state.database.sessions() as session:
            return shop.ensure_current(session, lambda: r["clock"][0])

    with ThreadPoolExecutor(max_workers=4) as pool:
        assert all(pool.map(prepare, range(4)))
    with r["app"].state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ShopWeek)) == 1
        assert session.scalar(select(func.count()).select_from(ShopDay)) == 7
        assert session.scalar(select(func.count()).select_from(ShopOfferWindow)) == 26


def test_selling_and_compaction_do_not_restore_featured_allowance(rotating):
    from forest_api import recovery

    r = rotating
    offer = featured(r)
    key = uuid4()
    paid = purchase(r, offer, request=key).json()
    owned = paid["ownedItemIds"][0]
    quote = r["client"].get(f"/v1/me/items/{owned}/sale-quote", headers=r["headers"]).json()
    sold = r["client"].post(
        f"/v1/me/items/{owned}/sell",
        headers=r["headers"],
        json={
            "requestId": str(uuid4()),
            "valuationVersion": quote["valuationVersion"],
            "expectedTokens": quote["tokens"],
        },
    )
    assert sold.status_code == 200, sold.text
    assert purchase(r, offer).json()["error"]["code"] == "item_allowance_used"
    with r["app"].state.database.sessions() as session:
        recovery.maintain(session, apply=True, now=r["clock"][0] + timedelta(days=10))
    r["clock"][0] += timedelta(days=10)
    assert purchase(r, offer, request=key).json() == paid


@pytest.mark.parametrize(
    "zone,now",
    [
        ("America/New_York", datetime(2030, 3, 9, 17, tzinfo=UTC)),
        ("America/New_York", datetime(2030, 11, 2, 16, tzinfo=UTC)),
    ],
)
def test_daily_grants_use_local_midnights_across_dst(rotating, zone, now):
    from forest_api.models import User

    r = rotating
    r["clock"][0] = now
    with r["app"].state.database.sessions.begin() as session:
        session.get(User, r["owner"]).game_timezone = zone
    put_harps(r)
    r["clock"][0] += timedelta(days=2)
    result = r["client"].get("/v1/me/garden", headers=r["headers"])
    assert result.status_code == 200, result.text
    with r["app"].state.database.sessions.begin() as session:
        grants = list(session.scalars(select(DailyItemGrant).order_by(DailyItemGrant.boundary)))
        assert len(grants) == 2
        assert grants[1].boundary - grants[0].boundary == timedelta(
            hours=23 if now.month == 3 else 25
        )


def test_future_release_preserves_saved_week_and_existing_values(rotating, monkeypatch):
    r = rotating
    first = summary(r)
    rows = item_catalogue.catalogue()
    rows[0] = {**rows[0], "tokenCost": 900}
    monkeypatch.setattr(item_catalogue, "catalogue", lambda: rows)
    with r["app"].state.database.sessions.begin() as session:
        saved = session.scalar(select(ShopWeek)).plan
    with r["app"].state.database.sessions() as session:
        item_catalogue.publish(
            session,
            apply=True,
            effective_week=r["clock"][0].date() + timedelta(days=7),
            version="future-test",
            clock=lambda: r["clock"][0],
        )
    assert summary(r)["itemOffers"] == first["itemOffers"]
    r["clock"][0] += timedelta(days=7)
    summary(r)
    with r["app"].state.database.sessions.begin() as session:
        assert session.get(ShopWeek, r["clock"][0].date() - timedelta(days=7)).plan == saved
        assert session.get(ShopWeek, r["clock"][0].date()).release_version == "future-test"


def test_post_lock_acceptance_time_rejects_old_offer(rotating):
    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.errors import ApiError
    from forest_api.item_commerce import PurchaseItem
    from forest_api.item_commerce import purchase as buy

    r = rotating
    value = summary(r)
    offer = value["itemOffers"][0]
    end = datetime.fromisoformat(value["shop"]["endsAt"])
    body = PurchaseItem(requestId=uuid4(), offerId=offer["offerId"], offerVersion=1, quantity=1)
    # The injected post-lock instant models a request that arrived before reset
    # but could not acquire its account lock until exactly the boundary.
    with r["app"].state.database.sessions() as session:
        session.info.update(item_commerce_client=True, item_rotations_client=True)
        with pytest.raises(ApiError) as error:
            buy(session, r["app"].state.settings, Identity(DEV_ISSUER, "alice"), body, lambda: end)
        assert error.value.code == "stale_offer"


def test_database_rejects_unsupported_item_skills(app):
    from sqlalchemy.exc import DBAPIError

    with pytest.raises(DBAPIError):
        with app.state.database.sessions.begin() as session:
            session.add(
                ItemSkillProfile(
                    id="broken", version=1, rules={"effects": [], "dailyGrant": {"water": "100000"}}
                )
            )
            session.flush()


def test_scheduled_kite_window_and_existing_expiry_survive_exact_boundary_store(
    rotating, monkeypatch
):
    from forest_api import visitor_schedule, visitors
    from forest_api.visitor_models import VisitorOpportunity, VisitorRules, VisitorSession

    r = rotating
    with r["app"].state.database.sessions.begin() as session:
        kite = items.grant(
            session, r["owner"], "cloud-shepherds-kite", 1, source="test", reference="kite"
        )[0]
        p = session.get(OwnedPlant, UUID(r["plant"]))
        p.growth_micro_units = (
            services.PlantPresenter(session)
            .profile("growth", p.growth_profile_id, p.growth_profile_version)
            .thresholds["adult"]
        )
        old = session.scalar(select(VisitorRules).order_by(VisitorRules.effective_at.desc()))
        session.add(
            VisitorRules(
                version="scheduled-kite",
                effective_at=r["clock"][0],
                is_fixture=True,
                rules={**old.rules, "arrival_protocol": 2},
            )
        )
    edit(
        r,
        actions=[{"action": "plant", "plantId": r["plant"], "x": 2, "y": 2, "rotationDegrees": 0}],
        item_actions=[
            {"action": "place", "itemId": str(kite), "x": 6, "y": 6, "rotationDegrees": 0}
        ],
    )
    monkeypatch.setattr(visitor_schedule, "jitter", lambda: Fraction(1, 1000))
    with r["app"].state.database.sessions.begin() as session:
        garden = session.get(Garden, r["garden"])
        state, _ = visitors.settle(session, r["app"].state.settings, garden, r["clock"][0])
        active = VisitorSession(
            id=uuid4(),
            owner_id=r["owner"],
            garden_id=r["garden"],
            installation_id=uuid4(),
            started_at=r["clock"][0],
            lease_expires_at=r["clock"][0] + timedelta(seconds=45),
            arrival_protocol=2,
        )
        session.add(active)
        session.flush()
        visitor_schedule.plan(session, garden, state, active, r["clock"][0])
        opportunities = list(
            session.scalars(select(VisitorOpportunity).order_by(VisitorOpportunity.issued_at))
        )
        assert opportunities
        first = opportunities[0]
        identity, expires, issued = first.id, first.expires_at, first.issued_at
        assert expires - issued == timedelta(seconds=24)
        assert expires <= active.lease_expires_at
    r["clock"][0] = issued
    edit(r, item_actions=[{"action": "store", "itemId": str(kite)}])
    with r["app"].state.database.sessions.begin() as session:
        saved = session.get(VisitorOpportunity, identity)
        assert saved.status == "issued" and saved.expires_at == expires


def test_export_real_http_rotation_contract(rotating):
    import json
    import os
    from pathlib import Path

    r = rotating
    first = summary(r)
    ids = []
    with r["app"].state.database.sessions.begin() as session:
        for row in item_catalogue.catalogue():
            ids.extend(
                items.grant(
                    session, r["owner"], row["id"], 1, source="fixture", reference=row["id"]
                )
            )
    inventory = r["client"].get("/v1/me/items", headers=r["headers"]).json()
    edit(
        r,
        actions=[
            {"action": "plant", "plantId": r["plant"], "x": 8.8, "y": 8.8, "rotationDegrees": 0}
        ],
        item_actions=[
            {
                "action": "place",
                "itemId": str(id),
                "x": round(1.1 + (i % 4) * 2.2, 3),
                "y": round(1.1 + (i // 4) * 2.2, 3),
                "rotationDegrees": 0,
            }
            for i, id in enumerate(ids)
        ],
    )
    garden = r["client"].get("/v1/me/garden", headers=r["headers"]).json()
    assert len({e["name"] for e in garden["skillSummary"]["activeSkills"]}) == 8
    r["clock"][0] += timedelta(days=1)
    rain = r["client"].get("/v1/me/garden", headers=r["headers"]).json()
    assert rain["dailyWater"][0]["water"] == "2.5"
    if os.environ.get("FOREST_EXPORT_ITEM_ROTATIONS_CONTRACT") == "1":
        path = (
            Path(__file__).resolve().parents[2]
            / "frontend/MovementForest/Resources/Fixtures/item-rotations-contract.json"
        )
        path.write_text(
            json.dumps(
                {
                    "summary": first,
                    "inventory": inventory,
                    "garden": garden,
                    "afterDailyWater": rain,
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )


def test_release_boundary_is_utc_even_when_database_clock_has_local_offset(app):
    from zoneinfo import ZoneInfo

    local_monday = datetime(2030, 1, 7, 0, 30, tzinfo=ZoneInfo("Asia/Singapore"))
    with app.state.database.sessions() as session:
        result = item_catalogue.publish(session, clock=lambda: local_monday)
    assert result["effectiveWeek"] == "2029-12-31"


def test_future_publication_cannot_attach_a_skill_to_old_neutral_copies(rotating, monkeypatch):
    rows = item_catalogue.catalogue()
    rows[0] = {**rows[0], "skillId": "gentle_hold"}
    monkeypatch.setattr(item_catalogue, "catalogue", lambda: rows)
    with rotating["app"].state.database.sessions() as session:
        with pytest.raises(ValueError, match="new item definition version"):
            item_catalogue.publish(
                session,
                apply=True,
                version="no-retroactive-skill",
                effective_week=rotating["clock"][0].date() + timedelta(days=7),
                clock=lambda: rotating["clock"][0],
            )
