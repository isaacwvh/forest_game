import copy
import json
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from fractions import Fraction
from pathlib import Path
from threading import Event
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from test_activity import actors as actors
from test_activity import body_for, submit

from forest_api.calculations import MICRO, MetricRate, calculate_growth
from forest_api.models import BehaviourProfile, OwnedPlant, PlantGrowthCredit, PlayerProgress
from forest_api.schemas import BehaviourDefinition
from forest_api.skill_rules import CAPS_V1, CAPS_VERSION, SkillCaps
from forest_api.skill_seed import SLEEPING_DEW, grant_adult_moonwillow, seed_skills
from forest_api.skills import PlantFacts, SkillSnapshot


def effect(**updates):
    row = copy.deepcopy(SLEEPING_DEW)
    row.update(updates)
    return row


def facts(plant_id="source", *, stage="adult", effects=None, species="moonwillow", attraction=20):
    return PlantFacts(
        plant_id,
        species,
        "standard",
        stage,
        ("tree",),
        attraction * MICRO,
        "test",
        2,
        BehaviourDefinition(
            schemaVersion=2, metricMultipliers={"steps": 1}, gardenEffects=effects or []
        ),
    )


def snapshot(*plants):
    return SkillSnapshot(tuple(plants), SkillCaps.model_validate(CAPS_V1), CAPS_VERSION)


@pytest.mark.parametrize(
    "stage,expected",
    [(s, Fraction(1)) for s in ("sprout", "seedling", "young")] + [("adult", Fraction(26, 25))],
)
def test_sleeping_dew_activation_and_duplicate_group(stage, expected):
    source = facts(stage=stage, effects=[effect()])
    recipient = facts("recipient", stage="young", species="oak")
    garden = snapshot(source, replace(source, id="second", variant="golden"), recipient)
    assert garden.growth(recipient, ["steps"])[1] == expected
    assert garden.growth(source, ["steps"])[1] == expected
    active = garden.summary()["activeSkills"]
    assert len(active) == (1 if stage == "adult" else 0)
    if active:
        assert active[0]["eligibleSourcePlantIds"] == ["second", "source"]
    assert snapshot(recipient).growth(recipient, ["steps"])[1] == 1


def test_recipient_filtering_precedes_strongest_and_count_is_shared():
    broad = effect(magnitude={"value": "0.05"})
    narrow = effect(
        id="narrow",
        target="selected_plants",
        recipients={"stages": ["seedling"]},
        magnitude={"value": "0.10"},
    )
    counted = effect(
        id="counted",
        stackingGroup="counted",
        magnitude={
            "type": "per_copy",
            "value": "0.0175",
            "maximum": "0.07",
            "selector": {"species": ["moonwillow"], "stages": ["adult"]},
        },
    )
    plants = [facts(str(i), effects=[broad, narrow, counted]) for i in range(5)]
    seedling = facts("baby", stage="seedling", species="oak")
    garden = snapshot(*plants, seedling)
    assert garden.growth(seedling, ["steps"])[1] == Fraction(117, 100)
    assert garden.growth(plants[0], ["steps"])[1] == Fraction(112, 100)


@pytest.mark.parametrize("scope", ["activity", "water"])
@pytest.mark.parametrize("bonus,expected", [("1.49", "2.49"), ("1.5", "2.5"), ("2", "2.5")])
def test_growth_caps(scope, bonus, expected):
    source = facts(
        effects=[
            effect(
                scope=scope,
                metric="steps" if scope == "activity" else None,
                magnitude={"value": bonus},
            )
        ]
    )
    activity, water = snapshot(source).growth(source, ["steps", "flights_climbed"])
    assert (activity["steps"] if scope == "activity" else water) == Fraction(expected)
    assert activity["flights_climbed"] == 1


