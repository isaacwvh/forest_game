"""Permanent variant-stage artwork discovery; callers own locks and transactions."""

from collections import defaultdict
from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert

from forest_api import services
from forest_api.calculations import MAX_INTEGER, stage_for
from forest_api.errors import ApiError
from forest_api.models import CatalogDiscoveryState, CatalogStageDiscovery, GrowthProfile
from forest_api.schemas import DTO, STAGES, GrowthDefinition


class DiscoveryEntry(DTO):
    species_id: str
    variant_id: str
    stages: list[Literal["seedling", "young", "adult"]]


class DiscoverySnapshot(DTO):
    user_id: UUID
    catalog_version: str
    discovery_version: int = Field(ge=0, le=MAX_INTEGER)
    entries: list[DiscoveryEntry]


def record_reached(session, owner_id: UUID, plants, boundary: datetime) -> bool:
    """Called under the owner's lock, once per growth transaction. No independent commit."""
    candidates = set()
    profiles = {}
    for plant in plants:
        if plant.owner_id != owner_id:
            raise ValueError("Discovery requires owned copies from the locked account")
        key = (plant.growth_profile_id, plant.growth_profile_version)
        if key not in profiles:
            row = session.get(GrowthProfile, key)
            if row is None:
                raise ApiError(503, "invalid_growth_configuration", "Growth profile is unavailable")
            profiles[key] = GrowthDefinition(
                thresholds=row.thresholds,
                maximum_growth_micro_units=row.maximum_growth_micro_units,
            )
        reached = stage_for(plant.growth_micro_units, profiles[key].thresholds.model_dump())
        for stage in STAGES[1 : STAGES.index(reached) + 1]:
            candidates.add((plant.species_id, plant.variant_id, stage))
    if not candidates:
        return False
    inserted = session.execute(
        insert(CatalogStageDiscovery)
        .values(
            [
                dict(owner_id=owner_id, species_id=s, variant_id=v, stage=t, recorded_at=boundary)
                for s, v, t in sorted(candidates)
            ]
        )
        .on_conflict_do_nothing()
        .returning(CatalogStageDiscovery.stage)
    ).all()
    if not inserted:
        return False
    state = session.get(CatalogDiscoveryState, owner_id)
    if state is None:
        raise ApiError(503, "discovery_not_ready", "Catalog discovery requires a database upgrade")
    if state.version == MAX_INTEGER:
        raise ApiError(503, "counter_exhausted", "Discovery version requires maintenance")
    state.version += 1
    return True


def read(session, settings, identity) -> DiscoverySnapshot:
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        catalog = services.get_catalogue_state(session, settings)
        state = session.get(CatalogDiscoveryState, user.id)
        if state is None:
            raise ApiError(
                503, "discovery_not_ready", "Catalog discovery requires a database upgrade"
            )
        entries = defaultdict(set)
        for row in session.scalars(
            select(CatalogStageDiscovery).where(CatalogStageDiscovery.owner_id == user.id)
        ):
            entries[row.species_id, row.variant_id].add(row.stage)
        return DiscoverySnapshot(
            user_id=user.id,
            catalog_version=catalog.version,
            discovery_version=state.version,
            entries=[
                DiscoveryEntry(
                    species_id=s,
                    variant_id=v,
                    stages=[stage for stage in STAGES[1:] if stage in stages],
                )
                for (s, v), stages in sorted(entries.items())
            ],
        )
