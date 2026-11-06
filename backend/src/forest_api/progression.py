"""Step progression v1. Writers hold the account lock; readers never mint currency."""

from datetime import UTC, datetime
from math import isqrt
from uuid import NAMESPACE_URL, uuid4, uuid5

from sqlalchemy import func, select

from forest_api import collection, services
from forest_api.calculations import MAX_INTEGER
from forest_api.models import PlayerProgress, User
from forest_api.progression_models import GemGrant
from forest_api.progression_schemas import AccountSummary, AccountWallet, ProgressionSnapshot
from forest_api.visitor_models import VisitorWallet

RULES_VERSION = "step-progression-v1"
STEPS_PER_GEM = 10_000
STEPS_PER_XP = 100


def xp_threshold(level: int) -> int:
    if type(level) is not int or level < 1:
        raise ValueError("Level must be a positive integer")
    return 25 * (level - 1) * (level + 2) // 2


def snapshot(progress: PlayerProgress | None) -> ProgressionSnapshot:
    steps = progress.activity_steps if progress else 0
    if type(steps) is not int or not 0 <= steps <= MAX_INTEGER:
        raise ValueError("Invalid recorded step total")
    xp = steps // STEPS_PER_XP
    # Integer-only inverse, followed by exact threshold checks, even at bigint limits.
    level = max(1, (isqrt(9 + 8 * xp // 25) - 3) // 2 + 1)
    while xp_threshold(level + 1) <= xp:
        level += 1
    while xp_threshold(level) > xp:
        level -= 1
    remainder = steps % STEPS_PER_GEM
    return ProgressionSnapshot(
        rules_version=RULES_VERSION,
        version=progress.progression_version if progress else 0,
        lifetime_recorded_steps=str(steps),
        step_xp=str(xp),
        total_xp=str(xp),
        level=level,
        xp_into_level=str(xp - xp_threshold(level)),
        xp_for_next_level=str(50 + 25 * (level - 1)),
        steps_into_next_gem=remainder,
        steps_per_gem=STEPS_PER_GEM,
        steps_to_next_gem=STEPS_PER_GEM - remainder,
        plants_grown_to_adulthood=str(progress.first_maturity_count if progress else 0),
        last_sync_at=progress.last_sync_at if progress else None,
    )


def wallet_snapshot(wallet: VisitorWallet | None) -> AccountWallet:
    active = wallet.hosted_active if wallet else 0
    offline = wallet.hosted_offline if wallet else 0
    return AccountWallet(
        economy_version=wallet.economy_version if wallet else 0,
        token_balance=str(wallet.tokens if wallet else 0),
        gem_balance=str(wallet.gems if wallet else 0),
        lifetime_gems_earned=str(wallet.lifetime_gems_earned if wallet else 0),
        initialized=wallet.progression_initialized if wallet else False,
        hosted_active=str(active),
        hosted_offline=str(offline),
        hosted_total=str(active + offline),
    )


def initialize_account(session, owner):
    """New registrations only; existing accounts use the explicit backfill path."""
    wallet = collection.wallet_for(session, owner)
    wallet.progression_initialized = True
    if session.get(PlayerProgress, owner) is None:
        session.add(PlayerProgress(owner_id=owner, activity_steps=0, first_maturity_count=0))


def credit_steps(session, owner, steps, source_id, boundary):
    wallet = collection.wallet_for(session, owner)
    entitlement = steps // STEPS_PER_GEM
    if entitlement < wallet.lifetime_gems_earned:
        raise ValueError("Gem entitlement cannot move backwards")
    amount = entitlement - wallet.lifetime_gems_earned
    initialized = wallet.progression_initialized
    if amount:
        session.add(
            GemGrant(
                id=uuid4(),
                owner_id=owner,
                source_id=source_id,
                kind="steps" if initialized else "backfill",
                rules_version=RULES_VERSION,
                start_milestone=wallet.lifetime_gems_earned,
                end_milestone=entitlement,
                amount=amount,
                created_at=boundary,
            )
        )
        wallet.gems = collection.checked(wallet.gems + amount)
        wallet.lifetime_gems_earned = entitlement
    if amount or not initialized:
        wallet.economy_version = collection.checked(wallet.economy_version + 1)
    wallet.progression_initialized = True
    return amount, wallet


def reconcile(session, owner, wallet):
    if not wallet.progression_initialized:
        return
    earned = session.scalar(
        select(func.coalesce(func.sum(GemGrant.amount), 0)).where(GemGrant.owner_id == owner)
    )
    progress = session.get(PlayerProgress, owner)
    entitlement = (progress.activity_steps if progress else 0) // STEPS_PER_GEM
    # Spending is deliberately deferred. Its ledger must join this reconciliation when added.
    if earned != wallet.gems or earned != wallet.lifetime_gems_earned or earned != entitlement:
        raise ValueError("Unreconciled gem wallet; history retained")


def read_summary(session, identity, *, clock=lambda: datetime.now(UTC)):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        return AccountSummary(
            server_time=clock(),
            profile=services.user_dto(user),
            progression=snapshot(session.get(PlayerProgress, user.id)),
            wallet=wallet_snapshot(session.get(VisitorWallet, user.id)),
        )


def backfill(session, *, apply=False, limit=500):
    if not 1 <= limit <= 5000:
        raise ValueError("Limit must be between 1 and 5000")
    with session.begin():
        owners = list(
            session.scalars(
                select(User.id)
                .outerjoin(VisitorWallet, VisitorWallet.owner_id == User.id)
                .where(
                    (VisitorWallet.owner_id.is_(None)) | (~VisitorWallet.progression_initialized)
                )
                .order_by(User.id)
                .limit(limit + 1)
            )
        )
        result = {
            "examined": 0,
            "initialized": 0,
            "gems": "0",
            "hasMore": len(owners) > limit,
            "applied": apply,
        }
        total = 0
        for owner in owners[:limit]:
            session.scalar(select(User).where(User.id == owner).with_for_update())
            wallet = session.get(VisitorWallet, owner)
            if wallet and wallet.progression_initialized:
                continue
            progress = session.get(PlayerProgress, owner)
            steps = progress.activity_steps if progress else 0
            result["examined"] += 1
            amount = steps // STEPS_PER_GEM - (wallet.lifetime_gems_earned if wallet else 0)
            total += amount
            if apply:
                credit_steps(
                    session,
                    owner,
                    steps,
                    uuid5(NAMESPACE_URL, f"{RULES_VERSION}/backfill/{owner}"),
                    session.scalar(select(func.clock_timestamp())),
                )
                result["initialized"] += 1
        result["gems"] = str(total)
        return result