def test_layers_compound_to_625_and_fractional_carry_is_chunk_invariant():
    source = facts(
        effects=[
            effect(magnitude={"value": "2"}),
            effect(
                id="steps",
                scope="activity",
                metric="steps",
                stackingGroup="steps",
                magnitude={"value": "2"},
            ),
        ]
    )
    activity, water = snapshot(source).growth(source, ["steps"])
    rate = {"steps": MetricRate(normalisation="3", water_micro_units=10)}
    full = calculate_growth(
        {"steps": 300},
        rate,
        {"steps": 1},
        0,
        100000,
        {},
        activity_factors=activity,
        water_factor=water,
    )
    growth, remainder = 0, {}
    for _ in range(300):
        result = calculate_growth(
            {"steps": 1},
            rate,
            {"steps": 1},
            growth,
            100000,
            remainder,
            activity_factors=activity,
            water_factor=water,
        )
        growth, remainder = result.growth, result.fractional_state
    assert growth == full.growth == 6250
    assert remainder == full.fractional_state


def test_visitor_percentage_flat_and_final_caps():
    effects = [
        effect(
            id="plant",
            system="visitors",
            scope="attraction_plant",
            stackingGroup="plant",
            magnitude={"value": "3"},
        ),
        effect(
            id="garden",
            system="visitors",
            scope="attraction_garden",
            target="garden",
            stackingGroup="garden",
            magnitude={"value": "3"},
        ),
        effect(
            id="flat",
            system="visitors",
            scope="attraction_garden",
            target="garden",
            operation="flat",
            stackingGroup="flat",
            magnitude={"value": "100"},
        ),
        effect(
            id="capacity",
            system="visitors",
            scope="offline_capacity",
            target="garden",
            stackingGroup="capacity",
            magnitude={"value": "3"},
        ),
        effect(
            id="flat_capacity",
            system="visitors",
            scope="offline_capacity",
            target="garden",
            operation="flat",
            stackingGroup="flat_capacity",
            magnitude={"value": "100"},
        ),
    ]
    garden = snapshot(facts(effects=effects))
    assert garden.attraction() == 40 * MICRO
    assert garden.capacity(30, 120) == 90
    assert garden.capacity(30, 50) == 50
    assert snapshot().attraction() == 0
    assert snapshot(facts(effects=[effects[2]])).attraction() == 25 * MICRO
    assert snapshot(facts(effects=[effects[4]])).capacity(30, 120) == 40
    # Flat attraction enters after percentages and cannot amplify past its own budget.
    modest = copy.deepcopy(effects[1])
    modest["magnitude"]["value"] = "0.1"
    assert snapshot(facts(effects=[modest, effects[2]])).attraction() == 27 * MICRO


@pytest.mark.parametrize(
    "updates",
    [
        {"minimumStage": "young"},
        {"scope": "offline_rate"},
        {"system": "visitors"},
        {"metric": "steps"},
        {"operation": "flat"},
        {"magnitude": {"value": "NaN"}},
        {"magnitude": {"value": "0.0000001"}},
        {"condition": {"type": "weather"}},
        {"magnitude": {"type": "per_copy", "value": "1"}},
        {"unknown": True},
    ],
)
def test_unsupported_components_rejected(updates):
    with pytest.raises(ValidationError):
        BehaviourDefinition(
            schemaVersion=2, metricMultipliers={"steps": 1}, gardenEffects=[effect(**updates)]
        )


@pytest.fixture
def skilled(app, client, headers, actors):
    from forest_api.collection_seed import seed_collection

    actor = actors()
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
        seed_skills(session, app.state.settings)
        grant = grant_adult_moonwillow(session, app.state.settings, actor["subject"])
    return actor, grant


