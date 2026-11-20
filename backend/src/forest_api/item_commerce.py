"""Token-only saved offers, atomic allowances, copy valuations and durable resale."""

from uuid import UUID, uuid4

from pydantic import Field
from sqlalchemy import func, select

from forest_api import collection, items, services
from forest_api.collection_models import CollectionEvent
from forest_api.errors import ApiError
from forest_api.item_models import (
    ItemDefinition,
    ItemIdentity,
    ItemPlacement,
    ItemSale,
    ItemShopOffer,
    ItemValuation,
    ItemValueDefinition,
    OwnedItem,
    ShopAllowance,
    ShopOfferWindow,
)
from forest_api.schemas import DTO

VALUATION_VERSION = "item-resale-v1"
BENCH_PRICE = 550


class PurchaseItem(DTO):
    request_id: UUID
    offer_id: str = Field(min_length=1, max_length=100)
    offer_version: int = Field(strict=True, ge=1, le=2147483647)
    quantity: int = Field(strict=True, ge=1, le=20)


class SellItem(DTO):
    request_id: UUID
    valuation_version: str = Field(min_length=1, max_length=100)
    expected_tokens: str = Field(pattern=r"^[0-9]{1,19}$")


def offers(session, owner=None, now=None):
    from forest_api import shop

    now = now or session.scalar(select(func.clock_timestamp()))
    rotating = shop.active_release(session, now) is not None
    result = []
    query = (
        select(ItemShopOffer, ItemDefinition)
        .join(
            ItemDefinition,
            (ItemDefinition.id == ItemShopOffer.item_id)
            & (ItemDefinition.version == ItemShopOffer.item_version),
        )
        .where(ItemShopOffer.active)
        .order_by(ItemShopOffer.id, ItemShopOffer.version)
    ).outerjoin(
        ShopOfferWindow,
        (ShopOfferWindow.offer_id == ItemShopOffer.id)
        & (ShopOfferWindow.offer_version == ItemShopOffer.version),
    )
    query = (
        query.where(ShopOfferWindow.starts_at <= now, ShopOfferWindow.ends_at > now)
        if rotating
        else query.where(ShopOfferWindow.offer_id.is_(None))
    )
    for offer, definition in session.execute(query):
        window = session.get(ShopOfferWindow, (offer.id, offer.version))
        usage = (
            session.get(ShopAllowance, (owner, offer.id, offer.version))
            if owner and window and window.purchase_limit
            else None
        )
        from forest_api.item_skills import descriptions

        result.append(
            {
                "offerId": offer.id,
                "offerVersion": offer.version,
                "tokenCost": str(offer.token_cost),
                "itemId": definition.id,
                "definitionVersion": definition.version,
                "displayName": definition.display_name,
                "description": definition.description,
                "rarity": definition.rarity,
                "assetVersion": definition.asset_version,
                "modelKey": definition.model_key,
                "thumbnailKey": definition.thumbnail_key,
                "gardenSkills": descriptions(session, definition),
                **(
                    {
                        "startsAt": window.starts_at.isoformat(),
                        "endsAt": window.ends_at.isoformat(),
                        "slot": window.slot,
                        "remainingAllowance": max(
                            0, window.purchase_limit - (usage.purchased if usage else 0)
                        )
                        if window.purchase_limit
                        else None,
                    }
                    if window
                    else {}
                ),
            }
        )
    return result


