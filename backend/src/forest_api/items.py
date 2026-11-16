"""Capacity-guarded item grants. Call inside the reward's transaction before claiming it."""

from decimal import Decimal

from sqlalchemy import func, select, text

from forest_api import services
from forest_api.errors import ApiError
from forest_api.item_models import (
    ItemDefinition,
    ItemIdentity,
    ItemPlacement,
    ItemValuation,
    ItemValueDefinition,
    OwnedItem,
)
from forest_api.models import User
from forest_api.schemas import ItemDTO, PlacementDTO

BENCH_DESCRIPTION = "a basic bench, allows weary travelers to find rest in your garden"


def publish_bench(session):
    session.execute(text("SELECT pg_advisory_xact_lock(591417018)"))
    definition = session.get(ItemDefinition, ("wooden-bench", 1))
    if definition is None:
        definition = ItemDefinition(
            id="wooden-bench",
            version=1,
            display_name="Wooden Bench",
            description=BENCH_DESCRIPTION,
            rarity="common",
            asset_version="1.0.0",
            model_key="assets/items/wooden-bench/v1/models/wooden-bench-standard.usdz",
            thumbnail_key="assets/items/wooden-bench/v1/ui/wooden-bench-standard.png",
            clearance_radius=Decimal("0.900"),
        )
        session.add(definition)
        session.flush()
    return definition


def capacity(session, owner):
    settings = session.info["settings"]
    count = session.scalar(
        select(func.count()).select_from(OwnedItem).where(OwnedItem.owner_id == owner)
    )
    placed = session.scalar(
        select(func.count()).select_from(ItemPlacement).where(ItemPlacement.owner_id == owner)
    )
    return {
        "ownedItems": count,
        "placedItems": placed,
        "storedItems": count - placed,
        "itemLimit": settings.item_capacity,
    }


def grant(session, owner, item_id, version, *, source, reference, quantity=1, token_value=None):
    """Whole-bundle grant, serialized on owner. Never marks reward claims or commits.

    The caller must let a capacity error roll back the enclosing reward transaction.
    Permanent source identity prevents an old reward resurrecting a retired copy.
    """
    if type(quantity) is not int or not 1 <= quantity <= 100:
        raise ApiError(422, "invalid_item_quantity", "Invalid item quantity")
    user = session.scalar(select(User).where(User.id == owner).with_for_update())
    if user is None or user.status != "active":
        raise ApiError(404, "account_not_found", "Account not found")
    garden = services.lock_garden(session, owner, write=True)
    existing = list(
        session.scalars(
            select(ItemIdentity)
            .where(
                ItemIdentity.owner_id == owner,
                ItemIdentity.source == source,
                ItemIdentity.reference == reference,
            )
            .order_by(ItemIdentity.ordinal)
        )
    )
    if existing:
        if len(existing) != quantity or any(
            r.item_id != item_id or r.item_version != version for r in existing
        ):
            raise ApiError(
                409, "item_grant_conflict", "Reward source was used for a different item grant"
            )
        return [r.id for r in existing]
    if session.get(ItemDefinition, (item_id, version)) is None:
        raise ApiError(409, "item_unavailable", "Item is not published")
    room = capacity(session, owner)
    if room["ownedItems"] + quantity > room["itemLimit"]:
        raise ApiError(
            409,
            "item_capacity_full",
            "Item inventory full. Make room before collecting this reward.",
        )
    identities = [
        ItemIdentity(
            owner_id=owner,
            item_id=item_id,
            item_version=version,
            source=source,
            reference=reference,
            ordinal=i,
        )
        for i in range(quantity)
    ]
    session.add_all(identities)
    session.flush()
    value = session.get(ItemValueDefinition, (item_id, version))
    if token_value is not None and value is None:
        raise ApiError(409, "sale_unavailable", "Item valuation is not published")
    if value is not None:
        session.add_all(
            [
                ItemValuation(
                    owned_item_id=r.id,
                    valuation_version=value.valuation_version,
                    token_value=value.token_value if token_value is None else token_value,
                    resale_basis_points=value.resale_basis_points,
                )
                for r in identities
            ]
        )
    session.add_all([OwnedItem(id=r.id, owner_id=owner) for r in identities])
    if garden.state_version >= 9223372036854775807:
        raise ApiError(503, "version_exhausted", "Garden version requires maintenance")
    garden.state_version += 1
    session.flush()
    return [r.id for r in identities]


def rows(session, owner, *, placed_only=False):
    query = (
        select(OwnedItem, ItemIdentity, ItemDefinition, ItemPlacement)
        .join(ItemIdentity, ItemIdentity.id == OwnedItem.id)
        .join(
            ItemDefinition,
            (ItemDefinition.id == ItemIdentity.item_id)
            & (ItemDefinition.version == ItemIdentity.item_version),
        )
        .outerjoin(ItemPlacement, ItemPlacement.item_id == OwnedItem.id)
        .where(OwnedItem.owner_id == owner)
        .order_by(OwnedItem.id)
    )
    if placed_only:
        query = query.where(ItemPlacement.item_id.is_not(None))
    return session.execute(query).all()


def present(row):
    owned, identity, definition, placement = row
    from sqlalchemy.orm import object_session

    from forest_api.item_skills import descriptions

    return ItemDTO(
        owned_item_id=owned.id,
        item_id=definition.id,
        definition_version=definition.version,
        display_name=definition.display_name,
        description=definition.description,
        rarity=definition.rarity,
        asset_version=definition.asset_version,
        model_key=definition.model_key,
        thumbnail_key=definition.thumbnail_key,
        clearance_radius=definition.clearance_radius,
        garden_skills=descriptions(object_session(definition), definition),
        placement=PlacementDTO(
            garden_id=placement.garden_id,
            x=placement.x,
            y=placement.y,
            rotation_degrees=placement.rotation_degrees,
        )
        if placement
        else None,
    )


def read(session, identity, limit, after):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        services.lock_garden(session, user.id)
        values = rows(session, user.id)
        if any(row[2].id != "wooden-bench" for row in values) and not session.info.get(
            "item_rotations_client"
        ):
            raise ApiError(
                426, "item_content_update_required", "Update the app for the new garden items"
            )
        if after is not None:
            if after not in {r[0].id for r in values}:
                raise ApiError(400, "invalid_cursor", "Refresh the item inventory")
            values = [r for r in values if r[0].id > after]
        return {
            "items": [present(r) for r in values[:limit]],
            "capacity": capacity(session, user.id),
            "nextCursor": str(values[limit - 1][0].id) if len(values) > limit else None,
        }


def grant_bench(session, username, *, apply=False):
    with session.begin():
        user = session.scalar(select(User).where(User.username == username).with_for_update())
        if user is None:
            raise ValueError("Account not found")
        services.lock_garden(session, user.id, write=True)
        publish_bench(session)
        ids = grant(
            session, user.id, "wooden-bench", 1, source="intro_item", reference="wooden-bench-v1"
        )
        result = {
            "username": username,
            "ownedItemIds": [str(v) for v in ids],
            "capacity": capacity(session, user.id),
            "applied": apply,
        }
        if not apply:
            session.rollback()
        return result
