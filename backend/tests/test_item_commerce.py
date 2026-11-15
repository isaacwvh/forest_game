from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.exc import ProgrammingError

from forest_api import collection, history, item_commerce, items
from forest_api.collection_models import CollectionEvent
from forest_api.item_models import ItemIdentity, ItemSale, ItemShopOffer, ItemValuation, OwnedItem
from forest_api.main import create_app
from forest_api.visitor_models import VisitorRewardEvent, VisitorWallet, VisitorWalletEntry


@pytest.fixture
def shop(app, client, register, headers):
    account = register()
    owner = UUID(account["profile"]["userId"])
    with app.state.database.sessions() as session:
        item_commerce.publish(session, apply=True)
    with app.state.database.sessions.begin() as session:
        wallet = collection.wallet_for(session, owner)
        wallet.tokens = 2000
        event_id = uuid4()
        session.add(
            VisitorRewardEvent(
                id=event_id,
                owner_id=owner,
                kind="milestone",
                source_id=uuid4(),
                created_at=datetime.now(UTC),
                detail={"tokens": "2000"},
            )
        )
        session.flush()
        session.add(
            VisitorWalletEntry(
                id=uuid4(),
                owner_id=owner,
                event_id=event_id,
                amount=2000,
                created_at=datetime.now(UTC),
            )
        )
    return {
        "owner": owner,
        "garden": UUID(account["gardenId"]),
        "client": client,
        "headers": {
            **headers(),
            "X-Forest-Items": "1",
            "X-Forest-Item-Commerce": "1",
            "X-Forest-Recovery": "1",
        },
    }


def buy(shop, quantity=1, body=None):
    body = body or {
        "requestId": str(uuid4()),
        "offerId": "wooden-bench",
        "offerVersion": 1,
        "quantity": quantity,
    }
    return shop["client"].post("/v1/me/item-purchases", headers=shop["headers"], json=body)


def sale(shop, owned_id, *, body=None):
    body = body or {
        "requestId": str(uuid4()),
        "valuationVersion": "item-resale-v1",
        "expectedTokens": "137",
    }
    return shop["client"].post(f"/v1/me/items/{owned_id}/sell", headers=shop["headers"], json=body)


def test_purchase_sell_and_wallet_reconciliation(app, shop):
    summary = shop["client"].get("/v1/me/collection", headers=shop["headers"]).json()
    assert summary["itemOffers"][0]["tokenCost"] == "550"
    bought = buy(shop, 2)
    assert bought.status_code == 200, bought.text
    bought = bought.json()
    assert bought["tokenBalance"] == "900" and len(set(bought["ownedItemIds"])) == 2
    owned_id = bought["ownedItemIds"][0]
    quote = (
        shop["client"].get(f"/v1/me/items/{owned_id}/sale-quote", headers=shop["headers"]).json()
    )
    assert quote["tokenValue"] == "550" and quote["tokens"] == "137"
    sold = sale(shop, owned_id)
    assert sold.status_code == 200, sold.text
    assert sold.json()["tokenBalance"] == "1037"
    assert sold.json()["itemCapacity"]["ownedItems"] == 1
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 2
        assert session.scalar(select(func.count()).select_from(ItemValuation)) == 2
        history.reconcile(session, shop["owner"], shop["garden"])
        wallet = session.get(VisitorWallet, shop["owner"])
        assert wallet.hosted_active == 0 and wallet.hosted_offline == 0


def test_placed_item_has_quote_but_cannot_sell(app, shop):
    owned_id = buy(shop).json()["ownedItemIds"][0]
    placed = shop["client"].post(
        "/v1/me/garden/edits",
        headers=shop["headers"],
        json={
            "requestId": str(uuid4()),
            "expectedLayoutVersion": 0,
            "catalogVersion": "development-oak-v1",
            "actions": [],
            "itemActions": [
                {"action": "place", "itemId": owned_id, "x": 2, "y": 2, "rotationDegrees": 0}
            ],
        },
    )
    assert placed.status_code == 200, placed.text
    quote = shop["client"].get(f"/v1/me/items/{owned_id}/sale-quote", headers=shop["headers"])
    assert quote.status_code == 200 and quote.json()["tokens"] == "137"
    response = sale(shop, owned_id)
    assert response.status_code == 409 and response.json()["error"]["code"] == "item_is_placed"
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemSale)) == 0
        assert session.get(VisitorWallet, shop["owner"]).tokens == 1450


