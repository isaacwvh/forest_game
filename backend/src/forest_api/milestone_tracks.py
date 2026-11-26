"""Server-authoritative tracks. All observers run inside the existing owner transaction."""

import re
from collections import Counter
from copy import deepcopy
from datetime import datetime, timedelta
from fractions import Fraction
from uuid import NAMESPACE_URL, uuid4, uuid5
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import load_only
from sqlalchemy.orm.attributes import set_committed_value

from forest_api import collection, services
from forest_api import milestone_definitions as config
from forest_api.activity_models import MilestoneClaim
from forest_api.collection_models import CollectionEvent, OwnedPack
from forest_api.errors import ApiError
from forest_api.milestone_models import (
    MilestoneBonusGrant,
    MilestoneDay,
    MilestoneEntitlement,
    MilestoneEvent,
    MilestoneEventState,
    MilestonePolicy,
    MilestoneSpecies,
    MilestoneState,
)
from forest_api.models import CatalogStageDiscovery, PlayerProgress, Species, User
from forest_api.visitor_models import VisitorRewardEvent, VisitorWalletEntry

LEGACY = {
    "first_movement": "steps_1000",
    "first_hosted": "butterfly_1",
    "three_hosted": "butterfly_3",
    "first_seedling": "growth_first_seedling",
    "first_maturity": "growth_mature_1",
}


def policy(session):
    query = select(MilestonePolicy).where(MilestonePolicy.active)
    cache = session.info.get("milestone_policy_cache")
    if cache is None or session.info["settings"].catalogue_cache_seconds <= 0:
        return session.scalar(query)
    # Check the active version in SQL. The schema makes the definition immutable
    # for that version, even when the active flag changes.
    published = session.scalar(
        query.options(
            load_only(MilestonePolicy.version, MilestonePolicy.effective_at, MilestonePolicy.active)
        )
    )
    if published is None:
        return None
    cached = cache.get(published.version)
    if cached is not None:
        set_committed_value(published, "definition", cached)
    elif session.get_nested_transaction() is None:
        # Promote only after the transaction commits, so a rolled-back version
        # can never supply the definition for a later publication.
        session.info["milestone_policy_to_cache"] = (published.version, published.definition)
    return published


def enroll(session, owner, published, boundary):
    state = session.get(MilestoneState, owner)
    if state is not None:
        return state
    state = MilestoneState(
        owner_id=owner,
        policy_version=published.version,
        enrolled_at=published.effective_at,
        progress={},
    )
    session.add(state)
    session.flush()
    by_id = {d["milestoneId"]: d for d in published.definition["quests"]}
    legacy = list(session.scalars(select(MilestoneClaim).where(MilestoneClaim.owner_id == owner)))
    mappings = [
        (LEGACY[c.milestone_id], c.milestone_id) for c in legacy if c.milestone_id in LEGACY
    ]
    # Existing introductory awards remain spent/owned as-is. Never stack a full new opening.
    if legacy:
        mappings.append(("steps_new_beginnings", legacy[0].milestone_id))
    for key, old in mappings:
        session.add(
            MilestoneEntitlement(
                owner_id=owner,
                milestone_id=key,
                policy_version=published.version,
                earned_at=boundary,
                definition=deepcopy(by_id[key]),
                legacy_id=old,
            )
        )
    session.flush()
    return state


def discover(session, owner, published):
    # Permanent acquisition records include sold copies; variants collapse to species.
    ids = list(
        session.scalars(
            select(CatalogStageDiscovery.species_id)
            .where(CatalogStageDiscovery.owner_id == owner)
            .distinct()
        )
    )
    rarities = published.definition["species"]
    rows = [dict(owner_id=owner, species_id=s, rarity=rarities[s]) for s in ids if s in rarities]
    if rows:
        session.execute(insert(MilestoneSpecies).values(rows).on_conflict_do_nothing())


