"""Finite introductory funding, claimed separately from activity rewards."""

from fractions import Fraction
from uuid import NAMESPACE_URL, uuid4, uuid5

from forest_api import collection, services
from forest_api.activity_models import MilestoneClaim
from forest_api.errors import ApiError
from forest_api.launch_balance import VERSION
from forest_api.models import PlayerProgress
from forest_api.visitor_models import VisitorRewardEvent, VisitorWalletEntry

TRACK = (
    ("first_movement", "First movement", "Sync your first eligible movement.", 30),
    ("first_hosted", "A first guest", "Welcome or collect your first visitor.", 30),
    ("three_hosted", "A growing gathering", "Host three visitors in total.", 60),
    ("first_seedling", "Taking root", "Grow your first seedling through activity.", 30),
    ("first_maturity", "A mature garden begins", "Grow your first adult through activity.", 90),
)


def summary(session, owner, catalogue, wallet):
    if catalogue.version != VERSION:
        return []
    progress = session.get(PlayerProgress, owner)
    hosted = wallet.hosted_active + wallet.hosted_offline
    movement = bool(
        progress
        and (
            progress.activity_steps > 0
            or any(Fraction(q) > 0 for q in progress.activity_metrics.values())
        )
    )
    eligible = {
        "first_movement": movement,
        "first_hosted": hosted >= 1,
        "three_hosted": hosted >= 3,
        "first_seedling": bool(progress and progress.first_seedling_at),
        "first_maturity": bool(progress and progress.first_maturity_count > 0),
    }
    return [
        {
            "milestoneId": key,
            "title": title,
            "description": description,
            "rewardTokens": str(reward),
            "eligible": eligible[key],
            "claimed": session.get(MilestoneClaim, (owner, key)) is not None,
        }
        for key, title, description, reward in TRACK
    ]


def claim(session, settings, identity, milestone_id, body, clock):
    operation = "milestone_claim:" + milestone_id
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return previous
        services.lock_garden(session, user.id, write=True)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        wallet = collection.wallet_for(session, user.id)
        existing = session.get(MilestoneClaim, (user.id, milestone_id))
        if existing is not None:
            services.record_request(session, user.id, body, operation, digest, existing.receipt)
            return existing.receipt
        entry = next(
            (
                x
                for x in summary(session, user.id, catalogue, wallet)
                if x["milestoneId"] == milestone_id
            ),
            None,
        )
        if entry is None:
            raise ApiError(404, "milestone_not_found", "This milestone is not available")
        if not entry["eligible"]:
            raise ApiError(409, "milestone_not_ready", "Complete the milestone before claiming")
        boundary = clock()
        reward = int(entry["rewardTokens"])
        event_id = uuid4()
        session.add(
            VisitorRewardEvent(
                id=event_id,
                owner_id=user.id,
                kind="milestone",
                source_id=uuid5(NAMESPACE_URL, f"{user.id}/{milestone_id}"),
                created_at=boundary,
                detail={"milestoneId": milestone_id, "tokens": str(reward)},
            )
        )
        session.flush()
        session.add(
            VisitorWalletEntry(
                id=uuid4(), owner_id=user.id, event_id=event_id, amount=reward, created_at=boundary
            )
        )
        wallet.tokens = collection.checked(wallet.tokens + reward)
        wallet.economy_version = collection.checked(wallet.economy_version + 1)
        receipt = {
            "requestId": str(body.request_id),
            "milestoneId": milestone_id,
            "milestoneEventId": str(event_id),
            "tokensEarned": str(reward),
            "claimedAt": boundary.isoformat(),
            **collection.wallet_dto(wallet),
        }
        session.add(
            MilestoneClaim(
                owner_id=user.id,
                milestone_id=milestone_id,
                reward_tokens=reward,
                claimed_at=boundary,
                receipt=receipt,
            )
        )
        services.record_request(session, user.id, body, operation, digest, receipt)
        return receipt
