"""Explicit, atomic Woodland publication and pinned conversion compatibility."""

import json
from copy import deepcopy
from datetime import timedelta
from decimal import Decimal
from importlib.resources import files

from sqlalchemy import delete, func, select, text, update

from forest_api import collection, services, visitors
from forest_api.calculations import MetricRate
from forest_api.collection_models import ExchangeOffer
from forest_api.collection_schemas import PublishPack
from forest_api.models import (
    AttractionProfile,
    BehaviourProfile,
    GameCatalogue,
    Garden,
    GrowthProfile,
    OwnedPlant,
    PlantStage,
    Species,
    User,
    Variant,
)
from forest_api.schemas import BehaviourDefinition
from forest_api.woodland_models import DailySkillActivity

VERSION = "woodland-v1"


def release():
    return json.loads(
        files("forest_api").joinpath("data/woodland-v1.json").read_text(encoding="utf-8")
    )


def plant_rates(definition, rates):
    """Use per-profile conversions without recrediting accepted activity quantities."""
    result = dict(rates)
    for metric in rates:
        override = definition.conversion_rates.get(metric)
        if override is None and metric.startswith("workout_minutes."):
            override = definition.conversion_rates.get("workout_minutes.*")
        if override:
            result[metric] = MetricRate.model_validate(override)
    return result


def update_daily_flights(session, owner, days, today):
    for day in days:
        delta = day.metrics.get("flights_climbed", {}).get("newlyEligible", "0")
        amount = int(Decimal(str(delta)))
        if amount:
            row = session.get(DailySkillActivity, (owner, day.game_date))
            if row is None:
                session.add(
                    DailySkillActivity(owner_id=owner, game_date=day.game_date, flights=amount)
                )
            else:
                row.flights += amount
    session.execute(
        delete(DailySkillActivity).where(
            DailySkillActivity.owner_id == owner,
            DailySkillActivity.game_date < today - timedelta(days=7),
        )
    )
    session.flush()


