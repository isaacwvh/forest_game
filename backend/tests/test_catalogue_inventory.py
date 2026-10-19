from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from forest_api.errors import ApiError
from forest_api.models import (
    AttractionProfile,
    GardenPlacement,
    GrowthProfile,
    OwnedPlant,
    Species,
    Variant,
)
from forest_api.seed import seed_development_catalogue
from forest_api.services import award_plant, owned_plant, read_catalogue


def test_catalogue_has_shared_assets_and_no_owned_state(client, headers):
    response = client.get("/v1/catalog", headers=headers())
    assert response.status_code == 200
    catalogue = response.json()
    assert catalogue["isFixture"] is True
    assert catalogue["catalogVersion"] == "development-oak-v1"
    species = catalogue["species"][0]
    assert species["speciesId"] == "oak"
    assert species["isFixture"] is True
    assert isinstance(species["clearanceRadius"], float)
    assert len(species["variants"]) == 3
    root = Path(__file__).resolve().parents[2]
    for variant in species["variants"]:
        assert set(variant["stages"]) == {"sprout", "seedling", "young", "adult"}
        for assets in variant["stages"].values():
            assert (root / assets["modelKey"]).is_file()
            assert (root / assets["thumbnailKey"]).is_file()
    assert "ownerId" not in response.text
    assert "plantId" not in response.text
    assert "wallet" not in response.text.lower()
    assert catalogue["profiles"]["growth"][0]["thresholdsMicroUnits"]["sprout"] == "0"


def test_inventory_and_plant_lookup_cannot_cross_accounts(client, headers, register):
    alice = register()
    bob = register("bob")
    for subject, own, foreign in (("alice", alice, bob), ("bob", bob, alice)):
        inventory = client.get("/v1/me/inventory", headers=headers(subject)).json()
        assert [plant["plantId"] for plant in inventory["plants"]] == [own["starterPlantId"]]
        foreign_lookup = client.get(
            f"/v1/me/plants/{foreign['starterPlantId']}", headers=headers(subject)
        )
        missing_lookup = client.get(f"/v1/me/plants/{uuid4()}", headers=headers(subject))
        assert foreign_lookup.status_code == missing_lookup.status_code == 404
        assert foreign_lookup.json() == missing_lookup.json()
        garden = client.get("/v1/me/garden", headers=headers(subject)).json()
        assert garden["gardenId"] == own["gardenId"]
        assert garden["plants"] == []
        assert garden["width"] == 10
        assert garden["visibility"] == "friends"


def test_duplicates_have_independent_progress_and_pinned_rules(client, app, headers, register):
    account = register()
    owner = UUID(account["profile"]["userId"])
    first = UUID(account["starterPlantId"])
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, first).growth_micro_units = 580_000_000
        duplicate = award_plant(session, owner, "oak", "standard", "test", str(uuid4()))
        second = duplicate.id
        session.add(
            GrowthProfile(
                id="dev_oak_growth",
                version=2,
                thresholds={
                    "sprout": 0,
                    "seedling": 200_000_000,
                    "young": 800_000_000,
                    "adult": 2_000_000_000,
                },
                maximum_growth_micro_units=2_000_000_000,
            )
        )
        session.flush()
        session.get(Species, "oak").growth_profile_version = 2
        session.flush()
        newer = award_plant(session, owner, "oak", "standard", "test", str(uuid4())).id
    first_dto = client.get(f"/v1/me/plants/{first}", headers=headers()).json()
    second_dto = client.get(f"/v1/me/plants/{second}", headers=headers()).json()
    new_dto = client.get(f"/v1/me/plants/{newer}", headers=headers()).json()
    assert first_dto["growthMicroUnits"] == "580000000"
    assert first_dto["growthStage"] == "young"
    assert first_dto["pinnedProfiles"]["growth"]["version"] == 1
    assert second_dto["growthMicroUnits"] == "0"
    assert second_dto["pinnedProfiles"]["growth"]["version"] == 1
    assert new_dto["pinnedProfiles"]["growth"]["version"] == 2
    assert len({str(first), str(second), str(newer)}) == 3


