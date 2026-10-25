"""Approved two-species balance publication. Immutable old plants/packs are retained."""

from copy import deepcopy
from datetime import timedelta
from decimal import Decimal

from sqlalchemy import func, select, update

from forest_api import collection
from forest_api.activity_inputs import WORKOUT_TYPES
from forest_api.calculations import MICRO, CalculationRules
from forest_api.collection_models import ExchangeOffer
from forest_api.collection_schemas import PublishPack, SpeciesPackContract
from forest_api.models import (
    AttractionProfile,
    BehaviourProfile,
    EconomyConfig,
    GameCatalogue,
    GrowthProfile,
    PlantStage,
    SkillPolicy,
    Species,
    Variant,
)
from forest_api.schemas import STAGES, BehaviourDefinition
from forest_api.skill_rules import CAPS_V1
from forest_api.skill_seed import SLEEPING_DEW
from forest_api.visitor_models import VisitorRules, VisitorState
from forest_api.visitor_schemas import VisitorRuleDefinition

VERSION = "launch-balance-v1"
POLICY = "b8-caps-v2"
PACK_VERSION = 10
WOODLAND_COST = 120
MOONWILLOW_COST = 240
CURVE = {
    "strategy": "linear_softcap_v2",
    "k_micro_units": 20 * MICRO,
    "starter_probability": "0.1",
    "maximum_probability": "0.8",
    "knee_micro_units": 300 * MICRO,
    "knee_probability": "0.6",
    "tail_scale_micro_units": 120 * MICRO,
    "slot_seconds": 30,
    "offline_fraction": "0.25",
    "offline_rate_cap_per_second": "0.01",
    "base_capacity": 150,
    "maximum_capacity": 450,
}
METRICS = {
    "steps": {"normalisation": "1000", "water_micro_units": 10 * MICRO, "daily_cap": 30000},
    "walking_running_distance_km": {
        "normalisation": "1",
        "water_micro_units": MICRO,
        "daily_cap": 30,
    },
    "active_energy_kcal": {"normalisation": "100", "water_micro_units": MICRO, "daily_cap": 2000},
    "flights_climbed": {"normalisation": "5", "water_micro_units": 2 * MICRO, "daily_cap": 100},
    **{
        "workout_minutes." + kind: {
            "normalisation": "10",
            "water_micro_units": 2_500_000,
            "daily_cap": 120,
        }
        for kind in sorted(set(WORKOUT_TYPES.values()))
    },
}
PLANTS = {
    "oak": {
        "name": "Oak",
        "rarity": "common",
        "radius": "0.90",
        "attraction": [2_000_000, 5_000_000, 12_000_000, 20_000_000],
        "variants": [("standard", 75), ("blue", 20), ("vined", 5)],
    },
    "moonwillow": {
        "name": "Moonwillow",
        "rarity": "epic",
        "radius": "0.95",
        "attraction": [2_900_000, 7_250_000, 17_400_000, 29_000_000],
        "variants": [("standard", 90), ("golden", 10)],
    },
}