def metrics(session, owner, wallet, state):
    progress = session.get(PlayerProgress, owner)
    counts = dict(
        session.execute(
            select(MilestoneSpecies.rarity, func.count())
            .where(MilestoneSpecies.owner_id == owner)
            .group_by(MilestoneSpecies.rarity)
        ).all()
    )
    return {
        **state.progress,
        "opening": 1,
        "steps": progress.activity_steps if progress else 0,
        "butterflies": wallet.hosted_active + wallet.hosted_offline,
        "seedling": int(bool(progress and progress.first_seedling_at)),
        "maturity": progress.first_maturity_count if progress else 0,
        **{f"discovery_{r}": n for r, n in counts.items()},
    }


def earn(session, owner, published, definitions, values, boundary):
    existing = {
        e.milestone_id: e
        for e in session.scalars(
            select(MilestoneEntitlement).where(MilestoneEntitlement.owner_id == owner)
        )
    }
    for item in definitions:
        key = item["milestoneId"]
        if key not in existing and Fraction(values.get(item["metric"], 0)) >= item["threshold"]:
            entitlement = MilestoneEntitlement(
                owner_id=owner,
                milestone_id=key,
                policy_version=published.version,
                earned_at=boundary,
                definition=deepcopy(item),
            )
            if (
                key == "special_run_5km"
                and values.get("first_run_5") == values.get("first_run_10")
                and values.get("first_run_10")
            ):
                entitlement.superseded_by = "special_run_10km"
            session.add(entitlement)
            existing[key] = entitlement
    session.flush()


def refresh(session, owner, boundary):
    published = policy(session)
    if published is None or boundary < published.effective_at:
        return None
    state = enroll(session, owner, published, boundary)
    discover(session, owner, published)
    values = metrics(session, owner, collection.wallet_for(session, owner), state)
    earn(session, owner, published, published.definition["quests"], values, boundary)
    return published, state, values


def event_rows(session, boundary):
    return list(
        session.scalars(
            select(MilestoneEvent).where(
                MilestoneEvent.starts_at <= boundary, MilestoneEvent.ends_at > boundary
            )
        )
    )


def event_progress(session, owner, event):
    state = session.get(MilestoneEventState, (owner, event.event_id))
    if state is None:
        state = MilestoneEventState(owner_id=owner, event_id=event.event_id, progress={})
        session.add(state)
        session.flush()
    return state


def observe_activity(session, owner, boundary, days, *, grew_sprout=False):
    refreshed = refresh(session, owner, boundary)
    if refreshed is None:
        return
    published, state, _ = refreshed
    user = session.get(User, owner)
    start_date = state.enrolled_at.astimezone(ZoneInfo(user.game_timezone)).date()
    facts = dict(state.progress)
    for day in days:
        if day.game_date < start_date:
            continue
        key = (owner, day.game_date)
        row = session.get(MilestoneDay, key)
        if row is None:
            row = MilestoneDay(
                owner_id=owner, game_date=day.game_date, steps=0, workout_minutes="0", active=False
            )
            session.add(row)
        row.steps = collection.checked(row.steps + day.newly_eligible_steps)
        minutes = sum(
            (
                Fraction(v["newlyEligible"])
                for k, v in day.metrics.items()
                if k.startswith("workout_minutes.")
            ),
            Fraction(0),
        )
        row.workout_minutes = str(Fraction(row.workout_minutes) + minutes)
        facts["daily_steps"] = max(facts.get("daily_steps", 0), row.steps)
        if not row.active and (row.steps >= 1000 or Fraction(row.workout_minutes) >= 10):
            row.active = True
            facts["activity_days"] = collection.checked(facts.get("activity_days", 0) + 1)
        session.flush()
        # Evaluate every possible 14-day window containing this changed date. Includes
        # late reconciliations without scanning the account's entire activity history.
        dates = list(
            session.scalars(
                select(MilestoneDay.game_date).where(
                    MilestoneDay.owner_id == owner,
                    MilestoneDay.active,
                    MilestoneDay.game_date >= day.game_date - timedelta(days=13),
                    MilestoneDay.game_date <= day.game_date + timedelta(days=13),
                )
            )
        )
        best = max((sum(d <= x < d + timedelta(days=14) for x in dates) for d in dates), default=0)
        facts["rolling_days"] = max(facts.get("rolling_days", 0), best)
    state.progress = facts
    for event in event_rows(session, boundary):
        event_state = event_progress(session, owner, event)
        values = dict(event_state.progress)
        event_days = deepcopy(values.get("days", {}))
        for day in days:
            if day.game_date < event.starts_at.astimezone(ZoneInfo(user.game_timezone)).date():
                continue
            fact = event_days.setdefault(day.game_date.isoformat(), {"steps": 0, "minutes": "0"})
            fact["steps"] += day.newly_eligible_steps
            minutes = sum(
                (
                    Fraction(v["newlyEligible"])
                    for k, v in day.metrics.items()
                    if k.startswith("workout_minutes.")
                ),
                Fraction(0),
            )
            fact["minutes"] = str(Fraction(fact["minutes"]) + minutes)
        values.update(
            days=event_days,
            activity_days=sum(
                d["steps"] >= 1000 or Fraction(d["minutes"]) >= 10 for d in event_days.values()
            ),
        )
        if grew_sprout:
            values["growth"] = 1
        event_state.progress = values
        earn(session, owner, published, event.definition["quests"], values, boundary)
    session.flush()
    refresh(session, owner, boundary)


