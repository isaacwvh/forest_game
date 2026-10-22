"""The checked-in F5 fixtures come from the real disposable HTTP walkthrough."""

import json
from pathlib import Path

import pytest

from forest_api.activity_schemas import (
    ActivityStatus,
    EnrolResult,
    RecapAcknowledgement,
    RecapList,
    SyncActivity,
    SyncResult,
)
from forest_api.schemas import CatalogueDTO, GardenDTO, UserDTO

FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "frontend/MovementForest/Resources/Fixtures/activity-contract.json"
)


@pytest.mark.parametrize(
    ("key", "schema"),
    [
        ("profile", UserDTO),
        ("catalogue", CatalogueDTO),
        ("gardenBeforeSync", GardenDTO),
        ("enrolment", EnrolResult),
        ("syncRequest", SyncActivity),
        ("syncResult", SyncResult),
        ("status", ActivityStatus),
        ("recaps", RecapList),
        ("acknowledgement", RecapAcknowledgement),
    ],
)
def test_native_activity_wire_fixture(key, schema):
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    schema.model_validate(fixture[key])


def test_fixture_retains_transform_identity_and_recap_award():
    fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
    before = fixture["gardenBeforeSync"]
    after = fixture["syncResult"]["garden"]
    assert before["plants"][0]["plantId"] == after["plants"][0]["plantId"]
    assert before["plants"][0]["placement"] == after["plants"][0]["placement"]
    assert before["layoutVersion"] == after["layoutVersion"]
    assert after["stateVersion"] == before["stateVersion"] + 1
    assert (
        fixture["recaps"]["recaps"][0]["payload"]["plants"][0]["awardedGrowthMicroUnits"]
        == "10000000"
    )
    assert fixture["recaps"]["recaps"][0]["payload"]["resourceDeltas"] == {}
