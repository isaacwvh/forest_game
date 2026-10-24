"""Explicit development publication and repeat-safe adult test grant."""

from copy import deepcopy

from sqlalchemy import func, select

from forest_api import collection, services
from forest_api.collection_models import PackDefinition
from forest_api.collection_schemas import PublishPack, parse_pack
from forest_api.models import BehaviourProfile, GameCatalogue, OwnedPlant, Species, User
from forest_api.schemas import BehaviourDefinition

SKILLS_CATALOGUE = "development-skills-v1"
SLEEPING_DEW = {
    "componentVersion": 1,
    "id": "sleeping_dew",
    "name": "Sleeping Dew",
    "description": "While this fully grown Moonwillow is planted, all garden plants gain 4% "
    "more water from activity. Multiple Sleeping Dew skills do not stack.",
    "system": "growth",
    "scope": "water",
    "target": "all_planted_plants",
    "minimumStage": "adult",
    "operation": "percent",
    "magnitude": {"type": "fixed", "value": "0.04"},
    "stackingGroup": "moonwillow_sleeping_dew",
    "stackingRule": "strongest",
}


def seed_skills(session, settings):
    if settings.environment not in {"local", "test"}:
        raise ValueError("Development skills are restricted to local/test")
    with session.begin():
        catalogue = session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update()
        )
        if (
            catalogue is None
            or not catalogue.is_fixture
            or catalogue.version not in {"development-woodland-v2", SKILLS_CATALOGUE}
        ):
            raise ValueError("Seed the development collection before skills")
        moon = session.get(Species, "moonwillow")
        previous = session.get(BehaviourProfile, ("dev_moonwillow_behaviour", 1))
        if moon is None or previous is None:
            raise ValueError("The development Moonwillow catalogue is incomplete")
        rules = deepcopy(previous.rules)
        rules.update(schemaVersion=2, gardenEffects=[SLEEPING_DEW])
        rules = BehaviourDefinition.model_validate(rules).model_dump(mode="json", by_alias=True)
        existing = session.get(BehaviourProfile, ("dev_moonwillow_behaviour", 2))
        if existing is not None:
            if existing.rules != rules:
                raise ValueError("Refusing to replace an existing skill profile")
            return
        session.add(BehaviourProfile(id="dev_moonwillow_behaviour", version=2, rules=rules))
        session.flush()
        moon.behaviour_profile_version = 2
        for pack_id, old_version, new_version, price in (
            ("woodland", 2, 3, 5),
            ("moonwillow", 1, 2, 8),
        ):
            definition = deepcopy(session.get(PackDefinition, (pack_id, old_version)).definition)
            for pool in definition["rarities"]:
                for species in pool["species"]:
                    if species["speciesId"] == "moonwillow":
                        for variant in species["variants"]:
                            variant["profiles"]["behaviour"] = {
                                "id": "dev_moonwillow_behaviour",
                                "version": 2,
                            }
            session.flush()
            collection.publish_in_transaction(
                session,
                settings,
                PublishPack(
                    pack_id=pack_id,
                    version=new_version,
                    definition=parse_pack(definition),
                    is_fixture=True,
                    offer_id=pack_id,
                    offer_version=new_version,
                    token_cost=price,
                ),
            )
        catalogue.version = SKILLS_CATALOGUE


def grant_adult_moonwillow(session, settings, username, *, dry_run=False):
    if settings.environment not in {"local", "test"}:
        raise ValueError("Development grants are restricted to local/test")
    with session.begin():
        user = session.scalar(
            select(User).where(User.username == username.lower()).with_for_update()
        )
        if user is None or user.status != "active":
            raise ValueError("Specify an existing active game username")
        services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        source, reference = "development_grant", "sleeping-dew-adult-v1"
        plant = session.scalar(
            select(OwnedPlant).where(
                OwnedPlant.owner_id == user.id,
                OwnedPlant.acquisition_source == source,
                OwnedPlant.acquisition_reference == reference,
            )
        )
        if dry_run:
            return {
                "username": user.username,
                "userId": str(user.id),
                "dryRun": True,
                "existingPlantId": str(plant.id) if plant else None,
            }
        if plant is None:
            moon = session.get(Species, "moonwillow")
            if moon is None or (moon.behaviour_profile_id, moon.behaviour_profile_version) != (
                "dev_moonwillow_behaviour",
                2,
            ):
                raise ValueError("Publish Sleeping Dew before granting the test plant")
            plant = services.award_plant(
                session, user.id, "moonwillow", "standard", source, reference
            )
            if (plant.behaviour_profile_id, plant.behaviour_profile_version) != (
                "dev_moonwillow_behaviour",
                2,
            ):
                raise ValueError("The Standard variant must resolve to the Sleeping Dew profile")
            profile = services.PlantPresenter(session).profile(
                "growth", plant.growth_profile_id, plant.growth_profile_version
            )
            if profile.maximum_growth_micro_units != profile.thresholds["adult"]:
                raise ValueError("Test grant requires adult to be terminal maturity")
            plant.growth_micro_units = profile.maximum_growth_micro_units
            plant.fractional_state = {}
            plant.first_matured_at = session.scalar(select(func.clock_timestamp()))
            session.flush()
        return {
            "username": user.username,
            "userId": str(user.id),
            "plantId": str(plant.id),
            "growthMicroUnits": str(plant.growth_micro_units),
            "skill": "sleeping_dew",
        }