def edit(client, headers, actor, plant_id, action):
    garden = client.get("/v1/me/garden", headers=headers()).json()
    row = {"action": action, "plantId": plant_id}
    if action == "plant":
        row.update(x=6, y=6, rotationDegrees=0)
    response = client.post(
        "/v1/me/garden/edits",
        headers=headers(),
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": garden["layoutVersion"],
            "catalogVersion": garden["catalogVersion"],
            "actions": [row],
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_real_sleeping_dew_growth_store_retry_and_repeat_grant(app, client, headers, skilled):
    actor, grant = skilled
    with app.state.database.sessions() as session:
        assert grant_adult_moonwillow(session, app.state.settings, "alice") == grant
    stored = client.get("/v1/me/inventory", headers=headers()).json()["plants"]
    assert len(stored) == 1 and stored[0]["growthStage"] == "adult"
    assert stored[0]["gardenSkills"][0]["id"] == "sleeping_dew"
    assert (
        client.get("/v1/me/garden", headers=headers()).json()["skillSummary"]["activeSkills"] == []
    )
    planted = edit(client, headers, actor, grant["plantId"], "plant")
    assert planted["garden"]["skillSummary"]["activeSkills"][0]["magnitude"] == "0.04"
    body = body_for(actor, 3000)
    response = client.post("/v1/activity/sync", headers=headers(), json=body)
    assert response.status_code == 200, response.text
    result = response.json()
    oak = next(p for p in result["garden"]["plants"] if p["speciesId"] == "oak")
    assert oak["growthMicroUnits"] == "10400000"
    assert client.post("/v1/activity/sync", headers=headers(), json=body).json() == result
    edit(client, headers, actor, grant["plantId"], "store")
    final = submit(client, headers, actor, 4000).json()
    assert final["garden"]["plants"][0]["growthMicroUnits"] == "20400000"
    with app.state.database.sessions() as session:
        progress = session.get(PlayerProgress, actor["owner"])
        assert progress.first_maturity_count == 0
        credits = list(
            session.scalars(
                select(PlantGrowthCredit).where(PlantGrowthCredit.plant_id == actor["plant"])
            )
        )
        assert credits[0].context["skills"]["waterFactor"] == "1.04"
        assert credits[0].context["skillBonusGrowthMicroUnits"] == "400000"
        assert session.get(OwnedPlant, UUID(grant["plantId"])).growth_micro_units == 1000 * MICRO


def test_maturing_source_cannot_boost_its_upload(app, client, headers, skilled):
    actor, grant = skilled
    edit(client, headers, actor, grant["plantId"], "plant")
    with app.state.database.sessions.begin() as session:
        session.get(OwnedPlant, UUID(grant["plantId"])).growth_micro_units = 995 * MICRO
    result = submit(client, headers, actor, 3000).json()
    oak = next(p for p in result["garden"]["plants"] if p["speciesId"] == "oak")
    assert oak["growthMicroUnits"] == "10000000"
    assert result["garden"]["skillSummary"]["activeSkills"]
    next_result = submit(client, headers, actor, 4000).json()
    assert (
        next(p for p in next_result["garden"]["plants"] if p["speciesId"] == "oak")[
            "growthMicroUnits"
        ]
        == "20400000"
    )


@pytest.mark.parametrize(
    "updates",
    [
        {"minimumStage": "young"},
        {"scope": "offline_rate"},
        {"magnitude": {"value": "NaN"}},
        {"unknown": True},
    ],
)
def test_database_rejects_invalid_direct_skill_inserts(app, updates):
    with app.state.database.sessions() as session, pytest.raises(IntegrityError), session.begin():
        session.add(
            BehaviourProfile(
                id="invalid",
                version=2,
                rules={
                    "schemaVersion": 2,
                    "metricMultipliers": {"steps": 1},
                    "conditionalModifiers": [],
                    "gardenEffects": [effect(**updates)],
                },
            )
        )
        session.flush()


def test_native_skills_contract_uses_actual_resolved_growth():
    from forest_api.activity_schemas import RecapList, SyncResult
    from forest_api.schemas import CatalogueDTO, GardenDTO, InventoryDTO

    path = Path(__file__).resolve().parents[2] / (
        "frontend/MovementForest/Resources/Fixtures/skills-contract.json"
    )
    fixture = json.loads(path.read_text(encoding="utf-8"))
    for key in ("emptyGarden", "plantedGarden", "storedGarden"):
        GardenDTO.model_validate(fixture[key])
    CatalogueDTO.model_validate(fixture["catalogue"])
    InventoryDTO.model_validate(fixture["inventory"])
    result = SyncResult.model_validate(fixture["syncResult"])
    recaps = RecapList.model_validate(fixture["recaps"])
    assert (
        next(p for p in result.garden.plants if p.species_id == "oak").growth_micro_units
        == "10400000"
    )
    assert recaps.recaps[0].payload["plants"][0]["skillBonusGrowthMicroUnits"] == "400000"


@pytest.mark.parametrize("store_first", [True, False])
def test_skill_sync_store_race_uses_locked_source_snapshot(
    app, client, headers, skilled, store_first
):
    from forest_api import activity, placement
    from forest_api.activity_schemas import SyncActivity
    from forest_api.auth import DEV_ISSUER, Identity
    from forest_api.schemas import GardenEditRequest

    actor, grant = skilled
    edit(client, headers, actor, grant["plantId"], "plant")
    entered, release = Event(), Event()
    garden = client.get("/v1/me/garden", headers=headers()).json()
    edit_body = GardenEditRequest.model_validate(
        {
            "requestId": str(uuid4()),
            "catalogVersion": garden["catalogVersion"],
            "expectedLayoutVersion": garden["layoutVersion"],
            "actions": [{"action": "store", "plantId": grant["plantId"]}],
        }
    )

    class Gate:
        def before_change(self, *args):
            app.state.accounting.before_change(*args)
            entered.set()
            assert release.wait(10)

        def after_change(self, *args):
            app.state.accounting.after_change(*args)

    def sync(hold=False):
        with app.state.database.sessions() as session:
            return activity.sync(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                SyncActivity.model_validate(body_for(actor, 3000)),
                accounting=Gate() if hold else app.state.accounting,
                clock=lambda: actor["now"][0],
            )

    def store(hold=False):
        with app.state.database.sessions() as session:
            return placement.edit_garden(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                edit_body,
                accounting=Gate() if hold else app.state.accounting,
                clock=lambda: actor["now"][0],
            )

    first, second = (store, sync) if store_first else (sync, store)
    with ThreadPoolExecutor(2) as pool:
        f1 = pool.submit(first, True)
        assert entered.wait(10)
        f2 = pool.submit(second)
        release.set()
        f1.result(timeout=15)
        f2.result(timeout=15)
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, actor["plant"]).growth_micro_units == (
            10_000_000 if store_first else 10_400_000
        )


