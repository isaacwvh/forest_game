"""Explicit, repeat-safe test offers. Prices/rarities are unapproved fixtures."""

from decimal import Decimal

from sqlalchemy import select

from forest_api import collection, services
from forest_api.collection_models import ExchangeOffer, PackDefinition
from forest_api.collection_schemas import PackContract, PublishPack, SpeciesPackContract
from forest_api.models import (
    AttractionProfile,
    BehaviourProfile,
    GameCatalogue,
    GrowthProfile,
    PlantStage,
    Species,
    Variant,
)
from forest_api.schemas import STAGES

COLLECTION_FIXTURE_VERSION = "development-woodland-v2"


def seed_legacy_collection(session, settings):
    """Retained schema-1 bootstrap, also used by legacy compatibility tests."""
    if settings.environment not in {"local", "test"}:
        raise ValueError("Development collection is disabled outside local/test")
    with session.begin():
        # This fixture only extends the development oak catalogue, never custom data.
        session.scalar(select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update())
        catalogue = services.get_catalogue_state(session, settings)
        if not catalogue.is_fixture or catalogue.version not in {
            "development-oak-v1",
            COLLECTION_FIXTURE_VERSION,
        }:
            raise ValueError("Collection fixture requires the development catalogue")
        if session.get(PackDefinition, ("woodland", 1)) is not None:
            return
        species = session.get(Species, "oak")
        profiles = services.profile_refs(species).model_dump(mode="json", by_alias=True)
        pools = []
        for variant_id, rarity, weight in [
            ("standard", "common", 75),
            ("blue", "rare", 20),
            ("vined", "legendary", 5),
        ]:
            variant = session.get(Variant, ("oak", variant_id))
            variant.rarity = rarity
            pools.append(
                {
                    "rarity": rarity,
                    "weight": weight,
                    "outcomes": [
                        {
                            "speciesId": "oak",
                            "variantId": variant_id,
                            "profiles": profiles,
                        }
                    ],
                }
            )
        session.flush()
        definition = PackContract.model_validate(
            {
                "displayName": "Woodland Pack",
                "description": "One oak sprout. Development prices and odds are provisional.",
                "rarities": pools,
            }
        )
        collection.publish_in_transaction(
            session,
            settings,
            PublishPack(
                pack_id="woodland",
                version=1,
                is_fixture=True,
                definition=definition,
                offer_id="woodland",
                offer_version=1,
                token_cost=5,
            ),
        )

        # A second immediately available pack tests separate pools without new art.
        blue = PackContract.model_validate(
            {
                "displayName": "Blue Oak Pack",
                "description": "One guaranteed blue oak sprout. Development fixture.",
                "rarities": [pools[1]],
            }
        )
        collection.publish_in_transaction(
            session,
            settings,
            PublishPack(
                pack_id="blue_oak",
                version=1,
                is_fixture=True,
                definition=blue,
                offer_id="blue_oak",
                offer_version=1,
                token_cost=8,
            ),
        )


