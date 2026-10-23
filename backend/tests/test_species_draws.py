import copy
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import func, select
from test_collection import exchange, open_pack

from forest_api import collection
from forest_api.collection_models import ExchangeOffer, OwnedPack, PackDefinition, PackOpening
from forest_api.collection_schemas import PublishPack, SpeciesPackContract, parse_pack
from forest_api.collection_seed import seed_collection
from forest_api.errors import ApiError
from forest_api.models import OwnedPlant, Species
from forest_api.seed import seed_development_catalogue
from forest_api.visitor_models import VisitorWallet


@pytest.fixture
def species_economy(economy):
    app = economy["app"]
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
    return economy


def definition(economy):
    with economy["app"].state.database.sessions() as session:
        return copy.deepcopy(session.get(PackDefinition, ("woodland", 2)).definition)


@pytest.mark.parametrize(
    "species_roll,variant_roll,expected",
    [
        (0, 0, ("moonwillow", "golden")),
        (0, 9, ("moonwillow", "golden")),
        (0, 10, ("moonwillow", "standard")),
        (0, 99, ("moonwillow", "standard")),
        (1, 0, ("oak", "blue")),
        (1, 19, ("oak", "blue")),
        (1, 20, ("oak", "standard")),
        (1, 94, ("oak", "standard")),
        (1, 95, ("oak", "vined")),
        (1, 99, ("oak", "vined")),
    ],
)
def test_three_exact_selection_boundaries(species_economy, species_roll, variant_roll, expected):
    contract = parse_pack(definition(species_economy))
    values, bounds = iter([0, species_roll, variant_roll]), []

    def random_below(limit):
        bounds.append(limit)
        return next(values)

    rarity, outcome = collection.choose(contract, random_below)
    assert rarity == "common"
    assert (outcome.species_id, outcome.variant_id) == expected
    assert bounds == [100, 2, 100]


def test_variant_addition_does_not_weight_species_or_rarity(species_economy):
    original = definition(species_economy)
    updated = copy.deepcopy(original)
    species = updated["rarities"][0]["species"]
    oak = next(s for s in species if s["speciesId"] == "oak")
    extra = copy.deepcopy(oak["variants"][0])
    extra.update(variantId="synthetic_extra", weight=40)
    oak["variants"].append(extra)
    species.reverse()
    for species_roll in (0, 1):
        results = []
        for value in (original, updated):
            rolls, bounds = iter([0, species_roll, 0]), []

            def random_below(limit, limits=bounds, source=rolls):
                limits.append(limit)
                return next(source)

            rarity, outcome = collection.choose(parse_pack(value), random_below)
            results.append((rarity, outcome.species_id))
            assert bounds[:2] == [100, 2]
        assert results[0] == results[1]


def test_multiple_rarity_boundaries_ignore_species_and_variant_counts(species_economy):
    value = definition(species_economy)
    common = value["rarities"][0]
    common["weight"] = 80
    rare = copy.deepcopy(common["species"][0])
    rare["speciesId"] = "synthetic_rare"
    value["rarities"].append({"rarity": "rare", "weight": 20, "species": [rare]})
    contract = parse_pack(value)
    for roll, expected in [(0, "common"), (79, "common"), (80, "rare"), (99, "rare")]:
        values = iter([roll, 0, 0])
        assert collection.choose(contract, lambda n, source=values: next(source))[0] == expected


@pytest.mark.parametrize(
    "change",
    [
        "empty_tier",
        "empty_species",
        "zero_variants",
        "duplicate_species",
        "duplicate_variant",
        "negative",
        "fractional",
        "unknown_schema",
    ],
)
def test_invalid_hierarchy_rejected(species_economy, change):
    value = definition(species_economy)
    pool = value["rarities"][0]
    plant = pool["species"][0]
    if change == "empty_tier":
        pool["species"] = []
    elif change == "empty_species":
        plant["variants"] = []
    elif change == "zero_variants":
        for v in plant["variants"]:
            v["weight"] = 0
    elif change == "duplicate_species":
        pool["species"].append(copy.deepcopy(plant))
    elif change == "duplicate_variant":
        plant["variants"].append(copy.deepcopy(plant["variants"][0]))
    elif change == "negative":
        plant["variants"][0]["weight"] = -1
    elif change == "fractional":
        plant["variants"][0]["weight"] = 1.5
    else:
        value["schemaVersion"] = 999
    with pytest.raises(ValidationError):
        parse_pack(value)


def test_new_publisher_uses_species_rarity_and_rejects_duplicate_species_across_tiers(
    species_economy,
):
    app = species_economy["app"]
    value = definition(species_economy)
    value["rarities"][0]["rarity"] = "rare"
    with pytest.raises(ApiError), app.state.database.sessions() as session:
        collection.publish(
            session,
            app.state.settings,
            PublishPack(
                pack_id="bad_species",
                version=1,
                is_fixture=True,
                offer_id="bad_species",
                offer_version=1,
                token_cost=1,
                definition=SpeciesPackContract.model_validate(value),
            ),
        )
    value = definition(species_economy)
    value["rarities"].append(
        {
            "rarity": "rare",
            "weight": 1,
            "species": [copy.deepcopy(value["rarities"][0]["species"][0])],
        }
    )
    with pytest.raises(ValidationError):
        parse_pack(value)


