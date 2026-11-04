"""Capacity races, exact resale and permanent recovery after live-copy retirement."""

from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select
from sqlalchemy.exc import DBAPIError
from test_collection import exchange, open_pack
from test_placement import edit_body, plant_action

from forest_api import collection, history, recovery, services
from forest_api import inventory_management as inventory
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.collection_models import OwnedPack, PackOpening
from forest_api.collection_schemas import ExchangeRequest, OpenPackRequest
from forest_api.errors import ApiError
from forest_api.history_models import GrowthDaySummary
from forest_api.models import (
    ApiRequest,
    EconomyConfig,
    Garden,
    OwnedPlant,
    PlantIdentity,
    PlantSale,
)
from forest_api.visitor_models import VisitorWallet


def grant(economy, variant="standard", water=0):
    with economy["app"].state.database.sessions.begin() as session:
        plant = services.award_plant(
            session, economy["owner"], "oak", variant, "test", str(uuid4())
        )
        plant.growth_micro_units = water
        return plant.id


def quote(economy, plant):
    return economy["client"].get(f"/v1/me/plants/{plant}/sale-quote", headers=economy["headers"])


def sale_body(value, **changes):
    return {
        "requestId": str(uuid4()),
        "valuationVersion": value["valuationVersion"],
        "expectedTokens": value["tokens"],
        "expectedGrowthMicroUnits": value["growthMicroUnits"],
        **changes,
    }


def sell(economy, plant, body=None, **changes):
    return economy["client"].post(
        f"/v1/me/plants/{plant}/sell",
        headers={**economy["headers"], "X-Forest-Recovery": "1"},
        json=body or sale_body(quote(economy, plant).json(), **changes),
    )


@pytest.mark.parametrize(
    "base,multiplier,water,adult,expected",
    [
        (240, 10000, 0, 1_000_000_000, 60),
        (240, 12500, 400_000_000, 1_000_000_000, 105),
        (240, 15000, 1_000_000_000, 1_000_000_000, 180),
        (720, 15000, 400_000_000, 1_000_000_000, 378),
        (720, 15000, 1_000_000_000, 1_000_000_000, 540),
        (960, 15000, 9_000_000_000, 1_000_000_000, 720),
        (240, 12500, 333_333_333, 1_000_000_000, 99),
        (240, 10000, 200_000_000, 400_000_000, 90),
    ],
)
def test_exact_prices(base, multiplier, water, adult, expected):
    assert inventory.price(base, multiplier, water, adult) == expected


def test_live_sale_frees_space_and_replays_after_response_compaction(economy):
    plant = grant(economy, "blue", 400_000_000)
    value = quote(economy, plant).json()
    assert value["tokens"] == "105"
    body = sale_body(value)
    response = sell(economy, plant, body)
    assert response.status_code == 200, response.text
    receipt = response.json()
    assert receipt["tokenBalance"] == "205" and receipt["tokensEarned"] == "105"
    assert receipt["capacity"]["ownedPlants"] == 1
    assert sell(economy, plant, body).json() == receipt
    app = economy["app"]
    with app.state.database.sessions() as session:
        assert session.get(OwnedPlant, plant) is None
        assert session.get(PlantIdentity, plant) is not None
        assert session.scalar(select(func.count()).select_from(PlantSale)) == 1
        now = session.get(ApiRequest, (economy["owner"], UUID(body["requestId"]))).created_at
    with app.state.database.sessions() as session:
        recovery.maintain(session, apply=True, now=now + timedelta(days=8))
    with app.state.database.sessions() as session:
        assert session.get(ApiRequest, (economy["owner"], UUID(body["requestId"]))).response is None
    assert sell(economy, plant, body).json() == receipt
    with app.state.database.sessions.begin() as session:
        session.execute(delete(ApiRequest).where(ApiRequest.request_id == UUID(body["requestId"])))
    assert sell(economy, plant, body).json() == receipt
    conflict = sell(economy, plant, {**body, "expectedTokens": "106"})
    assert (
        conflict.status_code == 409 and conflict.json()["error"]["code"] == "idempotency_conflict"
    )


def test_full_plants_block_open_without_consuming_and_sale_unblocks(economy):
    app = economy["app"]
    app.state.settings.plant_capacity = 2
    plant = grant(economy)
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]
    request = uuid4()
    result = open_pack(economy, pack, request)
    assert result.status_code == 409 and result.json()["error"]["code"] == "plant_capacity_full"
    assert (
        len(economy["client"].get("/v1/me/packs", headers=economy["headers"]).json()["packs"]) == 1
    )
    assert sell(economy, plant).status_code == 200
    opened = open_pack(economy, pack, request)
    assert opened.status_code == 200
    assert open_pack(economy, pack, request).json() == opened.json()


