"""Bounded live inventory and exact, recoverable plant recycling."""

from uuid import UUID, uuid4

from pydantic import Field
from sqlalchemy import func, select

from forest_api import collection, services
from forest_api.collection_models import OwnedPack, PackOpening
from forest_api.errors import ApiError
from forest_api.models import GardenPlacement, GrowthProfile, OwnedPlant, PlantIdentity, PlantSale
from forest_api.schemas import DTO

VALUATION_VERSION = "plant-resale-v1"
RARITY_BASES = {"common": 240, "rare": 480, "epic": 720, "legendary": 960}


class SellPlant(DTO):
    request_id: UUID
    valuation_version: str = Field(min_length=1, max_length=100)
    expected_tokens: str = Field(pattern=r"^[0-9]{1,19}$")
    expected_growth_micro_units: str = Field(pattern=r"^[0-9]{1,19}$")


def capacity(session, owner, settings):
    owned = session.scalar(
        select(func.count()).select_from(OwnedPlant).where(OwnedPlant.owner_id == owner)
    )
    planted = session.scalar(
        select(func.count()).select_from(GardenPlacement).where(GardenPlacement.owner_id == owner)
    )
    packs = session.scalar(
        select(func.count())
        .select_from(OwnedPack)
        .where(
            OwnedPack.owner_id == owner,
            ~select(PackOpening.id).where(PackOpening.pack_id == OwnedPack.id).exists(),
        )
    )
    return {
        "ownedPlants": owned,
        "plantedPlants": planted,
        "storedPlants": owned - planted,
        "plantLimit": settings.plant_capacity,
        "plantedLimit": settings.planted_capacity,
        "unopenedPacks": packs,
        "packLimit": settings.pack_capacity,
    }


def require_plant_room(session, owner, settings=None, quantity=1):
    # All gameplay callers hold the account lock, so check + award is serialized.
    count = session.scalar(
        select(func.count()).select_from(OwnedPlant).where(OwnedPlant.owner_id == owner)
    )
    limit = settings.plant_capacity if settings is not None else 50
    if count + quantity > limit:
        raise ApiError(
            409,
            "plant_capacity_full",
            "Plant collection full. Sell a stored plant to open this pack.",
        )


def read_capacity(session, settings, identity):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        return capacity(session, user.id, settings)


def price(base, variant_basis_points, water, adult_water):
    if adult_water <= 0:
        raise ApiError(503, "sale_unavailable", "This plant's growth profile is unavailable")
    water = min(max(water, 0), adult_water)
    # base * variant * (1/4 + water/(4*adult)); one final integer floor.
    return base * variant_basis_points * (adult_water + water) // (40000 * adult_water)


def quote(session, owner, plant):
    identity = session.get(PlantIdentity, plant.id)
    if identity.acquisition_source == "starter":
        raise ApiError(409, "starter_protected", "Your original starter stays with your garden")
    if session.get(GardenPlacement, plant.id) is not None:
        raise ApiError(409, "plant_is_planted", "Store this plant before selling it")
    base = RARITY_BASES.get(identity.valuation_rarity)
    if (
        identity.owner_id != owner
        or identity.valuation_version != VALUATION_VERSION
        or base is None
        or identity.variant_basis_points is None
    ):
        raise ApiError(409, "sale_unavailable", "This plant does not have an approved resale value")
    profile = session.get(GrowthProfile, (plant.growth_profile_id, plant.growth_profile_version))
    adult = int(profile.thresholds["adult"])
    amount = price(base, identity.variant_basis_points, plant.growth_micro_units, adult)
    return {
        "plantId": str(plant.id),
        "valuationVersion": identity.valuation_version,
        "rarity": identity.valuation_rarity,
        "rarityBase": str(base),
        "variantBasisPoints": identity.variant_basis_points,
        "growthMicroUnits": str(plant.growth_micro_units),
        "adultWaterMicroUnits": str(adult),
        "tokens": str(amount),
    }


def read_quote(session, identity, plant_id):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        return quote(session, user.id, services.owned_plant(session, user.id, plant_id))


def sell(session, settings, identity, plant_id, body, clock):
    operation = "plant_sell"
    digest = services.request_hash(operation + ":" + str(plant_id), body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return previous
        previous = session.scalar(
            select(PlantSale).where(
                PlantSale.owner_id == user.id, PlantSale.request_id == body.request_id
            )
        )
        if previous is not None:
            if previous.payload_hash != digest:
                raise ApiError(
                    409, "idempotency_conflict", "Request ID was used for different input"
                )
            return previous.receipt
        garden = services.lock_garden(session, user.id, write=True)
        plant = services.owned_plant(session, user.id, plant_id, lock=True)
        current = quote(session, user.id, plant)
        if (
            current["valuationVersion"] != body.valuation_version
            or current["tokens"] != body.expected_tokens
            or current["growthMicroUnits"] != body.expected_growth_micro_units
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
        session.delete(plant)
        session.flush()
        sale_id = uuid4()
        receipt = {
            "requestId": str(body.request_id),
            "saleId": str(sale_id),
            "plantId": str(plant_id),
            "tokensEarned": str(amount),
            "soldAt": boundary.isoformat(),
            "valuation": current,
            **collection.wallet_dto(wallet),
            "capacity": capacity(session, user.id, settings),
        }
        session.add(
            PlantSale(
                id=sale_id,
                owner_id=user.id,
                plant_id=plant_id,
                request_id=body.request_id,
                payload_hash=digest,
                tokens=amount,
                receipt=receipt,
                sold_at=boundary,
            )
        )
        services.record_request(session, user.id, body, operation, digest, receipt)
        return receipt