def test_full_capacity_no_partial_purchase_or_reward(app, shop):
    app.state.settings.item_capacity = 1
    response = buy(shop, 2)
    assert response.status_code == 409 and response.json()["error"]["code"] == "item_capacity_full"
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 0
        assert session.scalar(select(func.count()).select_from(CollectionEvent)) == 0
        assert session.get(VisitorWallet, shop["owner"]).tokens == 2000


def test_replays_survive_retirement_sale_and_compaction(app, shop):
    body = {"requestId": str(uuid4()), "offerId": "wooden-bench", "offerVersion": 1, "quantity": 1}
    bought = buy(shop, body=body).json()
    owned_id = bought["ownedItemIds"][0]
    sale_body = {
        "requestId": str(uuid4()),
        "valuationVersion": "item-resale-v1",
        "expectedTokens": "137",
    }
    sold = sale(shop, owned_id, body=sale_body).json()
    with app.state.database.sessions.begin() as session:
        session.get(ItemShopOffer, ("wooden-bench", 1)).active = False
    with app.state.database.sessions() as session:
        history.maintain(
            session, apply=True, responses=True, now=datetime.now(UTC) + timedelta(days=9)
        )
    assert buy(shop, body=body).json() == bought
    assert sale(shop, owned_id, body=sale_body).json() == sold
    assert sale(shop, owned_id).status_code == 404
    with app.state.database.sessions.begin() as session:
        assert session.scalar(select(func.count()).select_from(OwnedItem)) == 0
        assert session.get(VisitorWallet, shop["owner"]).tokens == 1587
        assert items.grant(
            session,
            shop["owner"],
            "wooden-bench",
            1,
            source="item_purchase",
            reference=bought["purchaseId"],
        ) == [UUID(owned_id)]
        assert session.scalar(select(func.count()).select_from(OwnedItem)) == 0
    with pytest.raises(ProgrammingError, match="Sold item identities"):
        with app.state.database.sessions.begin() as session:
            session.add(OwnedItem(id=UUID(owned_id), owner_id=shop["owner"]))
            session.flush()


def test_gift_value_and_purchased_value_are_frozen(app, shop):
    with app.state.database.sessions() as session:
        gift_id = items.grant_bench(session, "alice", apply=True)["ownedItemIds"][0]
    with app.state.database.sessions.begin() as session:
        session.get(ItemShopOffer, ("wooden-bench", 1)).active = False
        session.add(
            ItemShopOffer(
                id="wooden-bench",
                version=2,
                item_id="wooden-bench",
                item_version=1,
                token_cost=800,
                active=True,
            )
        )
    assert (
        shop["client"]
        .get(f"/v1/me/items/{gift_id}/sale-quote", headers=shop["headers"])
        .json()["tokens"]
        == "137"
    )
    response = buy(
        shop,
        body={
            "requestId": str(uuid4()),
            "offerId": "wooden-bench",
            "offerVersion": 2,
            "quantity": 1,
        },
    )
    assert response.status_code == 200, response.text
    copy_id = response.json()["ownedItemIds"][0]
    assert (
        shop["client"]
        .get(f"/v1/me/items/{copy_id}/sale-quote", headers=shop["headers"])
        .json()["tokens"]
        == "200"
    )


def test_concurrent_purchases_and_sales(app, shop):
    app.state.settings.item_capacity = 1

    def purchase(_):
        with TestClient(create_app(app.state.settings)) as client:
            return buy({**shop, "client": client}).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(purchase, range(2))) == [200, 409]
    owned_id = (
        shop["client"]
        .get("/v1/me/items", headers=shop["headers"])
        .json()["items"][0]["ownedItemId"]
    )

    def sell_copy(_):
        with TestClient(create_app(app.state.settings)) as client:
            return sale({**shop, "client": client}, owned_id).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(sell_copy, range(2))) == [200, 404]
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 1587