def publish(session, *, apply=False):
    with session.begin():
        items.publish_bench(session)
        if session.get(ItemValueDefinition, ("wooden-bench", 1)) is None:
            session.add(
                ItemValueDefinition(
                    item_id="wooden-bench",
                    item_version=1,
                    valuation_version=VALUATION_VERSION,
                    token_value=BENCH_PRICE,
                    resale_basis_points=2500,
                )
            )
            session.flush()
        if session.get(ItemShopOffer, ("wooden-bench", 1)) is None:
            session.add(
                ItemShopOffer(
                    id="wooden-bench",
                    version=1,
                    item_id="wooden-bench",
                    item_version=1,
                    token_cost=BENCH_PRICE,
                    active=True,
                )
            )
            session.flush()
        result = {
            "applied": apply,
            "offers": offers(session),
            "benchSaleTokens": str(BENCH_PRICE // 4),
        }
        if not apply:
            session.rollback()
        return result


def purchase(session, settings, identity, body, clock):
    operation = "item_purchase"
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = collection.durable_replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return previous
        services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        require_client(session)
        offer = session.get(ItemShopOffer, (body.offer_id, body.offer_version))
        if offer is None or not offer.active:
            raise ApiError(409, "stale_offer", "Refresh Shop to see the current offer")
        from forest_api import shop

        boundary = clock()
        window = shop.validate_purchase(session, user.id, offer, body.quantity, boundary)
        room = items.capacity(session, user.id)
        if room["ownedItems"] + body.quantity > room["itemLimit"]:
            raise ApiError(
                409, "item_capacity_full", "Item inventory full. Sell a stored item to make room."
            )
        cost = collection.checked(offer.token_cost * body.quantity)
        wallet = collection.wallet_for(session, user.id)
        if wallet.tokens < cost:
            raise ApiError(409, "insufficient_tokens", "You need more tokens for this item")
        from forest_api.visitors import throttle

        throttle(session, user.id, boundary)
        purchase_id = uuid4()
        ids = items.grant(
            session,
            user.id,
            offer.item_id,
            offer.item_version,
            source=operation,
            reference=str(purchase_id),
            quantity=body.quantity,
            token_value=offer.token_cost,
        )
        wallet.tokens -= cost
        shop.consume(session, user.id, window, body.quantity)
        wallet.economy_version = collection.checked(wallet.economy_version + 1)
        receipt = {
            "requestId": str(body.request_id),
            "purchaseId": str(purchase_id),
            "offerId": offer.id,
            "offerVersion": offer.version,
            "quantity": body.quantity,
            "tokensSpent": str(cost),
            "ownedItemIds": [str(v) for v in ids],
            "itemCapacity": items.capacity(session, user.id),
            "acceptedAt": boundary.isoformat(),
            **collection.wallet_dto(wallet),
        }
        session.add(
            CollectionEvent(
                id=purchase_id,
                owner_id=user.id,
                request_id=body.request_id,
                operation=operation,
                payload_hash=digest,
                token_delta=-cost,
                gem_delta=0,
                receipt=receipt,
                created_at=boundary,
            )
        )
        services.record_request(session, user.id, body, operation, digest, receipt)
        return receipt


def require_client(session):
    if not session.info.get("item_commerce_client"):
        raise ApiError(
            426, "item_commerce_client_update_required", "Update the app to buy or sell items"
        )


def quote(session, owner, owned_id):
    row = session.scalar(
        select(OwnedItem).where(OwnedItem.id == owned_id, OwnedItem.owner_id == owner)
    )
    if row is None:
        raise ApiError(404, "item_not_found", "Item not found")
    identity = session.get(ItemIdentity, owned_id)
    valuation = session.get(ItemValuation, owned_id)
    if valuation is None:
        # Pre-commerce gifts use an immutable per-definition value. GET stays read-only.
        valuation = session.get(ItemValueDefinition, (identity.item_id, identity.item_version))
    if valuation is None:
        # Existing expedition copies predate publication of their planned values.
        # Resolve only approved v1 values; never write during a quote read or
        # override an acquired-copy/published valuation above.
        from forest_api.expedition_items import approved_valuation

        valuation = approved_valuation(identity.item_id, identity.item_version)
    if valuation is None:
        raise ApiError(
            409, "item_sale_unavailable", "This item does not have a published resale value"
        )
    return {
        "ownedItemId": str(owned_id),
        "valuationVersion": valuation.valuation_version,
        "tokenValue": str(valuation.token_value),
        "resaleBasisPoints": valuation.resale_basis_points,
        "tokens": str(valuation.token_value * valuation.resale_basis_points // 10000),
    }


def read_quote(session, identity, owned_id):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        return quote(session, user.id, owned_id)


def sell(session, settings, identity, owned_id, body, clock):
    operation = "item_sell"
    digest = services.request_hash(operation + ":" + str(owned_id), body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return previous
        previous_sale = session.scalar(
            select(ItemSale).where(
                ItemSale.owner_id == user.id, ItemSale.request_id == body.request_id
            )
        )
        if previous_sale is not None:
            if previous_sale.payload_hash != digest:
                raise ApiError(
                    409, "idempotency_conflict", "Request ID was used for different input"
                )
            return previous_sale.receipt
        garden = services.lock_garden(session, user.id, write=True)
        require_client(session)
        current = quote(session, user.id, owned_id)
        if session.get(ItemPlacement, owned_id) is not None:
            raise ApiError(409, "item_is_placed", "Store this item before selling it")
        if (
            current["valuationVersion"] != body.valuation_version
            or current["tokens"] != body.expected_tokens
        ):
            raise ApiError(409, "stale_sale_quote", "The sale price changed. Review a fresh quote")
        boundary = clock()
        from forest_api.visitors import throttle

        throttle(session, user.id, boundary)
        wallet = collection.wallet_for(session, user.id)
        amount = int(current["tokens"])
        wallet.tokens = collection.checked(wallet.tokens + amount)
        wallet.economy_version = collection.checked(wallet.economy_version + 1)
        garden.state_version = collection.checked(garden.state_version + 1)
        session.delete(session.get(OwnedItem, owned_id))
        session.flush()
        sale_id = uuid4()
        receipt = {
            "requestId": str(body.request_id),
            "saleId": str(sale_id),
            "ownedItemId": str(owned_id),
            "tokensEarned": str(amount),
            "soldAt": boundary.isoformat(),
            "valuation": current,
            "itemCapacity": items.capacity(session, user.id),
            **collection.wallet_dto(wallet),
        }
        session.add(
            ItemSale(
                id=sale_id,
                owner_id=user.id,
                owned_item_id=owned_id,
                request_id=body.request_id,
                payload_hash=digest,
                tokens=amount,
                receipt=receipt,
                sold_at=boundary,
            )
        )
        services.record_request(session, user.id, body, operation, digest, receipt)
        return receipt
