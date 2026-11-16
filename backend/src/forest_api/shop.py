"""Persisted UTC rotations. Preparation never holds account or garden locks."""

import random
import secrets
from datetime import UTC, datetime, timedelta

from sqlalchemy import func, select, text

from forest_api.errors import ApiError
from forest_api.item_models import (
    ItemShopOffer,
    ShopAllowance,
    ShopDay,
    ShopOfferWindow,
    ShopRelease,
    ShopWeek,
)

LOCK = 591417020
MAX_CATCHUP_WEEKS = 8


def week_of(day):
    return day - timedelta(days=day.weekday())


def release_at(session, week):
    return session.scalar(
        select(ShopRelease)
        .where(ShopRelease.effective_week <= week)
        .order_by(ShopRelease.effective_week.desc())
        .limit(1)
    )


def generate(candidates, *, seed, previous=()):
    """Pure version-1 draws: stable identities, positive weights, ordered fallbacks."""
    rng = random.Random(seed)
    ids = [r["id"] for r in candidates]
    if len(set(ids)) != len(ids) or any(
        type(r["weight"]) is not int or r["weight"] <= 0 for r in candidates
    ):
        raise ValueError(
            "Each identity requires one pinned rarity/version and a positive integer weight"
        )
    pools = {
        rarity: sorted([r for r in candidates if r["rarity"] == rarity], key=lambda r: r["id"])
        for rarity in ("common", "rare", "epic")
    }
    rare_days, epic_days = sorted(rng.sample(range(7), 3)), sorted(rng.sample(range(7), 2))
    used = {"rare": set(), "epic": set()}
    yesterday = set(previous)
    days = []

    def draw(pool):
        roll = rng.randrange(sum(row["weight"] for row in pool))
        for row in pool:
            if roll < row["weight"]:
                return row
            roll -= row["weight"]
        raise AssertionError("Weighted draw exhausted a validated pool")

    for day in range(7):
        pool = list(pools["common"])
        chosen = []
        while pool and len(chosen) < 3:
            item = draw(pool)
            chosen.append(item)
            pool.remove(item)
        adjustment = False
        yesterday_common = yesterday & {r["id"] for r in pools["common"]}
        if len(chosen) == 3 and {r["id"] for r in chosen} == yesterday_common and pool:
            chosen[rng.randrange(3)] = draw(pool)
            adjustment = True
        slots = [
            {
                "slot": f"common_{i + 1}",
                "item": chosen[i] if i < len(chosen) else None,
                "reason": None if i < len(chosen) else "no_eligible_common",
            }
            for i in range(3)
        ]
        today = {r["id"] for r in chosen}
        for rarity, dates in (("rare", rare_days), ("epic", epic_days)):
            if day not in dates:
                continue
            pool = [r for r in pools[rarity] if r["id"] not in today]
            preferred = [r for r in pool if r["id"] not in used[rarity] | yesterday]
            fallback = "none"
            if not preferred:
                preferred = [r for r in pool if r["id"] not in used[rarity]]
                fallback = "allow_yesterday"
            if not preferred:
                preferred = [r for r in pool if r["id"] not in yesterday] or pool
                fallback = "allow_week_repeat"
            item = draw(preferred) if preferred else None
            if item:
                today.add(item["id"])
                used[rarity].add(item["id"])
            slots.append(
                {
                    "slot": rarity,
                    "item": item,
                    "reason": None if item else f"no_eligible_{rarity}",
                    "fallback": fallback,
                }
            )
        days.append({"slots": slots, "commonTrioAdjusted": adjustment})
        yesterday = today
    return {"rareDays": rare_days, "epicDays": epic_days, "days": days}


