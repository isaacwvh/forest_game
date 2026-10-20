"""The native client's synthetic wire fixtures must remain valid B3 contracts."""

import json
from pathlib import Path

import pytest

from forest_api.schemas import (
    CatalogueDTO,
    GardenDTO,
    GardenEditRequest,
    GardenEditResult,
    InventoryDTO,
    UserDTO,
)

FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "frontend/MovementForest/Resources/Fixtures/editor-contract.json"
)


@pytest.mark.parametrize(
    ("key", "schema"),
    [
        ("profile", UserDTO),
        ("catalogue", CatalogueDTO),
        ("emptyGarden", GardenDTO),
        ("inventory", InventoryDTO),
        ("plantRequest", GardenEditRequest),
        ("plantResult", GardenEditResult),
        ("placedInventory", InventoryDTO),
    ],
)
def test_native_editor_wire_fixture_matches_backend_schema(key, schema):
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    schema.model_validate_json(json.dumps(fixture[key]))


def test_native_fixture_receipt_preserves_owned_copy_and_canonical_transform():
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    request = GardenEditRequest.model_validate(fixture["plantRequest"])
    result = GardenEditResult.model_validate(fixture["plantResult"])
    before = InventoryDTO.model_validate(fixture["inventory"]).plants[0]
    after = result.updated_plants[0]
    assert result.request_id == request.request_id
    assert before.plant_id == after.plant_id == request.actions[0].plant_id
    assert before.placement is None
    assert before.pinned_profiles == after.pinned_profiles
    assert before.growth_micro_units == after.growth_micro_units
    assert after.placement.x == request.actions[0].x
    assert after.placement.y == request.actions[0].y
    assert after.placement.rotation_degrees == request.actions[0].rotation_degrees
    assert fixture["rejection"]["error"]["code"] == "out_of_bounds"