def observe_workout(session, owner, workout, boundary, earliest, awarded):
    published = policy(session)
    if published is None or workout.start < max(earliest, published.effective_at):
        return
    state = enroll(session, owner, published, boundary)
    if awarded <= 0:
        return
    facts = dict(state.progress)
    # This is pause-, overlap- and enrollment-adjusted active time before the growth cap.
    facts["workout_minutes"] = str(max(Fraction(facts.get("workout_minutes", "0")), awarded))
    segments = workout.segments if workout.has_segments else [workout]
    running = (
        workout.original_type == 37
        and bool(segments)
        and all(s.original_type == 37 for s in segments)
    )
    # Do not infer whole-workout distance from clipped, paused/unsupported segments.
    if running and workout.distance_metres is not None:
        active_minutes = Fraction(sum(s.duration_milliseconds for s in segments), 60000)
        if awarded >= active_minutes and active_minutes > 0:
            metres = Fraction(workout.distance_metres)
            facts["running_metres"] = str(max(Fraction(facts.get("running_metres", "0")), metres))
            if metres >= 5000:
                facts.setdefault("first_run_5", str(workout.workout_id))
            if metres >= 10000:
                facts.setdefault("first_run_10", str(workout.workout_id))
    state.progress = facts
    session.flush()


def observe_visitors(session, owner, boundary, visits):
    refreshed = refresh(session, owner, boundary)
    if refreshed is None or not visits:
        return
    published, _, _ = refreshed
    for event in event_rows(session, boundary):
        state = event_progress(session, owner, event)
        values = dict(state.progress)
        values["butterflies"] = collection.checked(values.get("butterflies", 0) + visits)
        state.progress = values
        earn(session, owner, published, event.definition["quests"], values, boundary)