def test_full_packs_block_purchase_and_quantity_is_atomic(economy):
    app = economy["app"]
    app.state.settings.pack_capacity = 2
    first = exchange(economy).json()
    blocked = exchange(economy, quantity=2)
    assert blocked.status_code == 409 and blocked.json()["error"]["code"] == "pack_capacity_full"
    second = exchange(economy).json()
    assert second["tokenBalance"] == "90"
    assert exchange(economy).status_code == 409
    replay = exchange(economy, requestId=first["requestId"])
    assert replay.json() == first
    assert open_pack(economy, first["packs"][0]["ownedPackId"]).status_code == 200
    assert exchange(economy).status_code == 200


def test_capacity_is_global_and_not_the_loaded_page(economy):
    for _ in range(4):
        grant(economy)
    response = economy["client"].get("/v1/me/inventory?limit=1", headers=economy["headers"]).json()
    assert len(response["plants"]) == 1
    assert response["capacity"]["ownedPlants"] == 5
    assert response["capacity"]["storedPlants"] == 5
    assert (
        response["capacity"]
        == economy["client"].get("/v1/me/capacity", headers=economy["headers"]).json()
    )


def test_starter_planted_and_foreign_copies_cannot_be_sold(economy, register, headers):
    app = economy["app"]
    with app.state.database.sessions() as session:
        starter = session.scalar(
            select(OwnedPlant.id).where(OwnedPlant.owner_id == economy["owner"])
        )
    assert quote(economy, starter).json()["error"]["code"] == "starter_protected"
    other = register("bob")
    assert quote(economy, other["starterPlantId"]).status_code == 404
    plant = grant(economy)
    body = sale_body(quote(economy, plant).json())
    placed = economy["client"].post(
        "/v1/me/garden/edits", headers=economy["headers"], json=edit_body(plant_action(plant))
    )
    assert placed.status_code == 200, placed.text
    planted_value = quote(economy, plant)
    assert planted_value.status_code == 200, planted_value.text
    assert planted_value.json()["tokens"] == body["expectedTokens"]
    assert sell(economy, plant, body).json()["error"]["code"] == "plant_is_planted"
    stored = economy["client"].post(
        "/v1/me/garden/edits",
        headers=economy["headers"],
        json=edit_body({"action": "store", "plantId": str(plant)}, version=1),
    )
    assert stored.status_code == 200
    assert sell(economy, plant, body).status_code == 200


def test_stale_quote_cannot_silently_change_sale(economy):
    plant = grant(economy)
    body = sale_body(quote(economy, plant).json())
    with economy["app"].state.database.sessions.begin() as session:
        session.get(OwnedPlant, plant).growth_micro_units = 400_000_000
    result = sell(economy, plant, body)
    assert result.status_code == 409 and result.json()["error"]["code"] == "stale_sale_quote"
    with economy["app"].state.database.sessions() as session:
        assert session.get(OwnedPlant, plant) is not None
        assert session.get(VisitorWallet, economy["owner"]).tokens == 100


def test_sale_preserves_opening_and_growth_summary(economy):
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]
    original = open_pack(economy, pack).json()
    plant = UUID(original["plant"]["plantId"])
    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        rule = session.scalar(select(EconomyConfig.version))
        session.add(
            GrowthDaySummary(
                plant_id=plant,
                day=datetime.now(UTC).date(),
                rule_version=rule,
                profile_key="test",
                profiles={},
                awarded=1,
                skill_bonus=0,
                credit_count=1,
            )
        )
    assert sell(economy, plant).status_code == 200
    assert open_pack(economy, pack).json() == original
    with app.state.database.sessions() as session:
        assert session.scalar(select(PackOpening).where(PackOpening.plant_id == plant)) is not None
        assert (
            session.scalar(select(GrowthDaySummary).where(GrowthDaySummary.plant_id == plant))
            is not None
        )
        assert session.get(OwnedPlant, plant) is None


def test_concurrent_openings_cannot_overfill(economy):
    app = economy["app"]
    app.state.settings.plant_capacity = 2
    packs = exchange(economy, quantity=2).json()["packs"]

    def attempt(pack):
        with app.state.database.sessions() as session:
            try:
                return collection.mutate(
                    session,
                    app.state.settings,
                    Identity(DEV_ISSUER, "alice"),
                    OpenPackRequest(request_id=uuid4()),
                    lambda: datetime.now(UTC),
                    pack_id=UUID(pack["ownedPackId"]),
                )["plant"]["plantId"]
            except ApiError as error:
                return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(attempt, packs))
    assert results.count("plant_capacity_full") == 1
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 2
        assert session.scalar(select(func.count()).select_from(PackOpening)) == 1