def test_publication_preview_is_read_only_and_does_not_reenable_retired(app):
    with app.state.database.sessions() as session:
        assert item_commerce.publish(session)["offers"][0]["tokenCost"] == "550"
    with app.state.database.sessions.begin() as session:
        assert session.get(ItemShopOffer, ("wooden-bench", 1)) is None
    with app.state.database.sessions() as session:
        item_commerce.publish(session, apply=True)
    with app.state.database.sessions.begin() as session:
        session.get(ItemShopOffer, ("wooden-bench", 1)).active = False
    with app.state.database.sessions() as session:
        assert item_commerce.publish(session, apply=True)["offers"] == []


@pytest.mark.parametrize("quantity", [0, -1, 21, True, "1", None])
def test_invalid_purchase_quantity_spends_nothing(app, shop, quantity):
    response = buy(
        shop,
        body={
            "requestId": str(uuid4()),
            "offerId": "wooden-bench",
            "offerVersion": 1,
            "quantity": quantity,
        },
    )
    assert response.status_code == 422, response.text
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 2000
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 0


def test_insufficient_funds_and_stale_offer_are_atomic(app, shop):
    response = buy(shop, 4)
    assert response.status_code == 409 and response.json()["error"]["code"] == "insufficient_tokens"
    response = buy(
        shop,
        body={
            "requestId": str(uuid4()),
            "offerId": "wooden-bench",
            "offerVersion": 2,
            "quantity": 1,
        },
    )
    assert response.status_code == 409 and response.json()["error"]["code"] == "stale_offer"
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 2000
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 0


def test_wrong_quote_foreign_sale_and_request_conflicts(app, shop, register, headers):
    body = {"requestId": str(uuid4()), "offerId": "wooden-bench", "offerVersion": 1, "quantity": 1}
    bought = buy(shop, body=body).json()
    owned_id = bought["ownedItemIds"][0]
    assert buy(shop, body={**body, "quantity": 2}).status_code == 409
    assert (
        sale(
            shop,
            owned_id,
            body={
                "requestId": str(uuid4()),
                "valuationVersion": "item-resale-v1",
                "expectedTokens": "138",
            },
        ).status_code
        == 409
    )
    register("bob")
    foreign = {**headers("bob"), "X-Forest-Item-Commerce": "1"}
    assert (
        shop["client"].get(f"/v1/me/items/{owned_id}/sale-quote", headers=foreign).status_code
        == 404
    )
    assert (
        shop["client"]
        .post(
            f"/v1/me/items/{owned_id}/sell",
            headers=foreign,
            json={
                "requestId": str(uuid4()),
                "valuationVersion": "item-resale-v1",
                "expectedTokens": "137",
            },
        )
        .status_code
        == 404
    )
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 1450
        assert session.scalar(select(func.count()).select_from(ItemSale)) == 0


def test_commit_failure_rolls_back_purchase_and_sale(app, shop, monkeypatch):
    from forest_api import services

    original = services.record_request

    def fail(*args, **kwargs):
        raise RuntimeError("simulated receipt failure")

    monkeypatch.setattr(services, "record_request", fail)
    with pytest.raises(RuntimeError, match="receipt failure"):
        buy(shop)
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 2000
        assert session.scalar(select(func.count()).select_from(ItemIdentity)) == 0
        assert session.scalar(select(func.count()).select_from(CollectionEvent)) == 0
    monkeypatch.setattr(services, "record_request", original)
    owned_id = buy(shop).json()["ownedItemIds"][0]
    monkeypatch.setattr(services, "record_request", fail)
    with pytest.raises(RuntimeError, match="receipt failure"):
        sale(shop, owned_id)
    with app.state.database.sessions.begin() as session:
        assert session.get(VisitorWallet, shop["owner"]).tokens == 1450
        assert session.get(OwnedItem, UUID(owned_id)) is not None
        assert session.scalar(select(func.count()).select_from(ItemSale)) == 0


