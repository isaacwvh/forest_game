"""Lazy, once-per-local-day flat water. All callers hold owner then garden locks.

Every membership mutation settles its old layout first. The durable checkpoint
therefore proves that the still-current membership covered every missed boundary;
request caches and phone uptime are never used as placement history.
"""

from datetime import UTC, datetime, timedelta
from decimal import Decimal
from zoneinfo import ZoneInfo

from sqlalchemy import func, select

from forest_api.calculations import MICRO
from forest_api.item_models import DailyItemGrant, DailyItemState, ShopRelease
from forest_api.models import GardenPlacement, OwnedPlant, PlayerProgress, User


def settle_due(session, settings, garden, now):
    from forest_api import collection, discovery, item_skills, services, visitors

    if session.info.get("settling_daily_items"):
        return
    activation = session.scalar(select(func.min(ShopRelease.published_at)))
    if activation is None or now < activation:
        return
    state = session.get(DailyItemState, garden.id)
    if state is None:
        state = DailyItemState(garden_id=garden.id, settled_at=activation)
        session.add(state)
        session.flush()
    if now <= state.settled_at:
        return
    owner = session.get(User, garden.owner_id)
    zone = ZoneInfo(owner.game_timezone)
    day = state.settled_at.astimezone(zone).date() + timedelta(days=1)
    today = now.astimezone(zone).date()
    sources = [
        (identity, profile)
        for identity, profile in item_skills.placed_profiles(session, garden)
        if profile.rules.get("dailyGrant", {}).get("family") == "morning_rain"
    ]
    if not sources or day > today:
        state.settled_at = now
        return
    plants = list(
        session.scalars(
            select(OwnedPlant)
            .join(GardenPlacement, GardenPlacement.plant_id == OwnedPlant.id)
            .where(GardenPlacement.garden_id == garden.id)
            .order_by(OwnedPlant.id)
            .with_for_update(of=OwnedPlant)
        )
    )
    presenter = services.PlantPresenter(session)
    presenter.preload(plants)
    limits = {
        p.id: presenter.profile("growth", p.growth_profile_id, p.growth_profile_version)
        for p in plants
    }
    # Published growth profiles have finite maturity. Once all recipients are
    # mature, skip the remaining (possibly years of) empty boundaries in O(1).
    session.info["settling_daily_items"] = True
    try:
        while day <= today:
            growing = [p for p in plants if p.growth_micro_units < limits[p.id].thresholds["adult"]]
            if not growing:
                break
            boundary = datetime.combine(day, datetime.min.time(), zone).astimezone(UTC)
            visitors.settle(session, settings, garden, boundary)
            changed = False
            for plant in growing:
                key = owner.id, plant.id, day, "morning_rain"
                if session.get(DailyItemGrant, key) is not None:
                    continue
                before = plant.growth_micro_units
                after = min(before + 5 * MICRO // 2, limits[plant.id].thresholds["adult"])
                plant.growth_micro_units = after
                if after == limits[plant.id].thresholds["adult"]:
                    plant.fractional_state = {}
                provenance = {
                    "version": "daily-item-water-v1",
                    "requestedMicroUnits": str(5 * MICRO // 2),
                    "beforeGrowth": str(before),
                    "afterGrowth": str(after),
                    "gameTimezone": owner.game_timezone,
                    "sources": [
                        {
                            "ownedItemId": str(i.id),
                            "itemId": i.item_id,
                            "definitionVersion": i.item_version,
                            "profileId": p.id,
                            "profileVersion": p.version,
                        }
                        for i, p in sources
                    ],
                    "growthProfileId": plant.growth_profile_id,
                    "growthProfileVersion": plant.growth_profile_version,
                }
                session.add(
                    DailyItemGrant(
                        owner_id=owner.id,
                        plant_id=plant.id,
                        game_date=day,
                        family="morning_rain",
                        awarded=after - before,
                        boundary=boundary,
                        provenance=provenance,
                    )
                )
                # Maturity/discovery are real outcomes; no steps, workout evidence,
                # gems, XP or activity-day credit is fabricated by a flat grant.
                progress = session.get(PlayerProgress, owner.id)
                if before < limits[plant.id].thresholds["seedling"] <= after and progress:
                    progress.first_seedling_at = progress.first_seedling_at or boundary
                if (
                    before < limits[plant.id].thresholds["adult"] <= after
                    and plant.first_matured_at is None
                ):
                    plant.first_matured_at = boundary
                    if progress:
                        progress.first_maturity_count = collection.checked(
                            progress.first_maturity_count + 1
                        )
                changed = True
            if changed:
                garden.state_version = collection.checked(garden.state_version + 1)
                session.flush()
                discovery.record_reached(session, owner.id, plants, boundary)
                visitors.VisitorAccounting(settings).after_change(session, garden, boundary)
            state.settled_at = boundary
            session.flush()
            day += timedelta(days=1)
        state.settled_at = now
    finally:
        session.info.pop("settling_daily_items", None)


def recent(session, owner, boundary):
    user = session.get(User, owner)
    cutoff = boundary.astimezone(ZoneInfo(user.game_timezone)).date() - timedelta(days=30)
    rows = session.execute(
        select(DailyItemGrant.game_date, func.sum(DailyItemGrant.awarded), func.count())
        .where(DailyItemGrant.owner_id == owner, DailyItemGrant.game_date >= cutoff)
        .group_by(DailyItemGrant.game_date)
        .order_by(DailyItemGrant.game_date.desc())
        .limit(7)
    )
    return [
        {
            "gameDate": day.isoformat(),
            "water": format(Decimal(amount) / MICRO, "f"),
            "plantCount": count,
        }
        for day, amount, count in rows
    ]