def summary(session, owner, wallet, boundary):
    refreshed = refresh(session, owner, boundary)
    if refreshed is None:
        return []
    published, _, values = refreshed
    definitions = list(published.definition["quests"])
    event_values = {}
    # Earned event entitlements survive the earning deadline and remain visible.
    event_ids = set(
        session.scalars(
            select(MilestoneEventState.event_id).where(MilestoneEventState.owner_id == owner)
        )
    )
    events = list(
        session.scalars(
            select(MilestoneEvent).where(
                (MilestoneEvent.event_id.in_(event_ids))
                | ((MilestoneEvent.starts_at <= boundary) & (MilestoneEvent.ends_at > boundary))
            )
        )
    )
    for event in events:
        state = session.get(MilestoneEventState, (owner, event.event_id))
        event_values[event.event_id] = state.progress if state else {}
        for item in event.definition["quests"]:
            definitions.append(
                {
                    **item,
                    "eventName": event.name,
                    "startsAt": event.starts_at.isoformat(),
                    "endsAt": event.ends_at.isoformat(),
                    "claimUntil": event.claim_until.isoformat(),
                }
            )
    entitlements = {
        e.milestone_id: e
        for e in session.scalars(
            select(MilestoneEntitlement).where(MilestoneEntitlement.owner_id == owner)
        )
    }
    claims = set(
        session.scalars(select(MilestoneClaim.milestone_id).where(MilestoneClaim.owner_id == owner))
    )
    result = []
    for item in definitions:
        key = item["milestoneId"]
        entitlement = entitlements.get(key)
        event_id = item.get("eventId")
        if event_id and boundary >= datetime.fromisoformat(item["endsAt"]) and not entitlement:
            continue
        progress = (event_values.get(event_id, {}) if event_id else values).get(item["metric"], 0)
        claimed = key in claims or bool(entitlement and entitlement.legacy_id)
        superseded = entitlement.superseded_by if entitlement else None
        claim_expired = bool(event_id and boundary >= datetime.fromisoformat(item["claimUntil"]))
        # Frozen reward fields always override current policy fields once earned.
        entry = {
            **item,
            **(entitlement.definition if entitlement else {}),
            "description": item["title"],
            "policyVersion": published.version,
            "progress": str(progress),
            "eligible": bool(entitlement) and not claimed and not superseded and not claim_expired,
            "claimed": claimed,
            "supersededBy": superseded,
            "legacyMilestoneId": entitlement.legacy_id if entitlement else None,
            "unavailableReason": "Event claim period ended. Your earned reward is retained."
            if claim_expired and not claimed
            else None,
            "earnedAt": entitlement.earned_at.isoformat() if entitlement else None,
        }
        result.append(entry)
    return result


def claim(session, settings, user, milestone_id, body, boundary, operation, digest):
    refreshed = refresh(session, user.id, boundary)
    if refreshed is None:
        raise ApiError(404, "milestone_not_found", "This milestone is not available")
    entry = next(
        (
            x
            for x in summary(session, user.id, collection.wallet_for(session, user.id), boundary)
            if x["milestoneId"] == milestone_id
        ),
        None,
    )
    if entry is None:
        raise ApiError(404, "milestone_not_found", "This milestone is not available")
    if not entry["eligible"]:
        raise ApiError(
            409,
            "milestone_not_ready",
            entry.get("unavailableReason") or "This milestone is incomplete or already fulfilled",
        )
    if session.info.get("milestones_client") != "1":
        raise ApiError(
            426, "milestones_client_update_required", "Update the app to claim this reward"
        )
    from forest_api.inventory_management import capacity

    pack_count = sum(p["quantity"] for p in entry["rewardPacks"])
    room = capacity(session, user.id, settings)
    if room["unopenedPacks"] + pack_count > room["packLimit"]:
        raise ApiError(409, "pack_capacity_exceeded", "Pack storage full. Open a pack, then retry.")
    for pack in entry["rewardPacks"]:
        collection.pack_contract(session, settings, pack["packId"], pack["version"])
    wallet = collection.wallet_for(session, user.id)
    tokens, gems = int(entry["rewardTokens"]), int(entry["rewardGems"])
    new_tokens = collection.checked(wallet.tokens + tokens)
    new_gems = collection.checked(wallet.gems + gems)
    new_earned = collection.checked(wallet.lifetime_gems_earned + gems)
    event_id = uuid4()
    session.add(
        VisitorRewardEvent(
            id=event_id,
            owner_id=user.id,
            kind="milestone",
            source_id=uuid5(NAMESPACE_URL, f"{user.id}/{milestone_id}"),
            created_at=boundary,
            detail={"milestoneId": milestone_id, "tokens": str(tokens), "gems": str(gems)},
        )
    )
    session.flush()
    if tokens:
        session.add(
            VisitorWalletEntry(
                id=uuid4(), owner_id=user.id, event_id=event_id, amount=tokens, created_at=boundary
            )
        )
    if gems:
        session.add(
            MilestoneBonusGrant(
                owner_id=user.id, milestone_id=milestone_id, amount=gems, created_at=boundary
            )
        )
    wallet.tokens, wallet.gems, wallet.lifetime_gems_earned = new_tokens, new_gems, new_earned
    wallet.economy_version = collection.checked(wallet.economy_version + 1)
    # OwnedPack retains its established collection-event FK; zero spending records the grant.
    grant_id = uuid4()
    grant = CollectionEvent(
        id=grant_id,
        owner_id=user.id,
        request_id=body.request_id,
        operation=operation,
        payload_hash=digest,
        token_delta=0,
        gem_delta=0,
        receipt={},
        created_at=boundary,
    )
    packs = []
    owned_packs = []
    for reward in entry["rewardPacks"]:
        for _ in range(reward["quantity"]):
            pack = OwnedPack(
                id=uuid4(),
                owner_id=user.id,
                pack_id=reward["packId"],
                pack_version=reward["version"],
                exchange_id=grant_id,
                acquired_at=boundary,
            )
            owned_packs.append(pack)
            packs.append(collection.pack_dto(pack))
    resulting_capacity = {**room, "unopenedPacks": room["unopenedPacks"] + pack_count}
    lower_run = session.get(MilestoneEntitlement, (user.id, "special_run_5km"))
    receipt = {
        "requestId": str(body.request_id),
        "milestoneId": milestone_id,
        "milestoneEventId": str(event_id),
        "tokensEarned": str(tokens),
        "gemsEarned": str(gems),
        "packs": packs,
        "claimedAt": boundary.isoformat(),
        "policyVersion": entry["policyVersion"],
        "supersededMilestoneIds": ["special_run_5km"]
        if milestone_id == "special_run_10km" and lower_run and lower_run.superseded_by
        else [],
        "capacity": resulting_capacity,
        **collection.wallet_dto(wallet),
    }
    grant.receipt = receipt
    session.add(grant)
    session.flush()
    session.add_all(owned_packs)
    session.add(
        MilestoneClaim(
            owner_id=user.id,
            milestone_id=milestone_id,
            claimed_at=boundary,
            reward_tokens=tokens,
            receipt=receipt,
        )
    )
    services.record_request(session, user.id, body, operation, digest, receipt)
    return receipt