def publish(session, settings, *, effective_at=None):
    """Atomic, repeat-safe trusted CLI publication; supports an empty production schema."""
    with session.begin():
        # Also serializes initial publication before a catalogue row exists.
        from sqlalchemy import text

        session.execute(text("SELECT pg_advisory_xact_lock(hashtextextended('forest-balance',0))"))
        catalogue = session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update()
        )
        if catalogue is not None and catalogue.version == VERSION:
            return {"version": VERSION, "alreadyPublished": True}
        now = session.scalar(select(func.clock_timestamp()))
        latest = session.scalar(select(func.max(VisitorState.settled_at)))
        latest_rules = session.scalar(select(func.max(VisitorRules.effective_at)))
        latest_economy = session.scalar(select(func.max(EconomyConfig.effective_at)))
        minimum = max(t for t in (now, latest, latest_rules, latest_economy) if t is not None)
        effective_at = effective_at or minimum + timedelta(seconds=2)
        if effective_at.tzinfo is None or effective_at <= minimum:
            raise ValueError("Publish balance strictly after server/accounting/configuration time")
        caps = {**CAPS_V1, "activityBonus": "1", "waterBonus": "1"}
        existing_policy = session.get(SkillPolicy, POLICY)
        if existing_policy is None:
            session.add(SkillPolicy(version=POLICY, rules=caps))
        elif existing_policy.rules != caps:
            raise ValueError("Cap policy versions are immutable")
        for species_id, definition in PLANTS.items():
            profile_id = f"launch_{species_id}"
            behaviour = BehaviourDefinition.model_validate(
                {
                    "schemaVersion": 2,
                    "metricMultipliers": {"steps": 1, "workout_minutes.*": 1},
                    "gardenEffects": [deepcopy(SLEEPING_DEW)] if species_id == "moonwillow" else [],
                }
            )
            session.add_all(
                [
                    GrowthProfile(
                        id=profile_id,
                        version=1,
                        thresholds={
                            "sprout": 0,
                            "seedling": 100 * MICRO,
                            "young": 400 * MICRO,
                            "adult": 1000 * MICRO,
                        },
                        maximum_growth_micro_units=1000 * MICRO,
                    ),
                    BehaviourProfile(
                        id=profile_id,
                        version=1,
                        rules=behaviour.model_dump(mode="json", by_alias=True),
                    ),
                    AttractionProfile(
                        id=profile_id,
                        version=1,
                        stage_attraction=dict(zip(STAGES, definition["attraction"], strict=True)),
                        gameplay_tags=["tree", "woodland"],
                    ),
                ]
            )
            session.flush()
            species = session.get(Species, species_id)
            values = {
                "display_name": definition["name"],
                "rarity": definition["rarity"],
                "description": "Movement Forest initial collection.",
                "clearance_radius": Decimal(definition["radius"]),
                "enabled": True,
                "is_fixture": False,
                **{
                    f"{kind}_profile_id": profile_id
                    for kind in ("growth", "behaviour", "attraction")
                },
                **{f"{kind}_profile_version": 1 for kind in ("growth", "behaviour", "attraction")},
            }
            if species is None:
                session.add(Species(id=species_id, **values))
            else:
                # The only geometry change shrinks Moonwillow; existing layouts stay valid.
                if Decimal(definition["radius"]) > species.clearance_radius:
                    raise ValueError(
                        "Expanding an existing radius needs layout compatibility review"
                    )
                for key, value in values.items():
                    setattr(species, key, value)
            session.flush()
            for variant_id, _weight in definition["variants"]:
                variant = session.get(Variant, (species_id, variant_id))
                if variant is None:
                    session.add(
                        Variant(
                            species_id=species_id,
                            variant_id=variant_id,
                            display_name=variant_id.title(),
                            description="",
                            rarity=definition["rarity"],
                            enabled=True,
                            asset_catalog_key=f"assets/{species_id}/v1/{species_id}.json",
                            asset_catalog_version="1.0.0",
                        )
                    )
                    session.flush()
                else:
                    # New defaults use the new profiles; old owned plants/packs are untouched.
                    for kind in ("growth", "behaviour", "attraction"):
                        setattr(variant, f"{kind}_profile_id", None)
                        setattr(variant, f"{kind}_profile_version", None)
                for stage in STAGES:
                    if session.get(PlantStage, (species_id, variant_id, stage)) is None:
                        session.add(
                            PlantStage(
                                species_id=species_id,
                                variant_id=variant_id,
                                stage=stage,
                                model_key=f"assets/{species_id}/v1/models/{species_id}-{stage}-{variant_id}.usdz",
                                thumbnail_key=f"assets/{species_id}/v1/ui/{species_id}-{stage}-{variant_id}.png",
                            )
                        )
        session.flush()
        if catalogue is None:
            catalogue = GameCatalogue(
                id=1,
                version=VERSION,
                is_fixture=False,
                unit_metres=Decimal(1),
                board_width=Decimal(10),
                board_depth=Decimal(10),
                starter_species_id="oak",
                starter_variant_id="standard",
            )
            session.add(catalogue)
        else:
            catalogue.version, catalogue.is_fixture = VERSION, False
        session.flush()
        rules = CalculationRules.model_validate(
            {"metrics": METRICS, "visitors": CURVE, "workout_daily_cap_seconds": 7200}
        )
        visitor = VisitorRuleDefinition.model_validate(
            {
                "curve": CURVE,
                "skill_policy_version": POLICY,
                "gap_slots": 10,
                "tutorial_first_visitor": True,
            }
        )
        session.add(
            EconomyConfig(
                version=VERSION,
                effective_at=effective_at,
                is_fixture=False,
                rules=rules.model_dump(mode="json"),
            )
        )
        session.add(
            VisitorRules(
                version=VERSION,
                effective_at=effective_at,
                is_fixture=False,
                rules=visitor.model_dump(mode="json"),
            )
        )
        session.flush()
        for pack_id, price, members in (
            ("woodland", WOODLAND_COST, list(PLANTS)),
            ("moonwillow", MOONWILLOW_COST, ["moonwillow"]),
        ):
            pools = []
            for species_id in members:
                plant = PLANTS[species_id]
                pools.append(
                    {
                        "rarity": plant["rarity"],
                        "weight": 75 if species_id == "oak" else 25,
                        "species": [
                            {
                                "speciesId": species_id,
                                "variants": [
                                    {
                                        "variantId": v,
                                        "weight": w,
                                        "profiles": {
                                            kind: {"id": f"launch_{species_id}", "version": 1}
                                            for kind in ("growth", "behaviour", "attraction")
                                        },
                                    }
                                    for v, w in plant["variants"]
                                ],
                            }
                        ],
                    }
                )
            collection.publish_in_transaction(
                session,
                settings,
                PublishPack(
                    pack_id=pack_id,
                    version=PACK_VERSION,
                    is_fixture=False,
                    offer_id=pack_id,
                    offer_version=PACK_VERSION,
                    token_cost=price,
                    definition=SpeciesPackContract(
                        display_name=f"{pack_id.title()} Pack",
                        description="One sprout. Rarity, species and variant odds are disclosed.",
                        rarities=pools,
                    ),
                ),
            )
        session.execute(
            update(ExchangeOffer)
            .where(ExchangeOffer.id.not_in(["woodland", "moonwillow"]))
            .values(active=False)
        )
        return {
            "version": VERSION,
            "effectiveAt": effective_at.isoformat(),
            "woodlandTokens": WOODLAND_COST,
            "moonwillowTokens": MOONWILLOW_COST,
        }


