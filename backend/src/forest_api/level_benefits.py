"""Versioned account capacities and durable, at-most-once level presentation."""

from uuid import uuid4

from sqlalchemy import func, select, text

from forest_api import progression, services
from forest_api.errors import ApiError
from forest_api.models import Garden, PlayerProgress, User
from forest_api.progression_models import AccountLevelState, LevelBenefitsPolicy, LevelUpNotice
from forest_api.progression_schemas import (
    LevelBenefitsSnapshot,
    LevelUpClaimResult,
    LevelUpNoticeDTO,
)

POLICY_VERSION = "level-benefits-v1"
PLANT_TIERS = ((1, 50), (5, 60), (10, 75), (15, 90), (20, 100))


def base_capacity(level):
    if type(level) is not int or level < 1:
        raise ValueError("Level must be a positive integer")
    return 600 + 75 * min(level - 1, 4) + 60 * min(max(level - 5, 0), 15)


def plant_limit(level):
    base_capacity(level)  # shared bounds validation
    return next(limit for milestone, limit in reversed(PLANT_TIERS) if level >= milestone)


def active(session, boundary=None):
    policy = session.get(LevelBenefitsPolicy, POLICY_VERSION)
    return policy is not None and (boundary is None or policy.effective_at <= boundary)


def account_level(session, owner):
    return progression.snapshot(session.get(PlayerProgress, owner)).level


def owned_limit(session, owner, fallback):
    return plant_limit(account_level(session, owner)) if active(session) else fallback


def initialize(session, owner):
    if active(session):
        session.add(AccountLevelState(owner_id=owner, reached_level=1, presented_level=1))


def snapshot(session, owner, settings, boundary):
    if not active(session, boundary):
        return None
    from forest_api import visitors

    progress = progression.snapshot(session.get(PlayerProgress, owner))
    garden = session.scalar(select(Garden).where(Garden.owner_id == owner))
    _, definition = visitors.rule_at(session, settings, boundary)
    skills = services.skill_snapshot(session, garden, boundary=boundary)
    base = base_capacity(progress.level)
    next_plant = next(
        ((level, limit) for level, limit in PLANT_TIERS if level > progress.level), None
    )
    return LevelBenefitsSnapshot(
        policy_version=POLICY_VERSION,
        progression_version=progress.version,
        garden_state_version=garden.state_version,
        level=progress.level,
        base_offline_capacity=base,
        effective_offline_capacity=skills.capacity(
            base, 3 * base, flat_multiplier=definition.capacity_flat_multiplier
        ),
        maximum_offline_capacity=3 * base,
        plant_limit=plant_limit(progress.level),
        planted_limit=settings.planted_capacity if settings else 20,
        next_base_increase=base_capacity(progress.level + 1) - base,
        next_plant_level=next_plant[0] if next_plant else None,
        next_plant_limit=next_plant[1] if next_plant else None,
    )


def record_level_up(session, owner, old_level, new_level, source, settings, boundary):
    if not active(session, boundary) or new_level <= old_level:
        return
    state = session.get(AccountLevelState, owner)
    if state is None:
        state = AccountLevelState(
            owner_id=owner, reached_level=old_level, presented_level=old_level
        )
        session.add(state)
    if new_level <= state.reached_level:
        return
    start = max(old_level, state.reached_level)
    benefits = snapshot(session, owner, settings, boundary)
    notice = LevelUpNoticeDTO(
        id=uuid4(),
        policy_version=POLICY_VERSION,
        from_level=start,
        to_level=new_level,
        base_offline_before=base_capacity(start),
        base_offline_after=base_capacity(new_level),
        effective_offline_after=benefits.effective_offline_capacity,
        plant_limit_before=plant_limit(start),
        plant_limit_after=plant_limit(new_level),
    )
    session.add(
        LevelUpNotice(
            id=notice.id,
            owner_id=owner,
            source_id=source,
            from_level=start,
            to_level=new_level,
            payload=notice.model_dump(mode="json", by_alias=True),
            created_at=boundary,
        )
    )
    state.reached_level = new_level


def pending_notice(session, owner):
    row = session.scalar(
        select(LevelUpNotice)
        .where(LevelUpNotice.owner_id == owner, LevelUpNotice.consumed_at.is_(None))
        .order_by(LevelUpNotice.to_level)
        .limit(1)
    )
    return LevelUpNoticeDTO.model_validate(row.payload) if row else None


def claim(session, identity, notice_id, body, *, clock):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        row = session.get(LevelUpNotice, notice_id)
        if row is None or row.owner_id != user.id:
            raise ApiError(404, "level_notice_not_found", "Level-up notice is unavailable")
        if row.consumed_at is not None:
            return LevelUpClaimResult(
                notice=LevelUpNoticeDTO.model_validate(row.payload),
                may_present=row.claim_id == body.request_id
                and row.installation_id == body.installation_id,
            )
        reused = session.scalar(
            select(LevelUpNotice.id).where(
                LevelUpNotice.owner_id == user.id, LevelUpNotice.claim_id == body.request_id
            )
        )
        if reused is not None:
            raise ApiError(409, "idempotency_conflict", "Presentation request was already used")
        pending = pending_notice(session, user.id)
        if pending is None or pending.id != row.id:
            raise ApiError(409, "stale_level_notice", "Refresh account progress before presenting")
        row.consumed_at = clock()
        row.claim_id = body.request_id
        row.installation_id = body.installation_id
        state = session.get(AccountLevelState, user.id)
        state.presented_level = max(state.presented_level, row.to_level)
        return LevelUpClaimResult(
            notice=LevelUpNoticeDTO.model_validate(row.payload), may_present=True
        )


def activate(session, settings, *, apply=False, clock=None):
    """Settle old contexts, baseline historical levels, then enable prospectively."""
    from forest_api import visitors

    with session.begin():
        session.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended('forest-level-benefits',0))")
        )
        if active(session):
            return {"version": POLICY_VERSION, "alreadyActive": True, "applied": False}
        owners = list(session.scalars(select(User.id).order_by(User.id).with_for_update()))
        gardens = list(session.scalars(select(Garden).order_by(Garden.owner_id).with_for_update()))
        if list(session.scalars(select(User.id).order_by(User.id))) != owners:
            raise ValueError("Accounts changed during activation; retry")
        result = {"version": POLICY_VERSION, "accounts": len(owners), "applied": apply}
        if not apply:
            return result
        boundary = clock() if clock else session.scalar(select(func.clock_timestamp()))
        for garden in gardens:
            state, _ = visitors.settle(session, settings, garden, boundary)
            if state.settled_at > boundary:
                raise ValueError("Activation cannot precede settled visitor time")
        # Settlement holds the catalogue lock used by registration. Detect any
        # accounts committed before that lock was acquired, then retry atomically.
        if list(session.scalars(select(User.id).order_by(User.id))) != owners:
            raise ValueError("Accounts changed during activation; retry")
        session.add(LevelBenefitsPolicy(version=POLICY_VERSION, effective_at=boundary))
        for owner in owners:
            level = account_level(session, owner)
            session.add(
                AccountLevelState(owner_id=owner, reached_level=level, presented_level=level)
            )
        session.flush()
        for garden in gardens:
            visitors.VisitorAccounting(settings).after_change(session, garden, boundary)
        return result