def ensure_current(session, clock=None, *, upcoming=False):
    """Commit bounded chronological recovery, then report whether target is ready."""
    with session.begin():
        now = clock() if clock else session.scalar(select(func.clock_timestamp()))
        target = week_of(now.astimezone(UTC).date())
        if upcoming and now.astimezone(UTC).weekday() == 6:
            target += timedelta(days=7)
        launch = session.scalar(select(func.min(ShopRelease.effective_week)))
        if launch is None or launch > target:
            return True
        if session.get(ShopWeek, target) is not None:
            return True
        session.execute(text(f"SELECT pg_advisory_xact_lock({LOCK})"))
        # Lock waits may cross a UTC boundary; resolve the target again.
        now = clock() if clock else session.scalar(select(func.clock_timestamp()))
        target = week_of(now.astimezone(UTC).date())
        if upcoming and now.astimezone(UTC).weekday() == 6:
            target += timedelta(days=7)
        last = session.scalar(select(func.max(ShopWeek.week_start)))
        cursor = launch if last is None else last + timedelta(days=7)
        for _ in range(MAX_CATCHUP_WEEKS):
            if cursor > target:
                break
            release = release_at(session, cursor)
            if release is None:
                raise ApiError(503, "shop_unavailable", "Historical shop policy is unavailable")
            if release.policy.get("algorithm") != 1:
                raise ApiError(503, "shop_unavailable", "This shop policy requires a server update")
            previous = session.get(ShopWeek, cursor - timedelta(days=7))
            yesterday = (
                [s["item"]["id"] for s in previous.plan["days"][-1]["slots"] if s["item"]]
                if previous
                else []
            )
            seed = secrets.token_hex(32)
            plan = generate(release.catalogue, seed=seed, previous=yesterday)
            session.add(
                ShopWeek(week_start=cursor, release_version=release.version, seed=seed, plan=plan)
            )
            session.flush()
            for i, day in enumerate(plan["days"]):
                date = cursor + timedelta(days=i)
                start = datetime.combine(date, datetime.min.time(), UTC)
                end = start + timedelta(days=1)
                session.add(
                    ShopDay(shop_date=date, week_start=cursor, starts_at=start, ends_at=end)
                )
                session.flush()
                for slot in day["slots"]:
                    item = slot["item"]
                    if item is None:
                        continue
                    offer_id = f"garden/{date.isoformat()}/{slot['slot']}"
                    session.add(
                        ItemShopOffer(
                            id=offer_id,
                            version=1,
                            item_id=item["id"],
                            item_version=item["version"],
                            token_cost=item["tokenCost"],
                            active=True,
                        )
                    )
                    session.flush()
                    session.add(
                        ShopOfferWindow(
                            offer_id=offer_id,
                            offer_version=1,
                            shop_date=date,
                            slot=slot["slot"],
                            starts_at=start,
                            ends_at=end,
                            purchase_limit=None
                            if slot["slot"].startswith("common")
                            else release.policy["featuredLimit"],
                        )
                    )
                session.flush()
            cursor += timedelta(days=7)
        return cursor > target


def active_release(session, now):
    return release_at(session, week_of(now.astimezone(UTC).date()))


def check_client(session):
    if not session.info.get("item_rotations_client"):
        raise ApiError(
            426, "item_content_update_required", "Update the app for the new garden items"
        )


def current(session, owner, now):
    if active_release(session, now) is None:
        return None
    check_client(session)
    day = session.get(ShopDay, now.astimezone(UTC).date())
    if day is None or not day.starts_at <= now < day.ends_at:
        raise ApiError(503, "shop_preparing", "Shop is preparing. Please retry shortly")
    return {
        "serverNow": now.isoformat(),
        "shopTimezone": "UTC",
        "rotationId": day.shop_date.isoformat(),
        "startsAt": day.starts_at.isoformat(),
        "endsAt": day.ends_at.isoformat(),
    }


def validate_purchase(session, owner, offer, quantity, now):
    window = session.get(ShopOfferWindow, (offer.id, offer.version))
    if window is None:
        if active_release(session, now):
            raise ApiError(409, "stale_offer", "Refresh Shop to see the current offer")
        return None
    check_client(session)
    if not window.starts_at <= now < window.ends_at:
        raise ApiError(409, "stale_offer", "This offer has expired. Refresh Shop")
    usage = session.get(ShopAllowance, (owner, offer.id, offer.version))
    if (
        window.purchase_limit is not None
        and (usage.purchased if usage else 0) + quantity > window.purchase_limit
    ):
        raise ApiError(409, "item_allowance_used", "This featured item has already been purchased")
    return window


def consume(session, owner, window, quantity):
    if window is None or window.purchase_limit is None:
        return
    key = owner, window.offer_id, window.offer_version
    usage = session.get(ShopAllowance, key)
    if usage:
        usage.purchased += quantity
    else:
        session.add(
            ShopAllowance(owner_id=owner, offer_id=key[1], offer_version=key[2], purchased=quantity)
        )


def preview(session, week):
    with session.begin():
        saved = session.get(ShopWeek, week)
        if saved is None:
            return {"saved": False, "week": week.isoformat()}
        rotations = []
        for day in session.scalars(
            select(ShopDay).where(ShopDay.week_start == week).order_by(ShopDay.shop_date)
        ):
            offers = session.execute(
                select(ShopOfferWindow, ItemShopOffer)
                .join(
                    ItemShopOffer,
                    (ItemShopOffer.id == ShopOfferWindow.offer_id)
                    & (ItemShopOffer.version == ShopOfferWindow.offer_version),
                )
                .where(ShopOfferWindow.shop_date == day.shop_date)
                .order_by(ShopOfferWindow.slot)
            )
            rotations.append(
                {
                    "rotationId": day.shop_date.isoformat(),
                    "startsAt": day.starts_at.isoformat(),
                    "endsAt": day.ends_at.isoformat(),
                    "offers": [
                        {
                            "offerId": offer.id,
                            "offerVersion": offer.version,
                            "slot": window.slot,
                            "itemId": offer.item_id,
                            "definitionVersion": offer.item_version,
                            "tokenCost": str(offer.token_cost),
                            "purchaseLimit": window.purchase_limit,
                        }
                        for window, offer in offers
                    ],
                }
            )
        return {
            "saved": True,
            "week": week.isoformat(),
            "release": saved.release_version,
            "plan": saved.plan,
            "rotations": rotations,
        }
