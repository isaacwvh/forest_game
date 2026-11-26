"""Versioned token exchange and rarity-first draws; no client reward authority."""

import secrets
from pathlib import PurePosixPath
from uuid import uuid4

from sqlalchemy import func, select, tuple_, update

from forest_api import services
from forest_api.collection_models import (
    CollectionEvent,
    ExchangeOffer,
    OwnedPack,
    PackDefinition,
    PackMember,
    PackOpening,
)
from forest_api.collection_schemas import PackOutcome, outcomes, parse_pack
from forest_api.errors import ApiError
from forest_api.models import OwnedPlant, PlantStage, Species, Variant
from forest_api.schemas import STAGES
from forest_api.visitor_models import VisitorWallet

MAX_INTEGER = 9223372036854775807


def checked(value):
    if not 0 <= value <= MAX_INTEGER:
        raise ApiError(409, "amount_overflow", "The requested amount exceeds the supported limit")
    return value


def wallet_for(session, owner):
    wallet = session.get(VisitorWallet, owner)
    if wallet is None:
        wallet = VisitorWallet(
            owner_id=owner, tokens=0, hosted_active=0, hosted_offline=0, economy_version=0
        )
        session.add(wallet)
        session.flush()
    return wallet


def wallet_dto(wallet):
    return {
        "tokenBalance": str(wallet.tokens),
        "gemBalance": str(wallet.gems or 0),
        "economyVersion": wallet.economy_version,
    }


def pack_contract(session, settings, pack_id, version):
    row = session.get(PackDefinition, (pack_id, version))
    if row is None or (row.is_fixture and settings.environment not in {"local", "test"}):
        raise ApiError(503, "pack_unavailable", "This pack definition is unavailable")
    return row, parse_pack(row.definition)


def validate_dependencies(session, definition, *, publishing=False, fixture=False):
    members = [(pool, outcome) for pool in definition.rarities for outcome in outcomes(pool)]
    keys = {(o.species_id, o.variant_id) for _, o in members}
    species_by_id = {
        row.id: row
        for row in session.execute(
            select(Species.id, Species.enabled, Species.is_fixture, Species.rarity).where(
                Species.id.in_({key[0] for key in keys})
            )
        )
    }
    variants = {
        (row.species_id, row.variant_id): row
        for row in session.execute(
            select(
                Variant.species_id,
                Variant.variant_id,
                Variant.enabled,
                Variant.rarity,
                Variant.asset_catalog_key,
                Variant.asset_catalog_version,
            ).where(tuple_(Variant.species_id, Variant.variant_id).in_(keys))
        )
    }
    stages_by_variant = {}
    for row in session.execute(
        select(
            PlantStage.species_id,
            PlantStage.variant_id,
            PlantStage.stage,
            PlantStage.model_key,
            PlantStage.thumbnail_key,
        ).where(tuple_(PlantStage.species_id, PlantStage.variant_id).in_(keys))
    ):
        stages_by_variant.setdefault((row.species_id, row.variant_id), []).append(row)
    profiles = {}
    for kind, model in services.PROFILE_MODELS.items():
        refs = [getattr(outcome.profiles, kind) for _, outcome in members]
        profiles[kind] = set(
            session.execute(
                select(model.id, model.version).where(
                    tuple_(model.id, model.version).in_({(ref.id, ref.version) for ref in refs})
                )
            ).tuples()
        )
    for pool, outcome in members:
        key = outcome.species_id, outcome.variant_id
        species = species_by_id.get(key[0])
        variant = variants.get(key)
        if species is None or variant is None:
            raise ApiError(409, "invalid_pack", "Pack refers to an unknown plant")
        if publishing and (not species.enabled or not variant.enabled):
            raise ApiError(409, "invalid_pack", "New packs require available plants")
        if publishing and species.is_fixture and not fixture:
            raise ApiError(409, "invalid_pack", "Fixture plants require a fixture pack")
        expected_rarity = species.rarity if definition.schema_version == 2 else variant.rarity
        if publishing and expected_rarity != pool.rarity:
            raise ApiError(409, "invalid_pack", "Outcome rarity disagrees with the catalogue")
        for kind, available in profiles.items():
            ref = getattr(outcome.profiles, kind)
            if (ref.id, ref.version) not in available:
                raise ApiError(409, "invalid_pack", "Pack profile version does not exist")
        stages = stages_by_variant.get(key, [])
        if {row.stage for row in stages} != set(STAGES):
            raise ApiError(409, "invalid_pack", "Pack requires all four plant stages")
        prefix = f"assets/{outcome.species_id}/v1/"
        paths = [(variant.asset_catalog_key, ".json")]
        paths += [(row.model_key, ".usdz") for row in stages]
        paths += [(row.thumbnail_key, ".png") for row in stages]
        if not variant.asset_catalog_version or any(
            not path.startswith(prefix)
            or "\\" in path
            or ".." in PurePosixPath(path).parts
            or not path.endswith(extension)
            for path, extension in paths
        ):
            raise ApiError(409, "invalid_pack", "Pack asset references are incomplete or unsafe")


