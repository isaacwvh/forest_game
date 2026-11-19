"""UTC recurrence and transactional action observers. Callers own account/garden locks."""

from copy import deepcopy
from datetime import UTC, datetime, timedelta
from uuid import NAMESPACE_URL, uuid5

from sqlalchemy import select, text

from forest_api import collection, services
from forest_api.expedition_definitions import QUESTS, VERSION, definition
from forest_api.expedition_models import (
    ExpeditionClaim,
    ExpeditionEntitlement,
    ExpeditionRun,
    ExpeditionSchedule,
    ExpeditionTemplate,
)


def month_start(now):
    return now.astimezone(UTC).replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def next_month(start):
    return (start.replace(day=28) + timedelta(days=4)).replace(day=1)


def run_for(session, owner, boundary):
    session.execute(text("SELECT pg_advisory_xact_lock_shared(591417021)"))
    start = month_start(boundary)
    schedule = session.scalar(
        select(ExpeditionSchedule)
        .where(ExpeditionSchedule.month <= start.date())
        .order_by(ExpeditionSchedule.month.desc())
        .limit(1)
    )
    if schedule is None:
        return None
    identifier = uuid5(NAMESPACE_URL, f"forest/expedition/{owner}/{start.date()}")
    run = session.get(ExpeditionRun, identifier)
    if run is None:
        end = next_month(start)
        run = ExpeditionRun(
            id=identifier,
            owner_id=owner,
            month=start.date(),
            template_version=schedule.template_version,
            starts_at=start,
            ends_at=end,
            evidence_until=end + timedelta(days=7),
            progress_version=0,
            progress={},
            contributions={},
        )
        session.add(run)
        session.flush()
    return run


def content(session, run):
    return session.get(ExpeditionTemplate, run.template_version).definition


def set_progress(session, run, key, value, boundary):
    definitions = content(session, run)
    quest = next(q for q in definitions["quests"] if q["id"] == key)
    progress = deepcopy(run.progress)
    old = progress.get(key, {"current": 0, "completedAt": None})
    if old["completedAt"]:
        return
    value = min(quest["target"], max(0, value))
    if old["current"] == value:
        return
    completed = boundary.isoformat() if value == quest["target"] else None
    progress[key] = {"current": value, "completedAt": completed}
    run.progress = progress
    run.progress_version = collection.checked(run.progress_version + 1)
    if completed:
        earn(session, run, "quest:" + key, quest["reward"], boundary)
    count = sum(bool(p["completedAt"]) for p in progress.values())
    for milestone in definitions["milestones"]:
        if count >= milestone["count"]:
            earn(
                session, run, "milestone:" + str(milestone["count"]), milestone["reward"], boundary
            )
    session.flush()


def earn(session, run, key, reward, boundary):
    identifier = uuid5(run.id, key)
    if session.get(ExpeditionEntitlement, identifier) is None:
        session.add(
            ExpeditionEntitlement(
                id=identifier,
                run_id=run.id,
                reward_key=key,
                earned_at=boundary,
                reward=deepcopy(reward),
            )
        )
        session.flush()


def contribution(session, run, key, identity, boundary):
    values = deepcopy(run.contributions)
    seen = values.setdefault(key, [])
    target = next(q["target"] for q in content(session, run)["quests"] if q["id"] == key)
    if len(seen) >= target or str(identity) in seen:
        return
    seen.append(str(identity))
    run.contributions = values
    set_progress(session, run, key, len(seen), boundary)


def garden_facts(session, garden, run):
    from forest_api.item_models import ItemPlacement
    from forest_api.models import GardenPlacement, OwnedPlant

    plants = list(
        session.scalars(
            select(OwnedPlant)
            .join(GardenPlacement, GardenPlacement.plant_id == OwnedPlant.id)
            .where(GardenPlacement.garden_id == garden.id)
            .order_by(OwnedPlant.id)
        )
    )
    presenter = services.PlantPresenter(session)
    presenter.preload(plants)
    stages = {p.id: presenter.plant(p, None).growth_stage for p in plants}
    tags = content(session, run)["tags"]
    trees = {p.id for p in plants if "tree" in tags.get(p.species_id, [])}
    herbs = {p.id for p in plants if "herb" in tags.get(p.species_id, [])}
    items = list(
        session.scalars(select(ItemPlacement.item_id).where(ItemPlacement.garden_id == garden.id))
    )
    return stages, items, any(t != h for t in trees for h in herbs)


def observe_garden(session, garden, boundary, *, before=None):
    run = run_for(session, garden.owner_id, boundary)
    if run is None or not run.starts_at <= boundary < run.ends_at:
        return
    stages, items, _ = garden_facts(session, garden, run)
    set_progress(session, run, "items_together_4", len(items), boundary)
    set_progress(session, run, "all_stages_together", len(set(stages.values())), boundary)
    order = {s: i for i, s in enumerate(("sprout", "seedling", "young", "adult"))}
    for identifier, previous in (before or {}).items():
        if identifier in stages and order[stages[identifier]] > order[previous]:
            contribution(session, run, "copies_advanced_4", identifier, boundary)


