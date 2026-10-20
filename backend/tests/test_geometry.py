import json
from decimal import Decimal
from pathlib import Path

import pytest

from forest_api.errors import ApiError
from forest_api.geometry import ClearanceCircle, length_units, validate_layout

FIXTURES = Path(__file__).resolve().parents[2] / "spec_examples/placement-cases.json"
CASES = json.loads(FIXTURES.read_text(), parse_float=Decimal)["cases"]


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["name"])
def test_shared_geometry_examples(case):
    circles = [
        ClearanceCircle(
            plant["id"],
            length_units(Decimal(plant["x"])),
            length_units(Decimal(plant["y"])),
            length_units(Decimal(plant["radius"])),
        )
        for plant in case["plants"]
    ]
    width, depth = length_units(Decimal(case["width"])), length_units(Decimal(case["depth"]))
    if case["error"] is None:
        validate_layout(width, depth, circles)
    else:
        with pytest.raises(ApiError) as error:
            validate_layout(width, depth, circles)
        assert error.value.code == case["error"]


@pytest.mark.parametrize("value", ["NaN", "Infinity", "-1", "1000000", "0.0001"])
def test_invalid_published_geometry_is_rejected(value):
    with pytest.raises(ApiError) as error:
        length_units(Decimal(value))
    assert error.value.status == 503


def test_zero_radius_configuration_is_rejected():
    with pytest.raises(ApiError) as error:
        validate_layout(10000, 10000, [ClearanceCircle("a", 1000, 1000, 0)])
    assert error.value.code == "invalid_geometry_configuration"