def activate(session, settings, *, apply=False, clock=None):
    """Explicit policy publication. Existing account mapping is lazy and repeat-safe."""
    with session.begin():
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        if existing := session.get(MilestonePolicy, config.VERSION):
            return {"alreadyPublished": True, "version": existing.version, "applied": False}
        from forest_api.visitor_models import VisitorWallet

        uninitialized = session.scalar(
            select(User.id)
            .outerjoin(VisitorWallet)
            .where(VisitorWallet.owner_id.is_(None) | ~VisitorWallet.progression_initialized)
            .limit(1)
        )
        if uninitialized is not None:
            raise ValueError("Run backfill-progression before activating milestone bonus gems")
        species = dict(
            session.execute(
                select(Species.id, Species.rarity).where(Species.enabled, ~Species.is_fixture)
            ).all()
        )
        if dict(Counter(species.values())) != config.RARITY_COUNTS:
            raise ValueError("Milestones require the published 10/10/7/3 Woodland catalogue")
        for pack in ("woodland", "select-woodland", "premium-woodland"):
            row, _ = collection.pack_contract(session, settings, pack, config.PACK_VERSION)
            if row.is_fixture:
                raise ValueError("Milestone reward packs must be published, nonfixture contracts")
        boundary = clock() if clock else session.scalar(select(func.clock_timestamp()))
        claims = dict(
            session.execute(
                select(MilestoneClaim.milestone_id, func.count()).group_by(
                    MilestoneClaim.milestone_id
                )
            ).all()
        )
        definition = {
            "quests": config.definitions(),
            "species": species,
            "legacyMapping": LEGACY,
            "openingAlternative": "steps_only",
            "activityDay": "1000_steps_or_10_workout_minutes",
            "runningOverlap": "first_10km_replaces_5km",
            "cosmetics": [],
        }
        if apply:
            session.add(
                MilestonePolicy(
                    version=config.VERSION,
                    effective_at=boundary,
                    active=True,
                    definition=definition,
                )
            )
        return {
            "version": config.VERSION,
            "catalogue": catalogue.version,
            "applied": apply,
            "quests": len(definition["quests"]),
            "legacyClaims": claims,
            "legacyMapping": LEGACY,
            "supplementalGrants": [],
            "existingOpening": "New Beginnings fulfilled if any legacy claim exists",
            "decisions": {k: v for k, v in definition.items() if k not in ("quests", "species")},
        }