def test_concurrent_purchases_cannot_overfill(economy):
    app = economy["app"]
    app.state.settings.pack_capacity = 1

    def attempt(_):
        with app.state.database.sessions() as session:
            try:
                collection.mutate(
                    session,
                    app.state.settings,
                    Identity(DEV_ISSUER, "alice"),
                    ExchangeRequest(request_id=uuid4(), offer_id="woodland", offer_version=1),
                    lambda: datetime.now(UTC),
                )
                return "ok"
            except ApiError as error:
                return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(attempt, range(2))) == ["ok", "pack_capacity_full"]
    with app.state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 1
        assert session.get(VisitorWallet, economy["owner"]).tokens == 95


def test_two_sale_requests_only_pay_once(economy):
    plant = grant(economy)
    value = quote(economy, plant).json()
    app = economy["app"]

    def attempt(_):
        with app.state.database.sessions() as session:
            try:
                return inventory.sell(
                    session,
                    app.state.settings,
                    Identity(DEV_ISSUER, "alice"),
                    plant,
                    inventory.SellPlant.model_validate(sale_body(value)),
                    lambda: datetime.now(UTC),
                )["tokensEarned"]
            except ApiError as error:
                return error.code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(attempt, range(2))) == ["60", "plant_not_found"]
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, economy["owner"]).tokens == 160
        assert session.scalar(select(func.count()).select_from(PlantSale)) == 1


def test_placement_limit_allows_swap_and_grandfathered_reduction(economy):
    app = economy["app"]
    app.state.settings.planted_capacity = 1
    one, two = grant(economy), grant(economy)

    def edit(*actions, version=0):
        return economy["client"].post(
            "/v1/me/garden/edits",
            headers=economy["headers"],
            json=edit_body(*actions, version=version),
        )

    assert edit(plant_action(one)).status_code == 200
    assert edit(plant_action(two, x=6), version=1).json()["error"]["code"] == "garden_capacity_full"
    assert (
        edit({"action": "store", "plantId": str(one)}, plant_action(two), version=1).status_code
        == 200
    )
    # Simulate an already over-limit account after a configuration decrease.
    app.state.settings.planted_capacity = 2
    assert edit(plant_action(one, x=6), version=2).status_code == 200
    app.state.settings.planted_capacity = 1
    assert (
        edit(
            {"action": "rotate", "plantId": str(one), "rotationDegrees": 90}, version=3
        ).status_code
        == 200
    )
    assert edit({"action": "store", "plantId": str(one)}, version=4).status_code == 200


def test_internal_awards_respect_the_same_configured_limit(economy):
    app = economy["app"]
    app.state.settings.plant_capacity = 1
    with pytest.raises(ApiError, match="Plant collection full"):
        grant(economy)


def test_sold_identity_cannot_be_reinserted(economy):
    plant = grant(economy)
    with economy["app"].state.database.sessions() as session:
        original = session.get(OwnedPlant, plant)
        values = {c.name: getattr(original, c.name) for c in OwnedPlant.__table__.columns}
    assert sell(economy, plant).status_code == 200
    with pytest.raises(DBAPIError, match="sold plant cannot be reacquired"):
        with economy["app"].state.database.sessions.begin() as session:
            session.add(OwnedPlant(**values))


def test_sale_income_reconciles_without_becoming_a_hosted_visit(economy):
    plant = grant(economy)
    app = economy["app"]
    # Remove the synthetic fixture balance so all value has a durable source.
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, economy["owner"]).tokens = 0
    assert sell(economy, plant).status_code == 200
    with app.state.database.sessions.begin() as session:
        garden = session.scalar(select(Garden.id).where(Garden.owner_id == economy["owner"]))
        history.reconcile(session, economy["owner"], garden)
        wallet = session.get(VisitorWallet, economy["owner"])
        assert wallet.tokens == 60 and wallet.hosted_active == wallet.hosted_offline == 0


def test_valuation_is_pinned_and_cannot_be_changed_by_catalogue_edits(economy):
    from forest_api.models import Species

    plant = grant(economy, "blue", 400_000_000)
    original = quote(economy, plant).json()
    with economy["app"].state.database.sessions.begin() as session:
        session.get(Species, "oak").rarity = "legendary"
    assert quote(economy, plant).json() == original
    with pytest.raises(DBAPIError):
        with economy["app"].state.database.sessions.begin() as session:
            session.get(PlantIdentity, plant).variant_basis_points = 999999