def seed_collection(session, settings):
    """Upgrade fixture offers, not owned packs; repeated calls never re-enable sales."""
    seed_legacy_collection(session, settings)
    with session.begin():
        catalogue = session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update()
        )
        if session.get(PackDefinition, ("woodland", 2)) is not None:
            return
        oak = session.get(Species, "oak")
        oak.rarity = "common"
        moon = session.get(Species, "moonwillow")
        if moon is not None:
            raise ValueError("Refusing to replace an existing Moonwillow definition")
        # Dedicated neutral fixtures, not approved balance derived from artwork.
        session.add_all(
            [
                GrowthProfile(
                    id="dev_moonwillow_growth",
                    version=1,
                    thresholds={
                        "sprout": 0,
                        "seedling": 100_000_000,
                        "young": 400_000_000,
                        "adult": 1_000_000_000,
                    },
                    maximum_growth_micro_units=1_000_000_000,
                ),
                BehaviourProfile(
                    id="dev_moonwillow_behaviour",
                    version=1,
                    rules={
                        "schemaVersion": 1,
                        "metricMultipliers": {"steps": 1},
                        "conditionalModifiers": [],
                        "gardenEffects": [],
                    },
                ),
                AttractionProfile(
                    id="dev_moonwillow_attraction",
                    version=1,
                    stage_attraction={
                        "sprout": 2_000_000,
                        "seedling": 5_000_000,
                        "young": 12_000_000,
                        "adult": 20_000_000,
                    },
                    gameplay_tags=["tree", "woodland"],
                ),
            ]
        )
        session.flush()
        moon = Species(
            id="moonwillow",
            display_name="Moonwillow",
            rarity="common",
            description="Development fixture; balance and clearance radius are provisional.",
            clearance_radius=Decimal("1.100"),
            enabled=True,
            is_fixture=True,
            growth_profile_id="dev_moonwillow_growth",
            growth_profile_version=1,
            behaviour_profile_id="dev_moonwillow_behaviour",
            behaviour_profile_version=1,
            attraction_profile_id="dev_moonwillow_attraction",
            attraction_profile_version=1,
        )
        session.add(moon)
        session.flush()
        for variant in ("standard", "golden"):
            session.add(
                Variant(
                    species_id="moonwillow",
                    variant_id=variant,
                    display_name=variant.title(),
                    description="Development fixture",
                    rarity="development_unbalanced",
                    enabled=True,
                    asset_catalog_key="assets/moonwillow/v1/moonwillow.json",
                    asset_catalog_version="1.0.0",
                )
            )
        session.flush()
        for variant in ("standard", "golden"):
            for stage in STAGES:
                session.add(
                    PlantStage(
                        species_id="moonwillow",
                        variant_id=variant,
                        stage=stage,
                        model_key=f"assets/moonwillow/v1/models/moonwillow-{stage}-{variant}.usdz",
                        thumbnail_key=f"assets/moonwillow/v1/ui/moonwillow-{stage}-{variant}.png",
                    )
                )
        session.flush()

        def member(species, weights):
            variants = []
            for variant_id, weight in weights:
                variant = session.get(Variant, (species.id, variant_id))
                profiles = services.profile_refs(species).model_dump(mode="json", by_alias=True)
                for kind in services.PROFILE_MODELS:
                    override = getattr(variant, f"{kind}_profile_id")
                    if override is not None:
                        profiles[kind] = {
                            "id": override,
                            "version": getattr(variant, f"{kind}_profile_version"),
                        }
                variants.append({"variantId": variant_id, "weight": weight, "profiles": profiles})
            return {"speciesId": species.id, "variants": variants}

        members = [
            member(oak, [("standard", 75), ("blue", 20), ("vined", 5)]),
            member(moon, [("standard", 90), ("golden", 10)]),
        ]
        catalogue.version = COLLECTION_FIXTURE_VERSION
        woodland = SpeciesPackContract.model_validate(
            {
                "displayName": "Woodland Pack",
                "description": (
                    "One sprout: Oak or Moonwillow equally, then a weighted variant. "
                    "Provisional development odds."
                ),
                "rarities": [{"rarity": "common", "weight": 100, "species": members}],
            }
        )
        collection.publish_in_transaction(
            session,
            settings,
            PublishPack(
                pack_id="woodland",
                version=2,
                definition=woodland,
                is_fixture=True,
                offer_id="woodland",
                offer_version=2,
                token_cost=5,
            ),
        )
        session.flush()
        moonpack = SpeciesPackContract.model_validate(
            {
                "displayName": "Moonwillow Pack",
                "description": (
                    "One Moonwillow sprout: Standard 90%, Golden 10%. Development fixture."
                ),
                "rarities": [{"rarity": "common", "weight": 100, "species": [members[1]]}],
            }
        )
        collection.publish_in_transaction(
            session,
            settings,
            PublishPack(
                pack_id="moonwillow",
                version=1,
                definition=moonpack,
                is_fixture=True,
                offer_id="moonwillow",
                offer_version=1,
                token_cost=8,
            ),
        )
        legacy_blue = session.get(ExchangeOffer, ("blue_oak", 1))
        if legacy_blue is not None:
            legacy_blue.active = False