def observe_welcome(session, garden, boundary, identity):
    run = run_for(session, garden.owner_id, boundary)
    if run is None:
        return
    contribution(session, run, "active_butterflies_100", identity, boundary)
    if garden_facts(session, garden, run)[2]:
        contribution(session, run, "tree_herb_butterflies_50", identity, boundary)


def observe_opening(session, owner, boundary, identity):
    run = run_for(session, owner, boundary)
    if run is not None:
        contribution(session, run, "packs_opened_3", identity, boundary)


def present(session, run, now, *, retry_older=False):
    from forest_api.expedition_evidence import coverage

    data = content(session, run)
    entitlements = list(
        session.scalars(select(ExpeditionEntitlement).where(ExpeditionEntitlement.run_id == run.id))
    )
    claimed = {
        c.entitlement_id
        for c in session.scalars(
            select(ExpeditionClaim).where(
                ExpeditionClaim.entitlement_id.in_([e.id for e in entitlements])
            )
        )
    }
    rewards = [
        {"id": str(e.id), "rewardKey": e.reward_key, "reward": e.reward, "claimed": e.id in claimed}
        for e in entitlements
    ]
    by_key = {e["rewardKey"]: e for e in rewards}
    quests = [
        {
            **q,
            **run.progress.get(q["id"], {"current": 0, "completedAt": None}),
            "entitlement": by_key.get("quest:" + q["id"]),
        }
        for q in data["quests"]
    ]
    return {
        "runId": str(run.id),
        "month": run.month.isoformat(),
        "templateVersion": run.template_version,
        "name": data["name"],
        "timezone": "UTC",
        "serverNow": now.astimezone(UTC).isoformat(),
        "startsAt": run.starts_at.astimezone(UTC).isoformat(),
        "endsAt": run.ends_at.astimezone(UTC).isoformat(),
        "evidenceUntil": run.evidence_until.astimezone(UTC).isoformat(),
        "progressVersion": run.progress_version,
        "completedCount": sum(bool(q["completedAt"]) for q in quests),
        "artworkKey": data["artworkKey"],
        "quests": quests,
        "rewards": rewards,
        "coverage": coverage(session, run, now, retry_older=retry_older),
    }


def publish(session, settings, month, *, apply=False, clock=None, replacement=None):
    """Publish one recurring assignment; subsequent months need no manual operation."""
    from forest_api.expedition_items import publish_items
    from forest_api.models import AttractionProfile, Species
    from forest_api.placement import utc_now

    with session.begin():
        session.execute(text("SELECT pg_advisory_xact_lock(591417021)"))
        now = (clock or utc_now)()
        if month.day != 1:
            raise ValueError("Select the first day of a UTC calendar month")
        existing = session.get(ExpeditionSchedule, month)
        if existing is None and datetime.combine(month, datetime.min.time(), UTC) <= now:
            raise ValueError(
                "Schedule before 00:00 UTC on the first; retrospective publication is forbidden"
            )
        publish_items(session)
        collection.pack_contract(session, settings, "woodland", 20)
        tags = {}
        for species in session.scalars(select(Species)):
            profile = session.get(
                AttractionProfile,
                (species.attraction_profile_id, species.attraction_profile_version),
            )
            tags[species.id] = list(profile.gameplay_tags)
        version = replacement["version"] if replacement else VERSION
        data = deepcopy(replacement["definition"]) if replacement else definition(tags)
        data["tags"] = tags
        from forest_api.expedition_content import validate_content

        validate_content(session, settings, version, data)
        template = session.get(ExpeditionTemplate, version)
        if template is None:
            session.add(ExpeditionTemplate(version=version, definition=data, published_at=now))
            session.flush()
        elif replacement and template.definition != data:
            raise ValueError("Published expedition templates are immutable")
        # A repeat must use pinned published tags, not today's expanded catalogue.
        if existing is not None and existing.template_version != version:
            raise ValueError("Month assignments are immutable")
        if existing is None:
            session.add(ExpeditionSchedule(month=month, template_version=version, published_at=now))
        result = {
            "applied": apply,
            "month": month.isoformat(),
            "timezone": "UTC",
            "template": version,
            "recursMonthly": True,
            "quests": len(QUESTS),
            "items": sorted(
                {
                    r["itemId"]
                    for r in [q["reward"] for q in data["quests"]]
                    + [m["reward"] for m in data["milestones"]]
                    if "itemId" in r
                }
            ),
            "resalePolicy": "unavailable",
            "tokens": sum(
                q["reward"].get("tokens", 0) for q in data["quests"] + data["milestones"]
            ),
            "gems": sum(q["reward"].get("gems", 0) for q in data["quests"] + data["milestones"]),
            "packQuantity": sum(
                "packId" in q["reward"] for q in data["quests"] + data["milestones"]
            ),
        }
        session.flush()
        if (
            existing is None
            and datetime.combine(month, datetime.min.time(), UTC) <= (clock or utc_now)()
        ):
            raise ValueError("Publication crossed the UTC start; select a future month")
        if not apply:
            session.rollback()
        return result