def publish(session, settings, body):
    """Trusted CLI only. No HTTP authoring route or implicit catalogue membership."""
    with session.begin():
        publish_in_transaction(session, settings, body)


def publish_in_transaction(session, settings, body):
    """Caller owns the transaction; also used for atomic fixture publication."""
    if body.is_fixture and settings.environment not in {"local", "test"}:
        raise ValueError("Fixture packs cannot be published outside local/test")
    # Exclusive catalogue lock coordinates publication with all account paths.
    services.get_catalogue_state(session, settings)
    from forest_api.models import GameCatalogue

    session.scalar(select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update())
    validate_dependencies(session, body.definition, publishing=True, fixture=body.is_fixture)
    if session.get(ExchangeOffer, (body.offer_id, body.offer_version)) is not None:
        raise ApiError(409, "version_exists", "Offer version already exists")
    row = session.get(PackDefinition, (body.pack_id, body.version))
    canonical = body.definition.model_dump(mode="json", by_alias=True)
    if row is not None:
        if row.definition != canonical or row.is_fixture != body.is_fixture:
            raise ApiError(409, "version_exists", "Pack versions are immutable")
    else:
        session.add(
            PackDefinition(
                id=body.pack_id,
                version=body.version,
                is_fixture=body.is_fixture,
                definition=canonical,
            )
        )
        session.flush()
        for pool in body.definition.rarities:
            for outcome in outcomes(pool):
                pinned = {}
                for kind in services.PROFILE_MODELS:
                    ref = getattr(outcome.profiles, kind)
                    pinned[f"{kind}_profile_id"] = ref.id
                    pinned[f"{kind}_profile_version"] = ref.version
                session.add(
                    PackMember(
                        pack_id=body.pack_id,
                        pack_version=body.version,
                        species_id=outcome.species_id,
                        variant_id=outcome.variant_id,
                        **pinned,
                    )
                )
    session.execute(
        update(ExchangeOffer).where(ExchangeOffer.id == body.offer_id).values(active=False)
    )
    session.add(
        ExchangeOffer(
            id=body.offer_id,
            version=body.offer_version,
            pack_id=body.pack_id,
            pack_version=body.version,
            token_cost=body.token_cost,
            currency=body.currency,
            active=True,
        )
    )


def choose(definition, randbelow=secrets.randbelow):
    """Rarity totals never depend on the number of outcomes. Stable sort is explicit."""
    pools = sorted(definition.rarities, key=lambda row: row.rarity)
    roll = randbelow(sum(pool.weight for pool in pools))
    for pool in pools:
        if roll < pool.weight:
            if definition.schema_version == 1:
                legacy = sorted(pool.outcomes, key=lambda row: (row.species_id, row.variant_id))
                return pool.rarity, legacy[randbelow(len(legacy))]
            species = sorted(pool.species, key=lambda row: row.species_id)
            selected = species[randbelow(len(species))]
            variants = sorted(selected.variants, key=lambda row: row.variant_id)
            variant_roll = randbelow(sum(v.weight for v in variants))
            for variant in variants:
                if variant_roll < variant.weight:
                    return pool.rarity, PackOutcome(
                        species_id=selected.species_id,
                        variant_id=variant.variant_id,
                        profiles=variant.profiles,
                        clearance_radius=variant.clearance_radius,
                    )
                variant_roll -= variant.weight
            raise RuntimeError("Random source returned an out-of-range variant value")
        roll -= pool.weight
    raise RuntimeError("Random source returned an out-of-range value")


