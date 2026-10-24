"""Atomic B3 edits. All placement write paths must hold this account/garden lock order."""

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from typing import Protocol

from sqlalchemy import select
from sqlalchemy.orm import Session

from forest_api import services
from forest_api.auth import Identity
from forest_api.config import Settings
from forest_api.errors import ApiError
from forest_api.geometry import ClearanceCircle, length_units, validate_layout
from forest_api.models import Garden, GardenPlacement, OwnedPlant, Species, Variant
from forest_api.schemas import GardenEditRequest, GardenEditResult


@dataclass(frozen=True)
class Transform:
    x: Decimal
    y: Decimal
    rotation_degrees: Decimal


class PlacementAccounting(Protocol):
    def before_change(self, session: Session, garden: Garden, boundary: datetime) -> None: ...
    def after_change(self, session: Session, garden: Garden, boundary: datetime) -> None: ...


class DisabledPlacementAccounting:
    """B6 integration seam only. No visitor timeline or rewards are settled yet."""

    def before_change(self, session: Session, garden: Garden, boundary: datetime) -> None:
        pass

    def after_change(self, session: Session, garden: Garden, boundary: datetime) -> None:
        pass


DISABLED_ACCOUNTING = DisabledPlacementAccounting()


def utc_now() -> datetime:
    return datetime.now(UTC)


def edit_garden(
    session: Session,
    settings: Settings,
    identity: Identity,
    body: GardenEditRequest,
    *,
    accounting: PlacementAccounting = DISABLED_ACCOUNTING,
    clock: Callable[[], datetime] = utc_now,
) -> GardenEditResult:
    operation = "garden_edits"
    payload_hash = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, payload_hash)
        if previous is not None:
            return GardenEditResult.model_validate(previous)
        garden = services.lock_garden(session, user.id, write=True)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        if catalogue.version != body.catalog_version:
            raise ApiError(
                409,
                "stale_catalogue",
                "Refresh the catalogue before editing",
                {
                    "expectedCatalogVersion": body.catalog_version,
                    "currentCatalogVersion": catalogue.version,
                },
            )
        if garden.layout_version != body.expected_layout_version:
            raise ApiError(
                409,
                "stale_layout",
                "Refresh the garden before editing",
                {
                    "expectedLayoutVersion": body.expected_layout_version,
                    "currentLayoutVersion": garden.layout_version,
                },
            )

        placements = {
            row.plant_id: row
            for row in session.scalars(
                select(GardenPlacement).where(GardenPlacement.garden_id == garden.id)
            )
        }
        requested_ids = {action.plant_id for action in body.actions}
        relevant_ids = requested_ids | placements.keys()
        plants = {
            row.id: row
            for row in session.scalars(
                select(OwnedPlant)
                .where(OwnedPlant.owner_id == user.id, OwnedPlant.id.in_(relevant_ids))
                .order_by(OwnedPlant.id)
                .with_for_update()
            )
        }
        if not requested_ids <= plants.keys():
            raise ApiError(404, "plant_not_found", "Plant not found")

        initial = {
            plant_id: Transform(row.x, row.y, row.rotation_degrees)
            for plant_id, row in placements.items()
        }
        final = initial.copy()
        for action in body.actions:
            placed = action.plant_id in initial
            if action.action == "plant":
                if placed:
                    raise ApiError(
                        409,
                        "plant_already_placed",
                        "Plant is already placed",
                        {"plantId": str(action.plant_id)},
                    )
                plant = plants[action.plant_id]
                species = session.get(Species, plant.species_id)
                variant = session.get(Variant, (plant.species_id, plant.variant_id))
                if not species.enabled or not variant.enabled:
                    raise ApiError(
                        409,
                        "plant_unavailable",
                        "Plant is not enabled for planting",
                        {"plantId": str(action.plant_id)},
                    )
                final[action.plant_id] = Transform(action.x, action.y, action.rotation_degrees)
            else:
                if not placed:
                    raise ApiError(
                        409,
                        "plant_not_placed",
                        "Plant is stored, not placed",
                        {"plantId": str(action.plant_id)},
                    )
                saved = initial[action.plant_id]
                if action.action == "store":
                    del final[action.plant_id]
                elif action.action == "rotate":
                    final[action.plant_id] = Transform(saved.x, saved.y, action.rotation_degrees)
                else:
                    rotation = (
                        saved.rotation_degrees
                        if action.rotation_degrees is None
                        else action.rotation_degrees
                    )
                    final[action.plant_id] = Transform(action.x, action.y, rotation)

        species_ids = {plants[plant_id].species_id for plant_id in final}
        radii = {
            row.id: length_units(row.clearance_radius)
            for row in session.scalars(select(Species).where(Species.id.in_(species_ids)))
        }
        validate_layout(
            length_units(garden.width),
            length_units(garden.depth),
            [
                ClearanceCircle(
                    str(plant_id),
                    length_units(transform.x),
                    length_units(transform.y),
                    radii[plants[plant_id].species_id],
                )
                for plant_id, transform in sorted(final.items())
            ],
        )

        # One post-lock server boundary for settlement and the returned skill summary.
        boundary = clock()
        if final != initial:
            if max(garden.layout_version, garden.state_version) >= 9223372036854775807:
                raise ApiError(503, "version_exhausted", "Garden version requires maintenance")
            accounting.before_change(session, garden, boundary)
            for plant_id in initial.keys() - final.keys():
                session.delete(placements[plant_id])
            for plant_id, transform in final.items():
                if initial.get(plant_id) == transform:
                    continue
                row = placements.get(plant_id)
                if row is None:
                    row = GardenPlacement(plant_id=plant_id, owner_id=user.id, garden_id=garden.id)
                    session.add(row)
                    placements[plant_id] = row
                row.x, row.y, row.rotation_degrees = (
                    transform.x,
                    transform.y,
                    transform.rotation_degrees,
                )
            garden.layout_version += 1
            garden.state_version += 1
            session.flush()
            accounting.after_change(session, garden, boundary)
            session.flush()

        presenter = services.PlantPresenter(session)
        result = GardenEditResult(
            request_id=body.request_id,
            garden=services.present_garden(
                session, garden, catalogue, presenter, boundary=boundary
            ),
            updated_plants=[
                presenter.plant(
                    plants[action.plant_id],
                    placements[action.plant_id] if action.plant_id in final else None,
                )
                for action in body.actions
            ],
        )
        services.record_request(session, user.id, body, operation, payload_hash, result)
    return result