def test_export_item_commerce_contract(app, shop):
    import json
    import os
    from pathlib import Path

    fixture = {
        "summary": shop["client"].get("/v1/me/collection", headers=shop["headers"]).json(),
        "catalogue": shop["client"].get("/v1/catalog", headers=shop["headers"]).json(),
    }
    request = {
        "requestId": str(uuid4()),
        "offerId": "wooden-bench",
        "offerVersion": 1,
        "quantity": 2,
    }
    response = buy(shop, body=request)
    assert response.status_code == 200, response.text
    fixture.update(purchaseRequest=request, purchase=response.json())
    owned_id = response.json()["ownedItemIds"][0]
    fixture["quote"] = (
        shop["client"].get(f"/v1/me/items/{owned_id}/sale-quote", headers=shop["headers"]).json()
    )
    request = {
        "requestId": str(uuid4()),
        "valuationVersion": "item-resale-v1",
        "expectedTokens": "137",
    }
    response = sale(shop, owned_id, body=request)
    assert response.status_code == 200, response.text
    fixture.update(saleRequest=request, sale=response.json())
    if os.environ.get("FOREST_EXPORT_ITEM_COMMERCE_CONTRACT") == "1":
        path = (
            Path(__file__).resolve().parents[2]
            / "frontend/MovementForest/Resources/Fixtures/item-commerce-contract.json"
        )
        path.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")


def test_upgrade_preserves_existing_bench_and_adopts_gift_value(database_factory):
    from alembic import command
    from conftest import TEST_SECRET, migration_config, migration_url
    from sqlalchemy import create_engine, text

    from forest_api.auth import issue_development_token
    from forest_api.config import Settings

    with database_factory() as url, migration_url(url):
        configuration = migration_config()
        command.upgrade(configuration, "head")
        settings = Settings(
            _env_file=None,
            environment="test",
            database_url=url,
            auth_mode="development",
            dev_auth_secret=TEST_SECRET,
        )
        from forest_api.seed import seed_development_catalogue

        app = create_app(settings)
        with app.state.database.sessions() as session:
            seed_development_catalogue(session, settings)
        h = {
            "Authorization": "Bearer " + issue_development_token(settings, "upgrade_item"),
            "X-Forest-Items": "1",
            "X-Forest-Item-Commerce": "1",
        }
        with TestClient(app) as client:
            response = client.post(
                "/v1/accounts",
                headers=h,
                json={
                    "requestId": str(uuid4()),
                    "username": "upgrade_item",
                    "displayName": "Upgrade item",
                    "gameTimezone": "Asia/Singapore",
                },
            )
            assert response.status_code == 200, response.text
            with app.state.database.sessions() as session:
                owned_id = items.grant_bench(session, "upgrade_item", apply=True)["ownedItemIds"][0]
            response = client.post(
                "/v1/me/garden/edits",
                headers=h,
                json={
                    "requestId": str(uuid4()),
                    "expectedLayoutVersion": 0,
                    "catalogVersion": "development-oak-v1",
                    "actions": [],
                    "itemActions": [
                        {
                            "action": "place",
                            "itemId": owned_id,
                            "x": 2,
                            "y": 2,
                            "rotationDegrees": 45,
                        }
                    ],
                },
            )
            assert response.status_code == 200, response.text
        command.downgrade(configuration, "0018_garden_items")
        engine = create_engine(url)
        tables = (
            "users",
            "gardens",
            "owned_plants",
            "item_definitions",
            "item_identities",
            "owned_items",
            "item_placements",
        )
        with engine.connect() as connection:
            before = {
                name: connection.execute(text(f"SELECT to_jsonb(t) FROM {name} t")).all()
                for name in tables
            }
        command.upgrade(configuration, "head")
        command.check(configuration)
        with engine.connect() as connection:
            after = {
                name: connection.execute(text(f"SELECT to_jsonb(t) FROM {name} t")).all()
                for name in tables
            }
            assert before == after
        engine.dispose()
        app = create_app(settings)
        with TestClient(app) as client:
            assert client.get("/v1/me/collection", headers=h).json()["itemOffers"] == []
            with app.state.database.sessions() as session:
                item_commerce.publish(session, apply=True)
            quote = client.get(f"/v1/me/items/{owned_id}/sale-quote", headers=h)
            assert quote.status_code == 200 and quote.json()["tokens"] == "137"
            assert (
                client.get("/v1/me/garden", headers=h).json()["items"][0]["placement"][
                    "rotationDegrees"
                ]
                == 45
            )