def retire_offer(session, settings, offer_id, version):
    """Stop sales without changing the historical pack entitlement."""
    from forest_api.models import GameCatalogue

    with session.begin():
        services.get_catalogue_state(session, settings)
        session.scalar(select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update())
        offer = session.get(ExchangeOffer, (offer_id, version))
        if offer is None:
            raise ApiError(404, "offer_not_found", "Offer version not found")
        offer.active = False


def definition_dto(row, definition):
    total = sum(pool.weight for pool in definition.rarities)
    return {
        "packId": row.id,
        "version": row.version,
        "isFixture": row.is_fixture,
        **definition.model_dump(mode="json", by_alias=True),
        "totalWeight": total,
    }


def read_definition(session, settings, identity, pack_id, version):
    with session.begin():
        services.get_user(session, identity)
        row, definition = pack_contract(session, settings, pack_id, version)
        return definition_dto(row, definition)


def pack_dto(pack):
    return {
        "ownedPackId": str(pack.id),
        "packId": pack.pack_id,
        "version": pack.pack_version,
        "acquiredAt": pack.acquired_at.isoformat(),
    }


def read(session, settings, identity, *, kind="summary", limit=30, after=None, view="full"):
    for attempt in range(2):
        try:
            return _read_once(
                session, settings, identity, kind=kind, limit=limit, after=after, view=view
            )
        except ApiError as error:
            # A lock wait can cross Monday after preparation. End the account
            # transaction before recovering the newly required week.
            if kind != "summary" or error.code != "shop_preparing" or attempt:
                raise


def _read_once(session, settings, identity, *, kind="summary", limit=30, after=None, view="full"):
    from forest_api import shop

    clock = session.info.get("clock") or (lambda: session.scalar(select(func.clock_timestamp())))
    if kind == "summary" and view in {"full", "shop"}:
        with session.begin():
            services.get_user(session, identity)
        if not shop.ensure_current(session, clock):
            raise ApiError(503, "shop_preparing", "Shop is recovering missed weeks. Please retry")
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        if kind == "summary":
            wallet = wallet_for(session, user.id)
            from forest_api import milestones
            from forest_api.inventory_management import capacity

            catalogue = services.get_catalogue_state(session, settings)
            result = {
                **wallet_dto(wallet),
                "catalogVersion": catalogue.version,
                "capacity": capacity(session, user.id, settings),
            }
            if view in {"full", "home"}:
                result["milestones"] = milestones.summary(session, user.id, catalogue, wallet)
            if view in {"home", "packs"}:
                return {**result, "offers": []}

            offers = []
            for offer in session.scalars(
                select(ExchangeOffer).where(ExchangeOffer.active).order_by(ExchangeOffer.id)
            ):
                key = offer.pack_id, offer.pack_version
                cache = session.info.get("pack_presentation_cache")
                use_cache = cache is not None and settings.catalogue_cache_seconds > 0
                pack = cache.get(key) if use_cache else None
                if pack is None:
                    row, definition = pack_contract(session, settings, *key)
                    pack = definition_dto(row, definition)
                    if use_cache:
                        cache.put(key, pack, settings.catalogue_cache_seconds)
                offers.append(
                    {
                        "offerId": offer.id,
                        "offerVersion": offer.version,
                        "tokenCost": str(offer.token_cost),
                        "currency": offer.currency,
                        "pack": pack,
                    }
                )
            from forest_api import item_commerce, items

            now = clock()
            rotation = shop.current(session, user.id, now)
            return {
                **result,
                "offers": offers,
                "itemOffers": item_commerce.offers(session, user.id, now),
                "shop": rotation,
                "itemCapacity": items.capacity(session, user.id),
            }
        if kind == "packs":
            query = select(OwnedPack).where(
                OwnedPack.owner_id == user.id,
                ~select(PackOpening.id).where(PackOpening.pack_id == OwnedPack.id).exists(),
            )
            if after:
                cursor = session.get(OwnedPack, after)
                if cursor is None or cursor.owner_id != user.id:
                    raise ApiError(400, "invalid_cursor", "Refresh the pack list")
                query = query.where(
                    tuple_(OwnedPack.acquired_at, OwnedPack.id) > (cursor.acquired_at, cursor.id)
                )
            rows = session.scalars(
                query.order_by(OwnedPack.acquired_at, OwnedPack.id).limit(limit + 1)
            ).all()
            return {
                "packs": [pack_dto(row) for row in rows[:limit]],
                "nextCursor": str(rows[limit - 1].id) if len(rows) > limit else None,
            }
        query = (
            select(PackOpening.id, CollectionEvent.receipt)
            .join(CollectionEvent, CollectionEvent.id == PackOpening.event_id)
            .where(PackOpening.owner_id == user.id, CollectionEvent.owner_id == user.id)
        )
        if after:
            cursor = session.get(PackOpening, after)
            if cursor is None or cursor.owner_id != user.id:
                raise ApiError(400, "invalid_cursor", "Refresh the opening history")
            query = query.where(
                tuple_(PackOpening.opened_at, PackOpening.id) < (cursor.opened_at, cursor.id)
            )
        if view == "latest":
            row = session.execute(
                query.order_by(PackOpening.opened_at.desc(), PackOpening.id.desc()).limit(1)
            ).first()
            return {"openings": [row.receipt] if row else [], "nextCursor": None}
        rows = session.execute(
            query.order_by(PackOpening.opened_at.desc(), PackOpening.id.desc()).limit(limit + 1)
        ).all()
        return {
            "openings": [row.receipt for row in rows[:limit]],
            "nextCursor": str(rows[limit - 1].id) if len(rows) > limit else None,
        }


