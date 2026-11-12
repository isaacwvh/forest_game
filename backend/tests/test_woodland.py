"""Woodland publication, skill accounting, compatibility and recoverable gem purchases."""

from copy import deepcopy
from dataclasses import replace
from datetime import timedelta
from decimal import Decimal
from fractions import Fraction
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from test_activity_launch import player as player
from test_skills import facts, snapshot
from test_visitor_rescale import scene as scene

from forest_api import progression, services, woodland
from forest_api.calculations import MICRO, MetricRate, calculate_growth
from forest_api.collection_models import CollectionEvent, OwnedPack, PackDefinition
from forest_api.models import BehaviourProfile, Garden, OwnedPlant, PlayerProgress, Species
from forest_api.schemas import BehaviourDefinition
from forest_api.skill_rules import CAPS_V1, SkillCaps
from forest_api.skills import SkillSnapshot
from forest_api.visitor_models import VisitorWallet


@pytest.fixture
def forest(scene, app, client):
    with app.state.database.sessions() as session:
        preview = woodland.publish(session, app.state.settings)
    assert preview["applied"] is False
    with app.state.database.sessions() as session:
        result = woodland.publish(
            session, app.state.settings, apply=True, clock=lambda: scene["now"][0]
        )
    assert result["applied"]
    return {**scene, "headers": {**scene["headers"], "X-Forest-Woodland": "1"}}


def request(client, forest, path, **fields):
    response = client.post(
        "/v1/me/" + path, headers=forest["headers"], json={"requestId": str(uuid4()), **fields}
    )
    assert response.status_code == 200, response.text
    return response.json()


def species_facts(identifier, *, id=None, stage="adult"):
    record = next(p for p in woodland.release()["species"] if p["id"] == identifier)
    return replace(
        facts(id or identifier),
        species=identifier,
        stage=stage,
        tags=tuple(record["tags"]),
        behaviour=BehaviourDefinition.model_validate(record["behaviour"]),
    )


def test_catalog_is_complete_and_publication_is_repeat_safe(forest, app, client):
    catalog = client.get("/v1/catalog", headers=forest["headers"]).json()
    assert catalog["catalogVersion"] == woodland.VERSION
    assert len(catalog["species"]) == 30
    assert sum(len(p["variants"]) for p in catalog["species"]) == 47
    assert {
        r: sum(p["rarity"] == r for p in catalog["species"])
        for r in ("common", "rare", "epic", "legendary")
    } == {"common": 10, "rare": 10, "epic": 7, "legendary": 3}
    offers = client.get("/v1/me/collection", headers=forest["headers"]).json()["offers"]
    assert {(o["offerId"], o["currency"], o["tokenCost"]) for o in offers} == {
        ("woodland", "tokens", "1200"),
        ("select-woodland", "tokens", "4800"),
        ("premium-woodland", "gems", "5"),
    }
    for offer in offers:
        assert sum(len(p["species"]) for p in offer["pack"]["rarities"]) == 30
    with app.state.database.sessions() as session:
        assert woodland.publish(session, app.state.settings, apply=True)["alreadyPublished"]
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, UUID(forest["plant"])).clearance_radius == Decimal("0.9")
        assert session.get(Species, "oak").clearance_radius == Decimal("1.35")


def test_gem_purchase_replay_and_reconciliation(forest, app, client):
    owner = forest["owner"]
    with app.state.database.sessions.begin() as session:
        session.get(PlayerProgress, owner).activity_steps = 100000
        progression.credit_steps(session, owner, 100000, uuid4(), forest["now"][0])
    body = {"requestId": str(uuid4()), "offerId": "premium-woodland", "offerVersion": 20}
    path = "/v1/me/exchanges"
    first = client.post(path, headers=forest["headers"], json=body)
    assert first.status_code == 200, first.text
    assert first.json()["gemsSpent"] == "5"
    assert first.json()["gemBalance"] == "5"
    assert first.json()["tokensSpent"] == "0"
    assert client.post(path, headers=forest["headers"], json=body).json() == first.json()
    with app.state.database.sessions() as session:
        progression.reconcile(session, owner, session.get(VisitorWallet, owner))
        assert session.scalar(select(func.sum(CollectionEvent.gem_delta))) == -5
    pack = first.json()["packs"][0]["ownedPackId"]
    opened = request(client, forest, "packs/" + pack + "/open")
    assert opened["plant"]["growthMicroUnits"] == "0"
    assert (
        request(client, forest, "packs/" + pack + "/open")["plant"]["plantId"]
        == opened["plant"]["plantId"]
    )


