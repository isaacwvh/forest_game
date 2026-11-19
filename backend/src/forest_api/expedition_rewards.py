"""Atomic rewards with permanent entitlement identity, including stored item grants."""

from uuid import uuid4

from forest_api import collection, items, services
from forest_api.collection_models import CollectionEvent, OwnedPack
from forest_api.errors import ApiError
from forest_api.expedition_models import (
    ExpeditionBonusGrant,
    ExpeditionClaim,
    ExpeditionEntitlement,
    ExpeditionRun,
)
from forest_api.inventory_management import capacity
from forest_api.visitor_models import VisitorRewardEvent, VisitorWalletEntry


def claim(session, settings, identity, run_id, entitlement_id, body, clock):
    operation = "expedition_claim:" + str(entitlement_id)
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        replay = services.replay(session, user.id, body.request_id, operation, digest)
        if replay is not None:
            if replay.get("runId") != str(run_id):
                raise ApiError(409, "idempotency_conflict", "Claim belongs to another run")
            return replay
        run = session.get(ExpeditionRun, run_id)
        entitlement = session.get(ExpeditionEntitlement, entitlement_id)
        if (
            run is None
            or run.owner_id != user.id
            or entitlement is None
            or entitlement.run_id != run.id
        ):
            raise ApiError(
                404, "expedition_reward_not_found", "Earn this reward before collecting it"
            )
        old = session.get(ExpeditionClaim, entitlement_id)
        if old is not None:
            receipt = {**old.receipt, "requestId": str(body.request_id)}
            services.record_request(session, user.id, body, operation, digest, receipt)
            return receipt
        services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        now = clock()
        reward = entitlement.reward
        packs, owned_items = [], []
        room = capacity(session, user.id, settings)
        if "packId" in reward:
            if room["unopenedPacks"] >= room["packLimit"]:
                raise ApiError(
                    409, "pack_capacity_exceeded", "Pack storage full. Open a pack, then retry."
                )
            collection.pack_contract(session, settings, reward["packId"], reward["version"])
        if "itemId" in reward:
            owned_items = items.grant(
                session,
                user.id,
                reward["itemId"],
                reward["version"],
                source="expedition_reward",
                reference=f"{run.id}/{entitlement.reward_key}",
            )
        wallet = collection.wallet_for(session, user.id)
        tokens, gems = reward.get("tokens", 0), reward.get("gems", 0)
        event_id = uuid4()
        session.add(
            VisitorRewardEvent(
                id=event_id,
                owner_id=user.id,
                kind="expedition",
                source_id=entitlement.id,
                created_at=now,
                detail={
                    "tokens": str(tokens),
                    "gems": str(gems),
                    "entitlementId": str(entitlement.id),
                },
            )
        )
        session.flush()
        if tokens:
            session.add(
                VisitorWalletEntry(
                    id=uuid4(), owner_id=user.id, event_id=event_id, amount=tokens, created_at=now
                )
            )
        if gems:
            session.add(
                ExpeditionBonusGrant(entitlement_id=entitlement.id, owner_id=user.id, amount=gems)
            )
        wallet.tokens = collection.checked(wallet.tokens + tokens)
        wallet.gems = collection.checked(wallet.gems + gems)
        wallet.lifetime_gems_earned = collection.checked(wallet.lifetime_gems_earned + gems)
        wallet.economy_version = collection.checked(wallet.economy_version + 1)
        grant = CollectionEvent(
            id=uuid4(),
            owner_id=user.id,
            request_id=body.request_id,
            operation=operation,
            payload_hash=digest,
            token_delta=0,
            gem_delta=0,
            receipt={},
            created_at=now,
        )
        if "packId" in reward:
            pack = OwnedPack(
                id=uuid4(),
                owner_id=user.id,
                pack_id=reward["packId"],
                pack_version=reward["version"],
                exchange_id=grant.id,
                acquired_at=now,
            )
            session.add(pack)
            packs.append(collection.pack_dto(pack))
        receipt = {
            "requestId": str(body.request_id),
            "runId": str(run.id),
            "entitlementId": str(entitlement.id),
            "rewardKey": entitlement.reward_key,
            "tokensEarned": str(tokens),
            "gemsEarned": str(gems),
            "packs": packs,
            "ownedItemIds": [str(i) for i in owned_items],
            "claimedAt": now.isoformat(),
            **collection.wallet_dto(wallet),
        }
        grant.receipt = receipt
        session.add(grant)
        session.add(
            ExpeditionClaim(entitlement_id=entitlement.id, owner_id=user.id, receipt=receipt)
        )
        run.progress_version = collection.checked(run.progress_version + 1)
        services.record_request(session, user.id, body, operation, digest, receipt)
        return receipt
