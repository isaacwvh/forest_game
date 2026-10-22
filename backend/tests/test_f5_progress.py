"""Progress presentation must follow owned profiles, including retired versions."""

from uuid import UUID

import pytest

from forest_api.calculations import MICRO
from forest_api.models import GrowthProfile, OwnedPlant


@pytest.mark.parametrize(
    ("growth", "stage", "start", "next_threshold"),
    [(0, "sprout", 0, 200), (250, "seedling", 200, 600), (1500, "adult", 1500, None)],
)
def test_progress_resolves_pinned_profile_absent_from_catalogue(
    app, client, headers, register, growth, stage, start, next_threshold
):
    account = register()
    with app.state.database.sessions.begin() as session:
        session.add(
            GrowthProfile(
                id="retired-owned-only",
                version=1,
                thresholds={
                    "sprout": 0,
                    "seedling": 200 * MICRO,
                    "young": 600 * MICRO,
                    "adult": 1500 * MICRO,
                },
                maximum_growth_micro_units=1500 * MICRO,
            )
        )
        session.flush()
        plant = session.get(OwnedPlant, UUID(account["starterPlantId"]))
        plant.growth_profile_id = "retired-owned-only"
        plant.growth_profile_version = 1
        plant.growth_micro_units = growth * MICRO
    catalogue = client.get("/v1/catalog", headers=headers()).json()
    assert "retired-owned-only" not in {item["id"] for item in catalogue["profiles"]["growth"]}
    plant = client.get("/v1/me/inventory", headers=headers()).json()["plants"][0]
    assert plant["growthStage"] == stage
    assert plant["growthProgress"] == {
        "stageStartMicroUnits": str(start * MICRO),
        "nextStageMicroUnits": str(next_threshold * MICRO) if next_threshold is not None else None,
        "maximumGrowthMicroUnits": str(1500 * MICRO),
    }