def grant_test_plants(session, settings, username, *, dry_run=False):
    """Repeat-safe local test sprouts; never resets existing plants or earned counters."""
    from forest_api import services
    from forest_api.models import OwnedPlant, User

    if settings.environment not in {"local", "test"}:
        raise ValueError("Test grants are restricted to local/test")
    with session.begin():
        user = session.scalar(
            select(User).where(User.username == username.lower()).with_for_update()
        )
        if user is None or user.status != "active":
            raise ValueError("Specify an existing active game username")
        services.lock_garden(session, user.id, write=True)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        if catalogue.version != VERSION:
            raise ValueError("Publish the activity balance before granting test plants")
        results = []
        for species in PLANTS:
            reference = VERSION + "/" + species
            existing = session.scalar(
                select(OwnedPlant).where(
                    OwnedPlant.owner_id == user.id,
                    OwnedPlant.acquisition_source == "development_grant",
                    OwnedPlant.acquisition_reference == reference,
                )
            )
            plant = existing
            if plant is None and not dry_run:
                plant = services.award_plant(
                    session, user.id, species, "standard", "development_grant", reference
                )
            results.append(
                {
                    "speciesId": species,
                    "plantId": str(plant.id) if plant else None,
                    "existing": existing is not None,
                }
            )
        return {"username": user.username, "dryRun": dry_run, "plants": results}