def test_variant_profile_override_is_resolved_and_pinned(app, register):
    account = register()
    with app.state.database.sessions.begin() as session:
        session.add(
            AttractionProfile(
                id="blue_attraction",
                version=1,
                stage_attraction={"sprout": 1, "seedling": 2, "young": 3, "adult": 4},
                gameplay_tags=[],
            )
        )
        session.flush()
        variant = session.get(Variant, ("oak", "blue"))
        variant.attraction_profile_id = "blue_attraction"
        variant.attraction_profile_version = 1
        session.flush()
        plant = award_plant(
            session, UUID(account["profile"]["userId"]), "oak", "blue", "test", str(uuid4())
        )
        assert plant.attraction_profile_id == "blue_attraction"
        assert plant.growth_profile_id == "dev_oak_growth"


def test_placed_plants_are_excluded_from_storage_and_keep_fractional_coordinates(
    client, app, headers, register
):
    account = register()
    with app.state.database.sessions.begin() as session:
        session.add(
            GardenPlacement(
                plant_id=UUID(account["starterPlantId"]),
                owner_id=UUID(account["profile"]["userId"]),
                garden_id=UUID(account["gardenId"]),
                x=Decimal("3.201"),
                y=Decimal("4.609"),
                rotation_degrees=Decimal("35.12"),
            )
        )
    assert client.get("/v1/me/inventory", headers=headers()).json()["plants"] == []
    garden = client.get("/v1/me/garden", headers=headers()).json()
    assert garden["plants"][0]["plantId"] == account["starterPlantId"]
    assert garden["plants"][0]["placement"]["x"] == 3.201
    assert garden["plants"][0]["placement"]["rotationDegrees"] == 35.12
    assert garden["plants"][0]["contributesAttraction"] is True


def test_keyset_pagination_is_bounded_complete_and_owner_scoped(client, app, headers, register):
    account = register()
    register("bob")
    with app.state.database.sessions.begin() as session:
        for _ in range(4):
            award_plant(
                session, UUID(account["profile"]["userId"]), "oak", "standard", "test", str(uuid4())
            )
    found = []
    params = {"limit": 2}
    while True:
        page = client.get("/v1/me/inventory", params=params, headers=headers()).json()
        assert len(page["plants"]) <= 2
        found.extend(plant["plantId"] for plant in page["plants"])
        if page["nextCursor"] is None:
            break
        params["after"] = page["nextCursor"]
    assert len(found) == len(set(found)) == 5
    assert client.get("/v1/me/inventory?limit=101", headers=headers()).status_code == 422
    assert client.get("/v1/me/inventory?after=bad", headers=headers()).status_code == 422


@pytest.mark.parametrize("spoof_owner", ["alice", "bob"])
def test_database_rejects_cross_owner_placement(app, register, spoof_owner):
    alice = register()
    bob = register("bob")
    owner = alice if spoof_owner == "alice" else bob
    with pytest.raises(IntegrityError):
        with app.state.database.sessions.begin() as session:
            session.add(
                GardenPlacement(
                    plant_id=UUID(alice["starterPlantId"]),
                    garden_id=UUID(bob["gardenId"]),
                    owner_id=UUID(owner["profile"]["userId"]),
                    x=Decimal("2"),
                    y=Decimal("2"),
                    rotation_degrees=Decimal("0"),
                )
            )


def test_locked_ownership_lookup_does_not_allow_foreign_mutation(app, register):
    alice = register()
    bob = register("bob")
    with app.state.database.sessions.begin() as session:
        with pytest.raises(ApiError) as error:
            owned_plant(
                session, UUID(bob["profile"]["userId"]), UUID(alice["starterPlantId"]), lock=True
            )
        assert error.value.status == 404
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, UUID(alice["starterPlantId"])).growth_micro_units == 0


def test_fixture_seed_is_repeat_safe_and_forbidden_in_production(app, settings):
    with app.state.database.sessions() as session:
        seed_development_catalogue(session, settings)
    with app.state.database.sessions() as session:
        assert len(session.scalars(select(Species)).all()) == 1
    production = settings.model_copy(update={"environment": "production"})
    with app.state.database.sessions() as session:
        with pytest.raises(ValueError, match="local/test"):
            seed_development_catalogue(session, production)
    with app.state.database.sessions() as session:
        with pytest.raises(ApiError) as error:
            read_catalogue(session, production)
        assert error.value.code == "fixture_catalogue_disabled"


@pytest.mark.parametrize("path", ["/v1/catalog", "/v1/me", "/v1/me/garden", "/v1/me/inventory"])
def test_private_endpoints_require_authentication(client, path):
    response = client.get(path)
    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"