def backfill(session, *, apply=False, limit=500, clock=None):
    if not 1 <= limit <= 5000:
        raise ValueError("Limit must be between 1 and 5000")
    with session.begin():
        published = policy(session)
        if published is None:
            raise ValueError("Activate a milestone policy first")
        owners = list(
            session.scalars(
                select(User.id)
                .outerjoin(MilestoneState)
                .where(MilestoneState.owner_id.is_(None))
                .order_by(User.id)
                .limit(limit + 1)
            )
        )
        boundary = clock() if clock else session.scalar(select(func.clock_timestamp()))
        preview = []
        for owner in owners[:limit]:
            session.scalar(select(User).where(User.id == owner).with_for_update())
            refresh(session, owner, boundary)
            entitlements = list(
                session.scalars(
                    select(MilestoneEntitlement)
                    .where(MilestoneEntitlement.owner_id == owner)
                    .order_by(MilestoneEntitlement.milestone_id)
                )
            )
            preview.append(
                {
                    "ownerId": str(owner),
                    "entitlements": [
                        {
                            "milestoneId": e.milestone_id,
                            "legacyMilestoneId": e.legacy_id,
                            "supersededBy": e.superseded_by,
                            "rewardTokens": e.definition["rewardTokens"],
                            "rewardGems": e.definition["rewardGems"],
                            "rewardPacks": e.definition["rewardPacks"],
                        }
                        for e in entitlements
                    ],
                }
            )
        result = {
            "accounts": len(owners[:limit]),
            "hasMore": len(owners) > limit,
            "applied": apply,
            "granted": False,
            "preview": preview,
        }
        if not apply:
            session.rollback()
        return result


def schedule_event(
    session, *, event_id, name, starts_at, ends_at, claim_until, attribution, apply=False
):
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,31}", event_id) or not name.strip() or len(name) > 100:
        raise ValueError("Use a stable event ID and a nonempty name of at most 100 characters")
    if any(t.tzinfo is None for t in (starts_at, ends_at, claim_until)):
        raise ValueError("Event timestamps require offsets")
    if not starts_at < ends_at <= claim_until or ends_at - starts_at > timedelta(days=90):
        raise ValueError("Events require start < end <= claim deadline and at most 90 earning days")
    if attribution != "collection_time":
        raise ValueError(
            "Explicit collection_time attribution is required (includes old stored visits)"
        )
    with session.begin():
        published = policy(session)
        if published is None:
            raise ValueError("Activate milestones first")
        definition = {
            "quests": config.event_definitions(event_id),
            "visitorAttribution": attribution,
        }
        data = dict(
            event_id=event_id,
            name=name,
            starts_at=starts_at,
            ends_at=ends_at,
            claim_until=claim_until,
            policy_version=published.version,
            definition=definition,
        )
        existing = session.get(MilestoneEvent, event_id)
        if existing:
            if any(getattr(existing, k) != v for k, v in data.items()):
                raise ValueError("Published event instances are immutable; use a new ID")
        elif apply:
            if starts_at < session.scalar(select(func.clock_timestamp())):
                raise ValueError("New events must be scheduled before their earning interval")
            session.add(MilestoneEvent(**data))
        return {
            "eventId": event_id,
            "applied": apply,
            "alreadyPublished": bool(existing),
            "visitorAttribution": attribution,
            "includesPreEventStoredVisits": True,
        }