def test_upgrade_preserves_old_packs_results_balances_and_progress(economy):
    app = economy["app"]
    bought = exchange(economy, quantity=2).json()
    old_result = open_pack(economy, bought["packs"][0]["ownedPackId"]).json()
    with app.state.database.sessions.begin() as session:
        session.get(
            OwnedPlant, UUID(old_result["plant"]["plantId"])
        ).growth_micro_units = 200_000_000
    with app.state.database.sessions() as session:
        old_contract = copy.deepcopy(session.get(PackDefinition, ("woodland", 1)).definition)
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
    assert open_pack(economy, bought["packs"][0]["ownedPackId"]).json() == old_result
    pending_old = open_pack(economy, bought["packs"][1]["ownedPackId"]).json()
    assert pending_old["packVersion"] == 1 and pending_old["plant"]["speciesId"] == "oak"
    new = exchange(economy, offerVersion=2).json()
    assert new["packs"][0]["version"] == 2
    with app.state.database.sessions() as session:
        assert session.get(PackDefinition, ("woodland", 1)).definition == old_contract
        assert (
            session.get(OwnedPlant, UUID(old_result["plant"]["plantId"])).growth_micro_units
            == 200_000_000
        )
        assert session.get(VisitorWallet, economy["owner"]).tokens == 85


def test_repeat_seed_preserves_retirement_and_does_not_reset_player_state(species_economy):
    app = species_economy["app"]
    exchange(species_economy, offerVersion=2)
    with app.state.database.sessions() as session:
        collection.retire_offer(session, app.state.settings, "woodland", 2)
    for _ in range(2):
        with app.state.database.sessions() as session:
            seed_development_catalogue(session, app.state.settings)
            seed_collection(session, app.state.settings)
    with app.state.database.sessions() as session:
        assert not session.get(ExchangeOffer, ("woodland", 2)).active
        assert session.get(VisitorWallet, species_economy["owner"]).tokens == 95
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 1
        assert session.scalar(select(func.count()).select_from(Species)) == 2


def test_moonwillow_draw_store_place_grow_and_catalogue(species_economy):
    client, headers, app = (
        species_economy["client"],
        species_economy["headers"],
        species_economy["app"],
    )
    bought = exchange(species_economy, offerId="moonwillow").json()
    result = open_pack(species_economy, bought["packs"][0]["ownedPackId"]).json()
    assert result["plant"]["speciesId"] == "moonwillow" and result["rarity"] == "common"
    assert result["plant"]["pinnedProfiles"]["growth"]["id"] == "dev_moonwillow_growth"
    now = [datetime(2026, 10, 23, 4, tzinfo=UTC)]
    app.state.clock = lambda: now[0]
    installation = str(uuid4())
    enrolled = client.post(
        "/v1/activity/enrolments",
        headers=headers,
        json={
            "requestId": str(uuid4()),
            "installationId": installation,
            "observedAt": now[0].isoformat(),
            "steps": 0,
        },
    ).json()
    catalogue = client.get("/v1/catalog", headers=headers).json()
    assert {s["speciesId"] for s in catalogue["species"]} == {"oak", "moonwillow"}
    assert {s["rarity"] for s in catalogue["species"]} == {"common"}
    placed = client.post(
        "/v1/me/garden/edits",
        headers=headers,
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": catalogue["catalogVersion"],
            "actions": [
                {
                    "action": "plant",
                    "plantId": result["plant"]["plantId"],
                    "x": 3,
                    "y": 3,
                    "rotationDegrees": 0,
                }
            ],
        },
    )
    assert placed.status_code == 200, placed.text
    now[0] += timedelta(seconds=10)
    grown = client.post(
        "/v1/activity/sync",
        headers=headers,
        json={
            "requestId": str(uuid4()),
            "installationId": installation,
            "deviceId": enrolled["device"]["deviceId"],
            "observedAt": now[0].isoformat(),
            "days": [{"gameDate": "2026-10-23", "steps": 10000}],
        },
    )
    assert grown.status_code == 200, grown.text
    assert grown.json()["garden"]["plants"][0]["growthStage"] == "seedling"


def test_new_pool_keeps_existing_opening_uniqueness_and_receipts(species_economy):
    bought = exchange(species_economy, offerVersion=2).json()
    pack = bought["packs"][0]["ownedPackId"]
    original = open_pack(species_economy, pack).json()
    assert open_pack(species_economy, pack).json() == original
    with species_economy["app"].state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PackOpening)) == 1
        assert session.get(VisitorWallet, species_economy["owner"]).tokens == 95


def test_new_fixture_resolves_variant_profile_overrides_before_pinning(economy):
    from forest_api.models import GrowthProfile, Variant

    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        session.add(
            GrowthProfile(
                id="blue_override",
                version=1,
                thresholds={"sprout": 0, "seedling": 10, "young": 20, "adult": 30},
                maximum_growth_micro_units=30,
            )
        )
        session.flush()
        variant = session.get(Variant, ("oak", "blue"))
        variant.growth_profile_id = "blue_override"
        variant.growth_profile_version = 1
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
    value = definition(economy)
    oak = next(s for s in value["rarities"][0]["species"] if s["speciesId"] == "oak")
    blue = next(v for v in oak["variants"] if v["variantId"] == "blue")
    assert blue["profiles"]["growth"] == {"id": "blue_override", "version": 1}


def test_concurrent_species_first_openings_select_once(species_economy):
    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.collection_schemas import OpenPackRequest

    bought = exchange(species_economy, offerVersion=2).json()
    app = species_economy["app"]
    bounds = []

    def random_below(limit):
        bounds.append(limit)
        return 0

    def opening(_):
        with app.state.database.sessions() as session:
            return collection.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                OpenPackRequest(request_id=uuid4()),
                lambda: datetime.now(UTC),
                pack_id=UUID(bought["packs"][0]["ownedPackId"]),
                randbelow=random_below,
            )

    with ThreadPoolExecutor(max_workers=4) as executor:
        results = list(executor.map(opening, range(4)))
    assert all(result == results[0] for result in results)
    assert bounds == [100, 2, 100]