def test_wallet_overflow_rolls_back_the_entire_sale(economy):
    plant = grant(economy)
    with economy["app"].state.database.sessions.begin() as session:
        session.get(VisitorWallet, economy["owner"]).tokens = 9223372036854775807
    response = sell(economy, plant)
    assert response.status_code == 409 and response.json()["error"]["code"] == "amount_overflow"
    with economy["app"].state.database.sessions() as session:
        assert session.get(OwnedPlant, plant) is not None
        assert session.scalar(select(func.count()).select_from(PlantSale)) == 0


def test_default_fifty_pack_limit_and_exact_remaining_quantity(economy):
    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, economy["owner"]).tokens = 1000
    for count in (20, 20, 10):
        response = exchange(economy, quantity=count)
        assert response.status_code == 200, response.text
    blocked = exchange(economy)
    assert blocked.status_code == 409 and blocked.json()["error"]["code"] == "pack_capacity_full"
    snapshot = economy["client"].get("/v1/me/capacity", headers=economy["headers"]).json()
    assert snapshot == {
        "ownedPlants": 1,
        "plantedPlants": 0,
        "storedPlants": 1,
        "plantLimit": 50,
        "plantedLimit": 20,
        "unopenedPacks": 50,
        "packLimit": 50,
    }
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, economy["owner"]).tokens == 750


def test_sale_keeps_discovery_and_progress(economy):
    from forest_api import discovery
    from forest_api.models import CatalogStageDiscovery, PlayerProgress

    plant = grant(economy, water=1_000_000_000)
    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        copy = session.get(OwnedPlant, plant)
        discovery.record_reached(session, economy["owner"], [copy], datetime.now(UTC))
        progress = session.get(PlayerProgress, economy["owner"])
        if progress is None:
            progress = PlayerProgress(
                owner_id=economy["owner"], activity_steps=1000, first_maturity_count=1
            )
            session.add(progress)
        else:
            progress.activity_steps, progress.first_maturity_count = 1000, 1
    assert sell(economy, plant).status_code == 200
    with app.state.database.sessions() as session:
        stages = set(
            session.scalars(
                select(CatalogStageDiscovery.stage).where(
                    CatalogStageDiscovery.owner_id == economy["owner"],
                    CatalogStageDiscovery.variant_id == "standard",
                )
            )
        )
        assert stages == {"seedling", "young", "adult"}
        progress = session.get(PlayerProgress, economy["owner"])
        assert progress.activity_steps == 1000 and progress.first_maturity_count == 1


def test_existing_database_backfill_preserves_live_state_and_pins_value(database_factory):
    from alembic import command
    from conftest import TEST_SECRET, migration_config, migration_url

    from forest_api.config import Settings
    from forest_api.database import Database
    from forest_api.schemas import RegisterAccount
    from forest_api.seed import seed_development_catalogue

    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "0011_compact_history")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        database = Database(settings)
        try:
            with database.sessions() as session:
                seed_development_catalogue(session, settings)
            with database.sessions() as session:
                account = services.register_account(
                    session,
                    settings,
                    Identity(DEV_ISSUER, "old"),
                    RegisterAccount(
                        request_id=uuid4(),
                        username="oldplayer",
                        display_name="Old player",
                        game_timezone="Asia/Singapore",
                    ),
                )
            with database.sessions.begin() as session:
                plant = services.award_plant(
                    session, account.profile.user_id, "oak", "blue", "test", "backfill"
                )
                plant.growth_micro_units = 400_000_000
                plant.fractional_state = {"steps": "0.123"}
                plant_id = plant.id
            with database.sessions() as session:
                before = session.get(OwnedPlant, plant_id)
                before = {c.name: getattr(before, c.name) for c in OwnedPlant.__table__.columns}
            command.upgrade(configuration, "head")
            command.check(configuration)
            with database.sessions() as session:
                after = session.get(OwnedPlant, plant_id)
                assert {
                    c.name: getattr(after, c.name) for c in OwnedPlant.__table__.columns
                } == before
                assert inventory.quote(session, account.profile.user_id, after)["tokens"] == "105"
                assert session.scalar(select(func.count()).select_from(PlantIdentity)) == 2
        finally:
            database.engine.dispose()


def test_downgrade_after_a_sale_refuses_without_losing_state(economy):
    from alembic import command
    from conftest import migration_config, migration_url

    plant = grant(economy)
    assert sell(economy, plant).status_code == 200
    settings = economy["app"].state.settings
    with migration_url(settings.database_url.get_secret_value()):
        with pytest.raises(RuntimeError, match="Cannot downgrade after plant sales"):
            command.downgrade(migration_config(), "0011_compact_history")
    with economy["app"].state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PlantSale)) == 1
        assert session.get(OwnedPlant, plant) is None
