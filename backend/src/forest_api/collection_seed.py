"""Explicit, repeat-safe test offers. Prices/rarities are unapproved fixtures."""

from sqlalchemy import select

from forest_api import collection, services
from forest_api.collection_models import PackDefinition
from forest_api.collection_schemas import PackContract, PublishPack
from forest_api.models import GameCatalogue, Species, Variant


def seed_collection(session, settings):
    if settings.environment not in {"local", "test"}:
        raise ValueError("Development collection is disabled outside local/test")
    with session.begin():
        # This fixture only extends the development oak catalogue, never custom data.
        session.scalar(select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update())
        catalogue = services.get_catalogue_state(session, settings)
        if not catalogue.is_fixture or catalogue.version != "development-oak-v1":
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
