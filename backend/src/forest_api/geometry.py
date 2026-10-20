"""Canonical integer geometry shared by the placement use case and fixed examples."""

from dataclasses import dataclass
from decimal import Decimal
from itertools import combinations

from forest_api.errors import ApiError


@dataclass(frozen=True)
class ClearanceCircle:
    plant_id: str
    x: int
    y: int
    radius: int


def length_units(value: Decimal) -> int:
    if not value.is_finite() or value < 0 or value > Decimal("999999.999"):
        raise ApiError(503, "invalid_geometry_configuration", "Invalid published geometry")
    scaled = value * 1000
    if scaled != scaled.to_integral_value():
        raise ApiError(503, "invalid_geometry_configuration", "Invalid published geometry")
    return int(scaled)


def validate_layout(width: int, depth: int, circles: list[ClearanceCircle]) -> None:
    if width <= 0 or depth <= 0 or any(circle.radius <= 0 for circle in circles):
        raise ApiError(503, "invalid_geometry_configuration", "Invalid published geometry")
    for circle in circles:
        if not (
            circle.radius <= circle.x <= width - circle.radius
            and circle.radius <= circle.y <= depth - circle.radius
        ):
            raise ApiError(
                422,
                "out_of_bounds",
                "Plant clearance extends beyond the garden",
                {"plantId": circle.plant_id},
            )
    for first, second in combinations(circles, 2):
        distance_squared = (first.x - second.x) ** 2 + (first.y - second.y) ** 2
        if distance_squared < (first.radius + second.radius) ** 2:
            raise ApiError(
                422,
                "clearance_overlap",
                "Plant clearance circles overlap",
                {"plantIds": [first.plant_id, second.plant_id]},
            )
