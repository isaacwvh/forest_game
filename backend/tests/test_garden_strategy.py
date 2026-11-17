"""Draft preview safety, proof-bound atomic saves and cross-language fixtures."""

from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from test_placement import edit_body, plant_action
from test_placement import garden_setup as garden_setup

from forest_api.models import ApiRequest, Garden, GardenPlacement
from forest_api.schemas import GardenEditRequest

PREVIEW = "/v1/me/garden/preview"
EDITS = "/v1/me/garden/edits"


def state(app, owner):
    with app.state.database.sessions() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == owner))
        return (
            garden.layout_version,
            garden.state_version,
            session.scalar(select(func.count()).select_from(GardenPlacement)),
            session.scalar(select(func.count()).select_from(ApiRequest)),
        )


def test_preview_is_read_only_and_proof_saves_exactly_once(client, app, headers, garden_setup):
    _, owner, first, second = garden_setup
    body = edit_body(plant_action(first), plant_action(second, x=5))
    before = state(app, owner)
    preview = client.post(PREVIEW, headers=headers(), json=body)
    assert preview.status_code == 200, preview.text
    assert state(app, owner) == before
    result = preview.json()
    assert len(result["fingerprint"]) == 64
    assert int(result["totalAttractionMicroUnits"]) > 0
    assert client.post(PREVIEW, headers=headers(), json=body).json() == result
    body["expectedStrategyFingerprint"] = result["fingerprint"]
    saved = client.post(EDITS, headers=headers(), json=body)
    assert saved.status_code == 200, saved.text
    assert (
        saved.json()["garden"]["totalAttractionMicroUnits"] == result["totalAttractionMicroUnits"]
    )
    assert saved.json()["garden"]["skillSummary"] == result["skillSummary"]
    assert state(app, owner)[:3] == (before[0] + 1, before[1] + 1, 2)
    assert client.post(EDITS, headers=headers(), json=body).json() == saved.json()
    assert state(app, owner)[3] == before[3] + 1


def test_invalid_proof_cannot_apply_any_part_of_a_batch(client, app, headers, garden_setup):
    _, owner, first, second = garden_setup
    body = edit_body(
        plant_action(first), plant_action(second, x=5), expectedStrategyFingerprint="0" * 64
    )
    before = state(app, owner)
    response = client.post(EDITS, headers=headers(), json=body)
    assert response.status_code == 409, response.text
    assert response.json()["error"]["code"] == "strategy_changed"
    assert state(app, owner) == before


def test_preview_and_save_reject_the_same_invalid_final_layout(client, app, headers, garden_setup):
    _, owner, first, second = garden_setup
    body = edit_body(plant_action(first), plant_action(second))
    before = state(app, owner)
    preview = client.post(PREVIEW, headers=headers(), json=body)
    save = client.post(EDITS, headers=headers(), json=body)
    assert preview.status_code == save.status_code == 422
    assert preview.json()["error"]["code"] == save.json()["error"]["code"]
    assert state(app, owner) == before


def test_growth_changes_invalidate_a_reviewed_strategy(client, app, headers, garden_setup):
    _, owner, first, _ = garden_setup
    body = edit_body(plant_action(first))
    preview = client.post(PREVIEW, headers=headers(), json=body).json()
    from forest_api.models import OwnedPlant

    with app.state.database.sessions.begin() as session:
        plant = session.get(OwnedPlant, first)
        plant.growth_micro_units += 1
    before = state(app, owner)
    body["expectedStrategyFingerprint"] = preview["fingerprint"]
    response = client.post(EDITS, headers=headers(), json=body)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "strategy_changed"
    assert state(app, owner) == before


def test_preview_authorizes_owner_and_rejects_stale_layout(client, headers, garden_setup, register):
    _, _, first, _ = garden_setup
    register("bob")
    body = edit_body(plant_action(first))
    assert client.post(PREVIEW, headers=headers("bob"), json=body).status_code == 404
    assert (
        client.post(
            PREVIEW, headers=headers(), json={**body, "expectedLayoutVersion": 99}
        ).status_code
        == 409
    )
    assert client.post(PREVIEW, json=body).status_code == 401


def test_large_mixed_drafts_remain_one_bounded_batch():
    actions = [plant_action(uuid4()) for _ in range(150)]
    assert len(GardenEditRequest.model_validate(edit_body(*actions)).actions) == 150
    with pytest.raises(ValueError):
        GardenEditRequest.model_validate(edit_body(*[plant_action(uuid4()) for _ in range(201)]))


def test_null_preview_extension_preserves_old_request_hash():
    from forest_api import services

    body = edit_body(plant_action(UUID(int=1)))
    original = GardenEditRequest.model_validate(body)
    explicit = GardenEditRequest.model_validate({**body, "expectedStrategyFingerprint": None})
    assert services.request_hash("garden_edits", original) == services.request_hash(
        "garden_edits", explicit
    )


def test_native_reference_contract_is_current():
    import json

    from scripts.export_garden_strategy_contract import TARGET, cases

    assert json.loads(TARGET.read_text(encoding="utf-8")) == {"cases": cases()}