def test_concurrent_test_grants_remain_unique(app, skilled):
    _, expected = skilled

    def grant(_):
        with app.state.database.sessions() as session:
            return grant_adult_moonwillow(session, app.state.settings, "alice")

    with ThreadPoolExecutor(4) as pool:
        assert list(pool.map(grant, range(4))) == [expected] * 4


def test_skill_publication_preserves_legacy_packs_and_copies(economy):
    from test_collection import exchange, open_pack

    from forest_api.collection_models import ExchangeOffer, PackDefinition
    from forest_api.collection_seed import seed_collection

    app = economy["app"]
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
        old_definition = copy.deepcopy(session.get(PackDefinition, ("moonwillow", 1)).definition)
    old_pack = exchange(economy, offerId="moonwillow").json()["packs"][0]["ownedPackId"]
    with app.state.database.sessions() as session:
        seed_skills(session, app.state.settings)
        seed_skills(session, app.state.settings)
        assert session.get(PackDefinition, ("moonwillow", 1)).definition == old_definition
    legacy = open_pack(economy, old_pack).json()["plant"]
    assert legacy["pinnedProfiles"]["behaviour"]["version"] == 1
    assert legacy["gardenSkills"] == []
    new_pack = exchange(economy, offerId="moonwillow", offerVersion=2).json()["packs"][0][
        "ownedPackId"
    ]
    current = open_pack(economy, new_pack).json()["plant"]
    assert current["pinnedProfiles"]["behaviour"]["version"] == 2
    assert current["gardenSkills"][0]["id"] == "sleeping_dew"
    with app.state.database.sessions.begin() as session:
        session.get(ExchangeOffer, ("moonwillow", 2)).active = False
    with app.state.database.sessions() as session:
        seed_skills(session, app.state.settings)
        assert session.get(ExchangeOffer, ("moonwillow", 2)).active is False
