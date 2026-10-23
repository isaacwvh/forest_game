"""Explicit local/test fixtures. No balance values here are approved game data."""

from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import select, text
from sqlalchemy.orm import Session

from forest_api.config import Settings
from forest_api.models import (
    AttractionProfile,
    BehaviourProfile,
    EconomyConfig,
    GameCatalogue,
    GrowthProfile,
    PlantStage,
    Species,
    Variant,
)
from forest_api.schemas import STAGES, AttractionDefinition, BehaviourDefinition, GrowthDefinition

FIXTURE_VERSION = "development-oak-v1"


def seed_calculation_config(session: Session) -> None:
    from forest_api.calculations import CalculationRules

    seed_visitor_rules(session)
    version = "development-neutral-v1"
    if session.get(EconomyConfig, version) is not None:
        return
    rules = CalculationRules.model_validate(
        {
            "metrics": {
                "steps": {
                    "normalisation": "1000",
                    "water_micro_units": 10_000_000,
                    "daily_cap": 100_000,
                }
            },
            "visitors": {
                "k_micro_units": 20_000_000,
                "starter_probability": "0.1",
                "maximum_probability": "0.8",
                "slot_seconds": 30,
                "offline_fraction": "0.25",
                "offline_rate_cap_per_second": "0.01",
                "base_capacity": 30,
                "maximum_capacity": 120,
            },
        }
    )
    session.add(
        EconomyConfig(
            version=version,
            effective_at=datetime(1970, 1, 1, tzinfo=UTC),
            is_fixture=True,
            rules=rules.model_dump(mode="json"),
        )
    )
    session.flush()


def seed_visitor_rules(session: Session) -> None:
    from forest_api.visitor_models import VisitorRules
    from forest_api.visitor_schemas import VisitorRuleDefinition

    version = "development-visitors-v1"
    if session.get(VisitorRules, version) is None:
        definition = VisitorRuleDefinition.model_validate(
            {
                "curve": {
                    "k_micro_units": 2_000_000,
                    "starter_probability": "0.5",
                    "maximum_probability": "0.8",
                    "slot_seconds": 30,
                    "offline_fraction": "0.25",
                    "offline_rate_cap_per_second": "0.01",
                    "base_capacity": 30,
                    "maximum_capacity": 120,
                }
            }
        )
        session.add(
            VisitorRules(
                version=version,
                effective_at=datetime(1970, 1, 1, tzinfo=UTC),
                is_fixture=True,
                rules=definition.model_dump(mode="json"),
            )
        )
        session.flush()


def seed_development_catalogue(session: Session, settings: Settings) -> None:
    if settings.environment not in {"local", "test"}:
        raise ValueError("Development catalogue seeding is disabled outside local/test")
    with session.begin():
        session.execute(
            text("SELECT pg_advisory_xact_lock(hashtextextended('forest-dev-seed', 0))")
        )
        seed_calculation_config(session)
        existing = session.get(GameCatalogue, 1)
        if existing is not None:
            if (
                existing.version in {FIXTURE_VERSION, "development-woodland-v2"}
                and existing.is_fixture
            ):
                return
            raise ValueError("Refusing to replace an existing catalogue")
        if session.scalar(select(Species.id).limit(1)) is not None:
            raise ValueError("Refusing to seed over an existing partial catalogue")

        growth = GrowthDefinition(
            thresholds={
                "sprout": 0,
                "seedling": 100_000_000,
                "young": 400_000_000,
                "adult": 1_000_000_000,
            },
            maximum_growth_micro_units=1_000_000_000,
        )
        attraction = AttractionDefinition(
            stage_attraction={
                "sprout": 2_000_000,
                "seedling": 5_000_000,
                "young": 12_000_000,
                "adult": 20_000_000,
            },
            gameplay_tags=["tree", "woodland"],
        )
        behaviour = BehaviourDefinition(metric_multipliers={"steps": 1.0})
        session.add_all(
            [
                GrowthProfile(
                    id="dev_oak_growth",
                    version=1,
                    thresholds=growth.thresholds.model_dump(),
                    maximum_growth_micro_units=growth.maximum_growth_micro_units,
                ),
                BehaviourProfile(
                    id="dev_oak_behaviour",
                    version=1,
                    rules=behaviour.model_dump(mode="json", by_alias=True),
                ),
                AttractionProfile(
                    id="dev_oak_attraction",
                    version=1,
                    stage_attraction=attraction.stage_attraction.model_dump(),
                    gameplay_tags=attraction.gameplay_tags,
                ),
            ]
        )
        session.flush()
        session.add(
            Species(
                id="oak",
                display_name="Oak",
                description="Development fixture; balance unapproved.",
                clearance_radius=Decimal("0.900"),
                growth_profile_id="dev_oak_growth",
                growth_profile_version=1,
                behaviour_profile_id="dev_oak_behaviour",
                behaviour_profile_version=1,
                attraction_profile_id="dev_oak_attraction",
                attraction_profile_version=1,
                enabled=True,
                is_fixture=True,
            )
        )
        session.flush()
        for variant in ("standard", "blue", "vined"):
            session.add(
                Variant(
                    species_id="oak",
                    variant_id=variant,
                    display_name=variant.title(),
                    description="Development fixture",
                    rarity="development_unbalanced",
                    enabled=True,
                    asset_catalog_key="assets/oak/v1/oak.json",
                    asset_catalog_version="1.0.0",
                )
            )
        session.flush()
        for variant in ("standard", "blue", "vined"):
            for stage in STAGES:
                session.add(
                    PlantStage(
                        species_id="oak",
                        variant_id=variant,
                        stage=stage,
                        model_key=f"assets/oak/v1/models/oak-{stage}-{variant}.usdz",
                        thumbnail_key=f"assets/oak/v1/ui/oak-{stage}-{variant}.png",
                    )
                )
        session.add(
            GameCatalogue(
                id=1,
                version=FIXTURE_VERSION,
                is_fixture=True,
                unit_metres=Decimal("1"),
                board_width=Decimal("10"),
                board_depth=Decimal("10"),
                starter_species_id="oak",
                starter_variant_id="standard",
            )
        )