def publish(session, settings, *, apply=False, clock=None):
    data = release()
    for plant in data["species"]:
        BehaviourDefinition.model_validate(plant["behaviour"])
    with session.begin():
        session.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended('forest-content-release', 0))")
        )
        owners = list(session.scalars(select(User).order_by(User.id).with_for_update()))
        gardens = list(session.scalars(select(Garden).order_by(Garden.id).with_for_update()))
        catalogue = session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update()
        )
        if catalogue is None or catalogue.version not in {"launch-visitors-v2", VERSION}:
            raise ValueError("Publish the scheduled visitor economy before Woodland")
        if catalogue.version == VERSION:
            return {"version": VERSION, "alreadyPublished": True}
        report = {
            "version": VERSION,
            "species": 30,
            "variants": 47,
            "accounts": len(owners),
            "applied": apply,
        }
        if not apply:
            return report
        boundary = clock() if clock else session.scalar(select(func.clock_timestamp()))
        for garden in gardens:
            visitors.settle(session, settings, garden, boundary)
        for plant in data["species"]:
            identifier = plant["id"]
            profile_id = "woodland_" + identifier
            session.add_all(
                [
                    GrowthProfile(
                        id=profile_id,
                        version=1,
                        thresholds=plant["growth"],
                        maximum_growth_micro_units=plant["growth"]["adult"],
                    ),
                    BehaviourProfile(id=profile_id, version=1, rules=plant["behaviour"]),
                    AttractionProfile(
                        id=profile_id,
                        version=1,
                        stage_attraction=plant["attraction"],
                        gameplay_tags=plant["tags"],
                    ),
                ]
            )
            session.flush()
            species = session.get(Species, identifier)
            old_radius = species.clearance_radius if species else None
            if species is None:
                species = Species(id=identifier)
                session.add(species)
            species.display_name, species.rarity = plant["name"], plant["rarity"]
            species.description, species.clearance_radius = (
                plant["description"],
                Decimal(plant["radius"]),
            )
            species.enabled, species.is_fixture = True, False
            species.properties = {
                **(species.properties or {}),
                "release": VERSION,
                **({"legacyClearanceRadius": str(old_radius)} if old_radius else {}),
            }
            for kind in services.PROFILE_MODELS:
                setattr(species, f"{kind}_profile_id", profile_id)
                setattr(species, f"{kind}_profile_version", 1)
            session.flush()
            for variant_id in plant["variants"]:
                variant = session.get(Variant, (identifier, variant_id))
                if variant is None:
                    variant = Variant(species_id=identifier, variant_id=variant_id)
                    session.add(variant)
                variant.display_name = variant_id.replace("-", " ").title()
                variant.description, variant.rarity = "", plant["rarity"]
                variant.enabled = True
                variant.asset_catalog_key = plant["assetManifest"]
                variant.asset_catalog_version = "1.0.0"
                for kind in services.PROFILE_MODELS:
                    setattr(variant, f"{kind}_profile_id", None)
                    setattr(variant, f"{kind}_profile_version", None)
                session.flush()
                for asset in plant["assets"]:
                    if asset["variant"] != variant_id:
                        continue
                    stage = session.get(PlantStage, (identifier, variant_id, asset["stage"]))
                    if stage is None:
                        stage = PlantStage(
                            species_id=identifier, variant_id=variant_id, stage=asset["stage"]
                        )
                        session.add(stage)
                    prefix = plant["assetManifest"].rsplit("/", 1)[0] + "/"
                    stage.model_key, stage.thumbnail_key = (
                        prefix + asset["file"],
                        prefix + asset["thumbnail"],
                    )
        session.add(
            GrowthProfile(
                id="woodland_starter_oak",
                version=1,
                thresholds={
                    "sprout": 0,
                    "seedling": 15000000,
                    "young": 75000000,
                    "adult": 150000000,
                },
                maximum_growth_micro_units=150000000,
            )
        )
        oak = session.get(Species, "oak")
        oak.properties = {
            **oak.properties,
            "starterGrowthProfile": {"id": "woodland_starter_oak", "version": 1},
        }
        # Existing skill-bearing Moonwillows improve prospectively; historical packs stay pinned.
        upgrades = {}
        for copy in session.scalars(
            select(OwnedPlant).where(OwnedPlant.species_id == "moonwillow")
        ):
            key = (copy.behaviour_profile_id, copy.behaviour_profile_version)
            previous = session.get(BehaviourProfile, key)
            if not any(
                e.get("stackingGroup") == "moonwillow_sleeping_dew"
                for e in previous.rules.get("gardenEffects", [])
            ):
                continue
            if key not in upgrades:
                rules = deepcopy(previous.rules)
                for effect in rules["gardenEffects"]:
                    if effect.get("stackingGroup") == "moonwillow_sleeping_dew":
                        effect["magnitude"] = {"value": "0.08"}
                        effect["description"] = "All plants gain 8% more water."
                name = "woodland_upgrade_" + str(len(upgrades))
                upgrades[key] = name
                session.add(BehaviourProfile(id=name, version=1, rules=rules))
                session.flush()
            copy.behaviour_profile_id, copy.behaviour_profile_version = upgrades[key], 1
        session.flush()
        catalogue.version, catalogue.is_fixture = VERSION, False
        for pack in data["packs"]:
            pools = []
            for rarity, weight in zip(
                ("common", "rare", "epic", "legendary"), pack["weights"], strict=True
            ):
                members = []
                for plant in data["species"]:
                    if plant["rarity"] == rarity:
                        refs = {
                            k: {"id": "woodland_" + plant["id"], "version": 1}
                            for k in services.PROFILE_MODELS
                        }
                        members.append(
                            {
                                "speciesId": plant["id"],
                                "variants": [
                                    {
                                        "variantId": v,
                                        "weight": w,
                                        "profiles": refs,
                                        "clearanceRadius": float(plant["radius"]),
                                    }
                                    for v, w in plant["variants"].items()
                                ],
                            }
                        )
                pools.append({"rarity": rarity, "weight": weight, "species": members})
            collection.publish_in_transaction(
                session,
                settings,
                PublishPack.model_validate(
                    {
                        "packId": pack["id"],
                        "version": 20,
                        "offerId": pack["id"],
                        "offerVersion": 20,
                        "tokenCost": pack["cost"],
                        "currency": pack["currency"],
                        "definition": {
                            "schemaVersion": 2,
                            "displayName": pack["name"],
                            "description": "One Woodland sprout.",
                            "rarities": pools,
                        },
                    }
                ),
            )
        session.execute(
            update(ExchangeOffer).where(ExchangeOffer.id == "moonwillow").values(active=False)
        )
        session.flush()
        for garden in gardens:
            garden.state_version = collection.checked(garden.state_version + 1)
            visitors.VisitorAccounting(settings).after_change(session, garden, boundary)
        return {**report, "effectiveAt": boundary.isoformat()}