def test_insufficient_gems_and_client_gate_do_not_spend_or_award(forest, app, client):
    body = {"requestId": str(uuid4()), "offerId": "premium-woodland", "offerVersion": 20}
    denied = client.post("/v1/me/exchanges", headers=forest["headers"], json=body)
    assert denied.status_code == 409
    assert denied.json()["error"]["code"] == "insufficient_gems"
    old = {k: v for k, v in forest["headers"].items() if k != "X-Forest-Woodland"}
    gated = client.post("/v1/me/exchanges", headers=old, json={**body, "requestId": str(uuid4())})
    assert gated.status_code == 426
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 0
        assert session.get(VisitorWallet, forest["owner"]).gems == 0


def test_historical_pack_profiles_and_placement_survive(scene, app, client):
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, scene["owner"]).tokens = 1200
    old = request(client, scene, "exchanges", offerId="woodland", offerVersion=11)
    with app.state.database.sessions() as session:
        definition = deepcopy(session.get(PackDefinition, ("woodland", 11)).definition)
    with app.state.database.sessions() as session:
        woodland.publish(session, app.state.settings, apply=True, clock=lambda: scene["now"][0])
    opened = request(client, scene, "packs/" + old["packs"][0]["ownedPackId"] + "/open")
    assert not opened["plant"]["pinnedProfiles"]["growth"]["id"].startswith("woodland_")
    assert opened["plant"]["clearanceRadius"] in (0.9, 0.95)
    with app.state.database.sessions() as session:
        assert session.get(PackDefinition, ("woodland", 11)).definition == definition


@pytest.mark.parametrize("identifier", [p["id"] for p in woodland.release()["species"]])
def test_every_plant_profile_and_effect_resolves(identifier):
    source = species_facts(identifier)
    garden = SkillSnapshot((source,), SkillCaps.model_validate(CAPS_V1), "test", flights=10)
    assert garden.attraction() >= 0
    assert garden.capacity(600, 1800) >= 600
    assert garden.growth_interval(source, ["steps"], 1900, 300)[1] >= 1


def test_step_bands_split_exactly_and_do_not_stack_duplicate_sources():
    first = species_facts("dewjewel")
    later = species_facts("mirrorleaf")
    recipient = species_facts("oak", stage="sprout")
    garden = SkillSnapshot(
        (first, replace(first, id="duplicate"), later, recipient),
        SkillCaps.model_validate(CAPS_V1),
        "test",
    )
    factors, _ = garden.growth_interval(recipient, ["steps"], 1900, 300)
    assert factors["steps"] == Fraction(17, 15)
    trace = garden.context_interval(recipient, ["steps"], 1900, 300)
    assert [part["waterSteps"] for part in trace["stepBandSegments"]] == ["100", "200"]
    assert all(part["effects"] for part in trace["stepBandSegments"])
    active = garden.summary()["activeSkills"]
    assert {row.get("stepBand") for row in active} >= {"first_2000", "after_2000"}
    left = garden.growth_interval(recipient, ["steps"], 1900, 100)[0]["steps"]
    right = garden.growth_interval(recipient, ["steps"], 2000, 200)[0]["steps"]
    assert 100 * left + 200 * right == 300 * factors["steps"]


def test_distinct_species_companions_and_moonwillow_strongest():
    chorus = species_facts("duskwand")
    oak = species_facts("oak")
    garden = snapshot(chorus, oak, replace(oak, id="second"))
    assert garden.total("attraction_garden") == Fraction("0.02")
    moon = species_facts("moonwillow")
    legacy = deepcopy(moon.behaviour.model_dump())
    legacy["garden_effects"][0]["magnitude"]["value"] = "0.04"
    old = replace(moon, id="old", behaviour=BehaviourDefinition.model_validate(legacy))
    assert snapshot(moon, old, oak).growth(oak, ["steps"])[1] == Fraction("1.08")
    assert snapshot(replace(moon, stage="young"), oak).growth(oak, ["steps"])[1] == 1


