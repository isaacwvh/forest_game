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
from forest_api.level_benefits import owned_limit
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
        from forest_api.daily_items import settle_due

        settlement_boundary = clock()
        settle_due(session, settings, garden, settlement_boundary)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        from forest_api import items
        from forest_api.item_models import ItemPlacement

        item_rows = items.rows(session, user.id)
        initial_items = {
            row[0].id: Transform(row[3].x, row[3].y, row[3].rotation_degrees)
            for row in item_rows
            if row[3] is not None
        }
        if (initial_items or body.item_actions) and not session.info.get("items_client"):
            raise ApiError(
                426, "items_client_update_required", "Update the app to edit garden items"
            )
        owned_items = {row[0].id: row for row in item_rows}
        if not session.info.get("item_rotations_client") and any(
            row[2].id != "wooden-bench"
            for row in item_rows
            if row[3] is not None or row[0].id in {a.item_id for a in body.item_actions}
        ):
            raise ApiError(
                426, "item_content_update_required", "Update the app for the new garden items"
            )
        final_items = initial_items.copy()
        for action in body.item_actions:
            if action.item_id not in owned_items:
                raise ApiError(404, "item_not_found", "Item not found")
            placed = action.item_id in initial_items
            if action.action == "place":
                if placed:
                    raise ApiError(409, "item_already_placed", "Item is already placed")
                final_items[action.item_id] = Transform(action.x, action.y, action.rotation_degrees)
            else:
                if not placed:
                    raise ApiError(409, "item_not_placed", "Item is stored, not placed")
                saved = initial_items[action.item_id]
                if action.action == "store":
                    del final_items[action.item_id]
                elif action.action == "rotate":
                    final_items[action.item_id] = Transform(
                        saved.x, saved.y, action.rotation_degrees
                    )
                else:
                    final_items[action.item_id] = Transform(
                        action.x,
                        action.y,
                        saved.rotation_degrees
                        if action.rotation_degrees is None
                        else action.rotation_degrees,
                    )
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
        if len(final) > max(owned_limit(session, user.id, settings.plant_capacity), len(initial)):
            raise ApiError(
                409,
                "garden_capacity_full",
                "Plant collection limit reached. Store a planted copy before planting another.",
            )
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
                    length_units(plants[plant_id].clearance_radius)
                    if plants[plant_id].clearance_radius is not None
                    else radii[plants[plant_id].species_id],
                )
                for plant_id, transform in sorted(final.items())
            ]
            + [
                ClearanceCircle(
                    str(item_id),
                    length_units(transform.x),
                    length_units(transform.y),
                    length_units(owned_items[item_id][2].clearance_radius),
                )
                for item_id, transform in sorted(final_items.items())
            ],
        )

        # One post-lock server boundary for settlement and the returned skill summary.
        boundary = max(settlement_boundary, clock())
        if final != initial or final_items != initial_items:
            if max(garden.layout_version, garden.state_version) >= 9223372036854775807:
                raise ApiError(503, "version_exhausted", "Garden version requires maintenance")
            accounting.before_change(session, garden, boundary)
            for item_id in initial_items.keys() - final_items.keys():
                session.delete(owned_items[item_id][3])
            for item_id, transform in final_items.items():
                if initial_items.get(item_id) == transform:
                    continue
                row = owned_items[item_id][3]
                if row is None:
                    row = ItemPlacement(item_id=item_id, owner_id=user.id, garden_id=garden.id)
                    session.add(row)
                row.x, row.y, row.rotation_degrees = (
                    transform.x,
                    transform.y,
                    transform.rotation_degrees,
                )
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