def durable_replay(session, owner, request_id, operation, digest):
    previous = services.replay(session, owner, request_id, operation, digest)
    if previous is not None:
        return previous
    event = session.scalar(
        select(CollectionEvent).where(
            CollectionEvent.owner_id == owner, CollectionEvent.request_id == request_id
        )
    )
    if event is not None:
        if event.operation != operation or event.payload_hash != digest:
            raise ApiError(409, "idempotency_conflict", "Request ID was used for different input")
        return event.receipt


def mutate(session, settings, identity, body, clock, *, pack_id=None, randbelow=None):
    operation = "pack_open" if pack_id else "token_exchange"
    digest = services.request_hash(operation + (":" + str(pack_id) if pack_id else ""), body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = durable_replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return previous
        garden = services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        boundary = clock()
        # The B6 throttle is account-wide and checks replays before charging quota.
        from forest_api.visitors import throttle

        throttle(session, user.id, boundary)
        wallet = wallet_for(session, user.id)
        event_id = uuid4()
        delta = 0
        gem_delta = 0
        if pack_id is None:
            from forest_api.inventory_management import capacity

            limits = capacity(session, user.id, settings)
            if limits["unopenedPacks"] + body.quantity > settings.pack_capacity:
                raise ApiError(
                    409, "pack_capacity_full", "Pack storage full. Open a pack before buying more."
                )
            offer = session.get(ExchangeOffer, (body.offer_id, body.offer_version))
            if offer is None or not offer.active:
                raise ApiError(409, "stale_offer", "Refresh Shop to see the current offer")
            row, definition = pack_contract(session, settings, offer.pack_id, offer.pack_version)
            validate_dependencies(session, definition)
            require_woodland_client(session, row)
            cost = checked(offer.token_cost * body.quantity)
            if offer.currency == "gems":
                if wallet.gems < cost:
                    raise ApiError(409, "insufficient_gems", "You need more gems for this pack")
                wallet.gems -= cost
                gem_delta = -cost
            else:
                if wallet.tokens < cost:
                    raise ApiError(
                        409, "insufficient_tokens", "You need more visitor tokens for this exchange"
                    )
                wallet.tokens -= cost
                delta = -cost
            packs = [
                OwnedPack(
                    id=uuid4(),
                    owner_id=user.id,
                    pack_id=row.id,
                    pack_version=row.version,
                    exchange_id=event_id,
                    acquired_at=boundary,
                )
                for _ in range(body.quantity)
            ]
            receipt = {
                "requestId": str(body.request_id),
                "exchangeId": str(event_id),
                "offerId": offer.id,
                "offerVersion": offer.version,
                "quantity": body.quantity,
                "tokensSpent": str(cost if offer.currency == "tokens" else 0),
                "gemsSpent": str(cost if offer.currency == "gems" else 0),
                "currency": offer.currency,
                "packs": [pack_dto(pack) for pack in packs],
                "capacity": {**limits, "unopenedPacks": limits["unopenedPacks"] + body.quantity},
            }
        else:
            pack = session.scalar(
                select(OwnedPack)
                .where(OwnedPack.id == pack_id, OwnedPack.owner_id == user.id)
                .with_for_update()
            )
            if pack is None:
                raise ApiError(404, "pack_not_found", "Pack not found")
            opening = session.scalar(select(PackOpening).where(PackOpening.pack_id == pack.id))
            if opening is not None:
                receipt = session.get(CollectionEvent, opening.event_id).receipt
                services.record_request(session, user.id, body, operation, digest, receipt)
                return receipt
            from forest_api.inventory_management import capacity

            limits = capacity(session, user.id, settings)
            if limits["ownedPlants"] >= limits["plantLimit"]:
                raise ApiError(
                    409,
                    "plant_capacity_full",
                    "Plant collection full. Sell a stored plant to open this pack.",
                )
            row, definition = pack_contract(session, settings, pack.pack_id, pack.pack_version)
            validate_dependencies(session, definition)
            require_woodland_client(session, row)
            rarity, outcome = choose(definition, **({"randbelow": randbelow} if randbelow else {}))
            plant = OwnedPlant(
                id=uuid4(),
                owner_id=user.id,
                species_id=outcome.species_id,
                variant_id=outcome.variant_id,
                acquisition_source="pack_open",
                acquisition_reference=str(pack.id),
                clearance_radius=(
                    outcome.clearance_radius
                    or session.get(Species, outcome.species_id).properties.get(
                        "legacyClearanceRadius"
                    )
                    or session.get(Species, outcome.species_id).clearance_radius
                ),
                growth_micro_units=0,
                fractional_state={},
            )
            for kind in services.PROFILE_MODELS:
                ref = getattr(outcome.profiles, kind)
                setattr(plant, f"{kind}_profile_id", ref.id)
                setattr(plant, f"{kind}_profile_version", ref.version)
            session.add(plant)
            session.flush()
            from forest_api.discovery import record_reached

            record_reached(session, user.id, [plant], boundary)
            base_state = garden.state_version
            garden.state_version = checked(base_state + 1)
            # UUID ordering is not used for time semantics, only bounded pagination.
            opening_id = uuid4()
            from forest_api.expeditions import observe_opening

            observe_opening(session, user.id, boundary, opening_id)
            receipt = {
                "requestId": str(body.request_id),
                "openingId": str(opening_id),
                "ownedPackId": str(pack.id),
                "packId": row.id,
                "packVersion": row.version,
                "rarity": rarity,
                "openedAt": boundary.isoformat(),
                "inventoryBaseStateVersion": base_state,
                "gardenStateVersion": garden.state_version,
                "capacity": {
                    **limits,
                    "ownedPlants": limits["ownedPlants"] + 1,
                    "storedPlants": limits["storedPlants"] + 1,
                    "unopenedPacks": limits["unopenedPacks"] - 1,
                },
                "plant": services.PlantPresenter(session)
                .plant(plant, None)
                .model_dump(mode="json", by_alias=True),
            }
        wallet.economy_version = checked(wallet.economy_version + 1)
        receipt.update(wallet_dto(wallet))
        session.add(
            CollectionEvent(
                id=event_id,
                owner_id=user.id,
                request_id=body.request_id,
                operation=operation,
                payload_hash=digest,
                token_delta=delta,
                gem_delta=gem_delta,
                receipt=receipt,
                created_at=boundary,
            )
        )
        session.flush()
        if pack_id is None:
            session.add_all(packs)
        else:
            session.add(
                PackOpening(
                    id=opening_id,
                    owner_id=user.id,
                    pack_id=pack.id,
                    event_id=event_id,
                    plant_id=plant.id,
                    rarity=rarity,
                    opened_at=boundary,
                )
            )
        services.record_request(session, user.id, body, operation, digest, receipt)
        session.flush()
        return receipt


def require_woodland_client(session, pack):
    if pack.version >= 20 and pack.id in {"woodland", "select-woodland", "premium-woodland"}:
        if not session.info.get("woodland_release"):
            raise ApiError(
                426, "woodland_client_update_required", "Update the app to use Woodland packs"
            )