def test_new_conversions_do_not_change_legacy_growth():
    rate = {"workout_minutes.running": MetricRate(normalisation="10", water_micro_units=2500000)}
    new = species_facts("oak").behaviour
    adjusted = woodland.plant_rates(new, rate)
    assert rate["workout_minutes.running"].water_micro_units == 2500000
    result = calculate_growth(
        {"workout_minutes.running": 60}, adjusted, new.metric_multipliers, 0, 1000 * MICRO, {}
    )
    assert result.awarded == 15 * MICRO


def test_daily_flights_are_prospective_and_expire_at_midnight(forest, app, client):
    from forest_api import visitors
    from forest_api.woodland_models import DailySkillActivity

    with app.state.database.sessions.begin() as session:
        plant = services.award_plant(
            session, forest["owner"], "boughrunner", "standard", "test", "flights"
        )
        plant.growth_micro_units = 480 * MICRO
        garden = session.scalar(select(Garden).where(Garden.owner_id == forest["owner"]))
        from forest_api.models import GardenPlacement

        session.add(
            GardenPlacement(
                plant_id=plant.id,
                owner_id=forest["owner"],
                garden_id=garden.id,
                x=5,
                y=5,
                rotation_degrees=0,
            )
        )
        day = forest["now"][0].date()
        session.add(DailySkillActivity(owner_id=forest["owner"], game_date=day, flights=10))
        session.flush()
        visitors.VisitorAccounting(app.state.settings).after_change(
            session, garden, forest["now"][0]
        )
        skill = services.skill_snapshot(session, garden, boundary=forest["now"][0])
        assert skill.total("attraction_garden") == Fraction("0.1")
        end = forest["now"][0] + timedelta(days=1)
        visitors.settle(session, app.state.settings, garden, end)
        assert (
            services.skill_snapshot(session, garden, boundary=end).total("attraction_garden") == 0
        )


def test_every_variant_has_approved_resale(forest, app):
    from forest_api.inventory_management import quote

    with app.state.database.sessions.begin() as session:
        for plant in woodland.release()["species"]:
            for variant in plant["variants"]:
                copy = services.award_plant(
                    session,
                    forest["owner"],
                    plant["id"],
                    variant,
                    "test",
                    plant["id"] + "/" + variant,
                )
                result = quote(session, forest["owner"], copy)
                assert int(result["tokens"]) > 0
                if plant["id"] not in {"oak", "moonwillow"}:
                    assert result["variantBasisPoints"] == 10000


def test_step_band_activity_sync_is_exact_and_replay_safe(forest, app, client):
    from forest_api.models import GardenPlacement

    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden).where(Garden.owner_id == forest["owner"]))
        copies = {}
        for name, x, y in [("dewjewel", 5, 5), ("mirrorleaf", 8, 3), ("oak", 7.5, 7.5)]:
            copy = services.award_plant(session, forest["owner"], name, "standard", "test", name)
            if name != "oak":
                copy.growth_micro_units = next(
                    p["growth"]["adult"] for p in woodland.release()["species"] if p["id"] == name
                )
            copies[name] = copy.id
            session.add(
                GardenPlacement(
                    plant_id=copy.id,
                    owner_id=forest["owner"],
                    garden_id=garden.id,
                    x=x,
                    y=y,
                    rotation_degrees=0,
                )
            )
        session.flush()
    result, body = forest["submit"](steps=4000)
    recipient = next(p for p in result["garden"]["plants"] if p["plantId"] == str(copies["oak"]))
    assert recipient["growthMicroUnits"] == "33500000"
    retry = client.post("/v1/activity/sync", headers=forest["headers"], json=body)
    assert retry.status_code == 200
    assert retry.json() == result
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, copies["oak"]).growth_micro_units == 33500000


def test_existing_moonwillow_upgrades_only_its_skill(scene, app):
    with app.state.database.sessions.begin() as session:
        copy = services.award_plant(session, scene["owner"], "moonwillow", "golden", "test", "moon")
        identity = copy.id
        previous = (copy.growth_profile_id, copy.growth_profile_version, copy.clearance_radius)
        old_behavior = (copy.behaviour_profile_id, copy.behaviour_profile_version)
    with app.state.database.sessions() as session:
        woodland.publish(session, app.state.settings, apply=True, clock=lambda: scene["now"][0])
    with app.state.database.sessions() as session:
        copy = session.get(OwnedPlant, identity)
        assert (
            copy.growth_profile_id,
            copy.growth_profile_version,
            copy.clearance_radius,
        ) == previous
        upgraded = session.get(
            BehaviourProfile, (copy.behaviour_profile_id, copy.behaviour_profile_version)
        )
        assert upgraded.rules["gardenEffects"][0]["magnitude"]["value"] == "0.08"
        assert (
            session.get(BehaviourProfile, old_behavior).rules["gardenEffects"][0]["magnitude"][
                "value"
            ]
            == "0.04"
        )


@pytest.mark.parametrize(
    "source,scope,metric,value",
    [
        ("moonwillow", "water", None, "0.08"),
        ("bluebell", "activity", "steps", "0.125"),
        ("berry-shrub", "attraction_garden", None, "0.04"),
        ("pearlseal", "offline_capacity", None, "0.15"),
        ("swiftgrass", "activity", "workout_minutes.running", "0.1"),
        ("ironheart", "activity", "workout_minutes.yoga", "0.08"),
        ("sunspike", "activity", "active_energy_kcal", "0.05"),
        ("sunspike", "offline_capacity", None, "0.08"),
        ("coppercurl-maple", "offline_capacity", None, "0.2"),
    ],
)
def test_published_fixed_skill_values(source, scope, metric, value):
    plant = species_facts(source)
    recipient = species_facts("oak", stage="sprout")
    target = None if scope in {"attraction_garden", "offline_capacity"} else recipient
    assert snapshot(plant, recipient).total(scope, target, metric) == Fraction(value)


@pytest.mark.parametrize(
    "source,recipient,companion,scope,metric,base,upgraded",
    [
        ("moonbell", "oak", "heartleaf", "activity", "steps", "0.04", "0.08"),
        ("honeycluster", "oak", "dawnsorrel", "attraction_plant", None, "0.04", "0.06"),
        ("silverlace-fern", "dewfern", "oak", "water", None, "0.075", "0.1"),
    ],
)
def test_conditional_skills_replace_the_base(
    source, recipient, companion, scope, metric, base, upgraded
):
    plant = species_facts(source)
    target = species_facts(recipient, stage="sprout")
    other = species_facts(companion, stage="sprout")
    assert snapshot(plant, target).total(scope, target, metric) == Fraction(base)
    assert snapshot(plant, target, other).total(scope, target, metric) == Fraction(upgraded)


def test_copy_counts_and_stage_selectors_are_exact():
    fern = species_facts("dewfern")
    babies = [replace(fern, id=str(i), stage="sprout") for i in range(5)]
    target = species_facts("oak", stage="sprout")
    assert snapshot(fern, *babies, target).total("water", target) == Fraction("0.07")
    canopy = species_facts("havenbough")
    young = replace(target, id="young", stage="young")
    assert snapshot(canopy, target, young).total("water", target) == Fraction("0.115")
    assert snapshot(canopy, target, young).total("water", young) == 0


def test_daily_flight_facts_continue_after_the_water_cap(forest, app):
    from forest_api.woodland_models import DailySkillActivity

    forest["submit"](flightsClimbed=205)
    forest["submit"](flightsClimbed=210)
    with app.state.database.sessions() as session:
        rows = list(
            session.scalars(
                select(DailySkillActivity).where(DailySkillActivity.owner_id == forest["owner"])
            )
        )
        assert len(rows) == 1
        assert rows[0].flights == 205
