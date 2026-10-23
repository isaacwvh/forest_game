import copy
import json
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from pydantic import ValidationError
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import IntegrityError

from forest_api import collection
from forest_api.auth import DEV_ISSUER, Identity
from forest_api.collection_models import (
    CollectionEvent,
    OwnedPack,
    PackDefinition,
    PackOpening,
)
from forest_api.collection_schemas import (
    ExchangeRequest,
    OpenPackRequest,
    PackContract,
    PublishPack,
)
from forest_api.collection_seed import seed_collection
from forest_api.errors import ApiError
from forest_api.models import ApiRequest, GrowthProfile, OwnedPlant, Variant
from forest_api.visitor_models import VisitorWallet, VisitorWalletEntry


@pytest.fixture
def economy(app, client, register, headers):
    account = register()
    owner = UUID(account["profile"]["userId"])
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
    # Synthetic initial funds are deliberately local to tests, never a runtime API.
    with app.state.database.sessions.begin() as session:
        session.add(VisitorWallet(owner_id=owner, tokens=100, hosted_active=0, hosted_offline=0))
    return {"owner": owner, "headers": headers(), "client": client, "app": app}


def exchange(economy, **changes):
    return economy["client"].post(
        "/v1/me/exchanges",
        headers=economy["headers"],
        json={
            "requestId": str(uuid4()),
            "offerId": "woodland",
            "offerVersion": 1,
            "quantity": 1,
            **changes,
        },
    )


def open_pack(economy, pack, request=None):
    return economy["client"].post(
        f"/v1/me/packs/{pack}/open",
        headers=economy["headers"],
        json={"requestId": str(request or uuid4())},
    )


def contract(app):
    with app.state.database.sessions() as session:
        return copy.deepcopy(session.get(PackDefinition, ("woodland", 1)).definition)


def test_exchange_and_open_full_loop(economy):
    response = exchange(economy, quantity=2)
    assert response.status_code == 200, response.text
    value = response.json()
    assert value["tokensSpent"] == "10" and value["tokenBalance"] == "90"
    assert len(value["packs"]) == 2
    pack = value["packs"][0]["ownedPackId"]
    opening = open_pack(economy, pack)
    assert opening.status_code == 200, opening.text
    result = opening.json()
    assert result["tokenBalance"] == "90" and result["economyVersion"] == 2
    plant = result["plant"]
    assert plant["growthMicroUnits"] == "0" and plant["growthStage"] == "sprout"
    assert plant["placement"] is None and plant["pinnedProfiles"]["growth"]["version"] == 1
    inventory = economy["client"].get("/v1/me/inventory", headers=economy["headers"]).json()
    assert plant["plantId"] in [p["plantId"] for p in inventory["plants"]]
    packs = economy["client"].get("/v1/me/packs", headers=economy["headers"]).json()
    assert len(packs["packs"]) == 1
    history = economy["client"].get("/v1/me/pack-openings", headers=economy["headers"]).json()
    assert history["openings"] == [result]


@pytest.mark.parametrize("quantity", [0, -1, 21, 1.5, "2", True, None])
def test_quantity_is_strict_positive_bounded_integer(economy, quantity):
    assert exchange(economy, quantity=quantity).status_code == 422
    assert (
        economy["client"]
        .get("/v1/me/collection", headers=economy["headers"])
        .json()["tokenBalance"]
        == "100"
    )


def test_insufficient_funds_is_atomic(economy):
    with economy["app"].state.database.sessions.begin() as session:
        session.get(VisitorWallet, economy["owner"]).tokens = 4
    assert exchange(economy).json()["error"]["code"] == "insufficient_tokens"
    with economy["app"].state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(CollectionEvent)) == 0
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 0
        assert session.get(VisitorWallet, economy["owner"]).tokens == 4


def test_exchange_replay_and_conflict_survive_request_cache_cleanup(economy):
    request = str(uuid4())
    result = exchange(economy, requestId=request).json()
    assert exchange(economy, requestId=request).json() == result
    with economy["app"].state.database.sessions.begin() as session:
        session.execute(delete(ApiRequest).where(ApiRequest.request_id == UUID(request)))
    assert exchange(economy, requestId=request).json() == result
    assert (
        exchange(economy, requestId=request, quantity=2).json()["error"]["code"]
        == "idempotency_conflict"
    )


def test_open_replays_same_plant_with_new_uuid_and_after_restart(economy):
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]
    request = uuid4()
    result = open_pack(economy, pack, request).json()
    assert open_pack(economy, pack, request).json() == result
    assert open_pack(economy, pack).json() == result
    with economy["app"].state.database.sessions.begin() as session:
        session.execute(delete(ApiRequest).where(ApiRequest.request_id == request))
    assert open_pack(economy, pack, request).json() == result
    with economy["app"].state.database.sessions() as session:
        assert session.scalar(select(func.count()).select_from(PackOpening)) == 1
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 2


def test_request_uuid_cannot_change_operation_or_pack(economy):
    request = str(uuid4())
    packs = exchange(economy, requestId=request, quantity=2).json()["packs"]
    assert (
        open_pack(economy, packs[0]["ownedPackId"], request).json()["error"]["code"]
        == "idempotency_conflict"
    )
    opening_request = uuid4()
    assert open_pack(economy, packs[0]["ownedPackId"], opening_request).status_code == 200
    assert open_pack(economy, packs[1]["ownedPackId"], opening_request).status_code == 409


def test_foreign_pack_is_indistinguishable_from_missing(economy, register, headers):
    register("bob")
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]

    def request(target):
        return economy["client"].post(
            f"/v1/me/packs/{target}/open", headers=headers("bob"), json={"requestId": str(uuid4())}
        )

    assert request(pack).status_code == 404
    assert request(pack).json() == request(uuid4()).json()
    assert economy["client"].get("/v1/me/packs", headers=headers("bob")).json()["packs"] == []
    assert (
        economy["client"].get("/v1/me/pack-openings", headers=headers("bob")).json()["openings"]
        == []
    )


def test_old_pack_retains_contents_profiles_and_price_after_publication(economy):
    app = economy["app"]
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]
    new = contract(app)
    new["rarities"] = [new["rarities"][1]]
    with app.state.database.sessions() as session:
        collection.publish(
            session,
            app.state.settings,
            PublishPack(
                pack_id="woodland",
                version=2,
                is_fixture=True,
                definition=PackContract.model_validate(new),
                offer_id="woodland",
                offer_version=2,
                token_cost=9,
            ),
        )
    assert exchange(economy).json()["error"]["code"] == "stale_offer"
    newer = exchange(economy, offerVersion=2).json()
    assert newer["tokensSpent"] == "9" and newer["packs"][0]["version"] == 2
    old = open_pack(economy, pack).json()
    assert old["packVersion"] == 1
    with app.state.database.sessions.begin() as session:
        session.get(Variant, ("oak", "blue")).enabled = False
    # Retiring from new acquisition does not destroy an already acquired contract.
    assert (
        open_pack(economy, newer["packs"][0]["ownedPackId"]).json()["plant"]["variantId"] == "blue"
    )


def test_profile_changes_do_not_reprice_old_pack_awards(economy):
    pack = exchange(economy, offerId="blue_oak").json()["packs"][0]["ownedPackId"]
    with economy["app"].state.database.sessions.begin() as session:
        session.add(
            GrowthProfile(
                id="new_growth",
                version=1,
                thresholds={"sprout": 0, "seedling": 10, "young": 20, "adult": 30},
                maximum_growth_micro_units=30,
            )
        )
        session.flush()
        session.get(Variant, ("oak", "blue")).growth_profile_id = "new_growth"
        session.get(Variant, ("oak", "blue")).growth_profile_version = 1
    result = open_pack(economy, pack).json()
    assert result["plant"]["pinnedProfiles"]["growth"]["id"] == "dev_oak_growth"


@pytest.mark.parametrize(
    "roll,rarity",
    [
        (0, "common"),
        (74, "common"),
        (75, "legendary"),
        (79, "legendary"),
        (80, "rare"),
        (99, "rare"),
    ],
)
def test_exact_rarity_boundaries(economy, roll, rarity):
    definition = PackContract.model_validate(contract(economy["app"]))
    values = iter([roll, 0])
    assert collection.choose(definition, lambda n: next(values))[0] == rarity


def test_pool_edits_and_order_do_not_change_rarity_probability(economy):
    definition = contract(economy["app"])
    changed = copy.deepcopy(definition)
    common = changed["rarities"][0]
    extra = copy.deepcopy(common["outcomes"][0])
    extra["speciesId"] = "synthetic"
    common["outcomes"].append(extra)
    changed["rarities"].reverse()
    original = PackContract.model_validate(definition)
    revised = PackContract.model_validate(changed)
    for roll in range(100):
        assert (
            collection.choose(original, lambda n, value=roll: value if n == 100 else 0)[0]
            == collection.choose(revised, lambda n, value=roll: value if n == 100 else 0)[0]
        )
    values = iter([0, 1])
    assert collection.choose(revised, lambda n: next(values))[1].species_id == "synthetic"


@pytest.mark.parametrize(
    "change", ["empty", "negative", "float", "duplicate", "zero", "duplicate_rarity"]
)
def test_invalid_pool_configuration_rejected(economy, change):
    value = contract(economy["app"])
    if change == "empty":
        value["rarities"][0]["outcomes"] = []
    elif change == "negative":
        value["rarities"][0]["weight"] = -1
    elif change == "float":
        value["rarities"][0]["weight"] = 1.5
    elif change == "duplicate":
        value["rarities"][0]["outcomes"] *= 2
    elif change == "zero":
        for pool in value["rarities"]:
            pool["weight"] = 0
    else:
        value["rarities"].append(value["rarities"][0])
    with pytest.raises(ValidationError):
        PackContract.model_validate(value)


@pytest.mark.parametrize("change", ["species", "profile", "rarity"])
def test_publication_validates_references(economy, change):
    app = economy["app"]
    value = contract(app)
    if change == "species":
        value["rarities"][0]["outcomes"][0]["speciesId"] = "unknown"
    elif change == "profile":
        value["rarities"][0]["outcomes"][0]["profiles"]["growth"]["version"] = 999
    else:
        value["rarities"][0]["rarity"] = "wrong"
    with app.state.database.sessions() as session, pytest.raises(ApiError):
        collection.publish(
            session,
            app.state.settings,
            PublishPack(
                pack_id="invalid",
                version=1,
                is_fixture=True,
                definition=PackContract.model_validate(value),
                offer_id="invalid",
                offer_version=1,
                token_cost=1,
            ),
        )


def test_concurrent_exchanges_cannot_overspend(economy):
    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        session.get(VisitorWallet, economy["owner"]).tokens = 5

    def buy(_):
        with app.state.database.sessions() as session:
            try:
                collection.mutate(
                    session,
                    app.state.settings,
                    Identity(DEV_ISSUER, "alice"),
                    ExchangeRequest(request_id=uuid4(), offer_id="woodland", offer_version=1),
                    lambda: datetime.now(UTC),
                )
                return 200
            except ApiError as error:
                return error.status

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(buy, range(2))) == [200, 409]
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, economy["owner"]).tokens == 0
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == 1


def test_concurrent_openings_with_distinct_requests_award_once(economy):
    app = economy["app"]
    pack = exchange(economy).json()["packs"][0]["ownedPackId"]

    def opening(_):
        with app.state.database.sessions() as session:
            return collection.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                OpenPackRequest(request_id=uuid4()),
                lambda: datetime.now(UTC),
                pack_id=UUID(pack),
            )

    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(opening, range(2)))
    assert results[0] == results[1]


@pytest.mark.parametrize("operation", ["exchange", "open"])
def test_commit_failure_rolls_back_all_effects(economy, monkeypatch, operation):
    app = economy["app"]
    pack = exchange(economy).json()["packs"][0]["ownedPackId"] if operation == "open" else None
    from sqlalchemy.orm import Session

    original = Session.flush

    def broken(session, *args, **kwargs):
        result = original(session, *args, **kwargs)
        if any(
            isinstance(row, CollectionEvent) for row in session.identity_map.values()
        ) or session.info.get("failed"):
            raise RuntimeError("Injected failure")
        # The final flush persists the durable receipt, making it a meaningful rollback boundary.
        if session.scalar(select(func.count()).select_from(CollectionEvent)) > (1 if pack else 0):
            raise RuntimeError("Injected failure")
        return result

    body = (
        OpenPackRequest(request_id=uuid4())
        if pack
        else ExchangeRequest(request_id=uuid4(), offer_id="woodland", offer_version=1)
    )
    with monkeypatch.context() as patch:
        patch.setattr(Session, "flush", broken)
        with app.state.database.sessions() as session, pytest.raises(RuntimeError):
            collection.mutate(
                session,
                app.state.settings,
                Identity(DEV_ISSUER, "alice"),
                body,
                lambda: datetime.now(UTC),
                pack_id=UUID(pack) if pack else None,
            )
    with app.state.database.sessions() as session:
        assert session.get(VisitorWallet, economy["owner"]).tokens == (95 if pack else 100)
        assert session.scalar(select(func.count()).select_from(PackOpening)) == 0
        assert session.scalar(select(func.count()).select_from(OwnedPlant)) == 1
        assert session.scalar(select(func.count()).select_from(OwnedPack)) == (1 if pack else 0)


@pytest.mark.parametrize(
    "statement",
    [
        "UPDATE pack_definitions SET definition = '{}'::jsonb",
        "UPDATE exchange_offers SET token_cost = token_cost + 1",
        "UPDATE owned_packs SET pack_version = 2",
        "UPDATE collection_events SET token_delta = 0",
        "DELETE FROM plant_stages WHERE species_id = 'oak'",
    ],
)
def test_history_and_stage_assets_protected(economy, statement):
    exchange(economy)
    with economy["app"].state.database.sessions.begin() as session, pytest.raises(IntegrityError):
        session.execute(text(statement))


def test_unpublished_stage_assets_remain_editable(app):
    from forest_api.models import PlantStage

    key = ("oak", "standard", "sprout")
    with app.state.database.sessions.begin() as session:
        session.get(PlantStage, key).thumbnail_key = "replacement.png"
    with app.state.database.sessions() as session:
        assert session.get(PlantStage, key).thumbnail_key == "replacement.png"


def test_publication_rejects_unsafe_stage_assets(app):
    from forest_api.models import PlantStage, Species
    from forest_api.services import profile_refs

    with app.state.database.sessions.begin() as session:
        profiles = profile_refs(session.get(Species, "oak")).model_dump(mode="json", by_alias=True)
        session.get(
            PlantStage, ("oak", "standard", "sprout")
        ).thumbnail_key = "assets/oak/v1/../bad.png"
    definition = PackContract.model_validate(
        {
            "displayName": "Unsafe",
            "description": "fixture",
            "rarities": [
                {
                    "rarity": "development_unbalanced",
                    "weight": 1,
                    "outcomes": [
                        {"speciesId": "oak", "variantId": "standard", "profiles": profiles}
                    ],
                }
            ],
        }
    )
    with pytest.raises(ApiError), app.state.database.sessions() as session:
        collection.publish(
            session,
            app.state.settings,
            PublishPack(
                pack_id="unsafe",
                version=1,
                is_fixture=True,
                definition=definition,
                offer_id="unsafe",
                offer_version=1,
                token_cost=1,
            ),
        )


def test_pagination_is_complete_and_bounded(economy):
    ids = {p["ownedPackId"] for p in exchange(economy, quantity=5).json()["packs"]}
    found, after = set(), None
    while True:
        response = economy["client"].get(
            "/v1/me/packs",
            headers=economy["headers"],
            params={"limit": 2, **({"after": after} if after else {})},
        )
        value = response.json()
        found.update(p["ownedPackId"] for p in value["packs"])
        after = value["nextCursor"]
        if not after:
            break
    assert found == ids
    assert (
        economy["client"].get("/v1/me/packs?limit=101", headers=economy["headers"]).status_code
        == 422
    )


def test_collection_before_b6_activation_does_not_duplicate_wallet(economy):
    response = economy["client"].get("/v1/me/visitors", headers=economy["headers"])
    assert response.status_code == 200, response.text
    assert response.json()["tokenBalance"] == "100"
    assert response.json()["hostedTotal"] == "0"


def test_retired_offer_preserves_owned_pack_and_replays(economy):
    request = str(uuid4())
    bought = exchange(economy, requestId=request).json()
    app = economy["app"]
    with app.state.database.sessions() as session:
        collection.retire_offer(session, app.state.settings, "woodland", 1)
    assert exchange(economy).json()["error"]["code"] == "stale_offer"
    assert exchange(economy, requestId=request).json() == bought
    assert open_pack(economy, bought["packs"][0]["ownedPackId"]).status_code == 200
    with app.state.database.sessions() as session:
        seed_collection(session, app.state.settings)
    shop = economy["client"].get("/v1/me/collection", headers=economy["headers"]).json()
    assert [offer["offerId"] for offer in shop["offers"]] == ["blue_oak"]


def test_exchange_overflow_and_client_outcome_fields_rejected(economy):
    assert exchange(economy, plantId=str(uuid4())).status_code == 422
    app = economy["app"]
    definition = PackContract.model_validate(contract(app))
    with app.state.database.sessions() as session:
        collection.publish(
            session,
            app.state.settings,
            PublishPack(
                pack_id="woodland",
                version=1,
                is_fixture=True,
                definition=definition,
                offer_id="huge",
                offer_version=1,
                token_cost=9223372036854775807,
            ),
        )
    assert (
        exchange(economy, offerId="huge", quantity=2).json()["error"]["code"] == "amount_overflow"
    )


def test_earned_tokens_reconcile_with_exchange_and_hosted_counts(economy):
    from datetime import timedelta

    from forest_api.models import Garden, GardenPlacement

    app = economy["app"]
    with app.state.database.sessions.begin() as session:
        wallet = session.get(VisitorWallet, economy["owner"])
        wallet.tokens = 0
        garden = session.scalar(select(Garden).where(Garden.owner_id == economy["owner"]))
        plant = session.scalar(select(OwnedPlant).where(OwnedPlant.owner_id == economy["owner"]))
        session.add(
            GardenPlacement(
                plant_id=plant.id,
                owner_id=plant.owner_id,
                garden_id=garden.id,
                x=2,
                y=2,
                rotation_degrees=0,
            )
        )
    boundary = datetime(2026, 10, 23, tzinfo=UTC)
    app.state.clock = lambda: boundary
    client, headers = economy["client"], economy["headers"]
    assert client.get("/v1/me/visitors", headers=headers).status_code == 200
    boundary += timedelta(hours=1)
    claimed = client.post(
        "/v1/me/stored-visits/claim", headers=headers, json={"requestId": str(uuid4())}
    ).json()
    before = claimed["summary"]
    assert int(before["tokenBalance"]) >= 5
    bought = exchange(economy).json()
    opened = open_pack(economy, bought["packs"][0]["ownedPackId"]).json()
    after = client.get("/v1/me/visitors", headers=headers).json()
    assert after["hostedTotal"] == before["hostedTotal"]
    assert after["economyVersion"] == before["economyVersion"] + 2
    assert after["tokenBalance"] == opened["tokenBalance"]
    with app.state.database.sessions() as session:
        earnings = session.scalar(select(func.sum(VisitorWalletEntry.amount)))
        spending = session.scalar(select(func.sum(CollectionEvent.token_delta)))
        assert session.get(VisitorWallet, economy["owner"]).tokens == earnings + spending


def test_open_history_is_newest_first_with_complete_pagination(economy):
    packs = exchange(economy, quantity=3).json()["packs"]
    results = [open_pack(economy, p["ownedPackId"]).json() for p in packs]
    client = economy["client"]
    page = client.get("/v1/me/pack-openings?limit=2", headers=economy["headers"]).json()
    rest = client.get(
        "/v1/me/pack-openings",
        params={"limit": 2, "after": page["nextCursor"]},
        headers=economy["headers"],
    ).json()
    assert [r["openingId"] for r in page["openings"] + rest["openings"]] == [
        r["openingId"] for r in reversed(results)
    ]


def test_export_native_contract(economy):
    """Synthetic HTTP fixtures are opt-in; ordinary tests never rewrite resources."""
    summary = economy["client"].get("/v1/me/collection", headers=economy["headers"]).json()
    bought = exchange(economy, quantity=2).json()
    opened = open_pack(economy, bought["packs"][0]["ownedPackId"]).json()
    with economy["app"].state.database.sessions() as session:
        wallet = session.get(VisitorWallet, economy["owner"])
        # Opening has no token effect; historical B6 credits remain separate.
        assert wallet.tokens == 100 + session.scalar(select(func.sum(CollectionEvent.token_delta)))
        assert session.scalar(select(func.count()).select_from(VisitorWalletEntry)) == 0
    import os

    if os.environ.get("FOREST_EXPORT_COLLECTION_CONTRACT") == "1":
        value = {
            "summary": summary,
            "exchange": bought,
            "opening": opened,
            "packs": economy["client"].get("/v1/me/packs", headers=economy["headers"]).json(),
            "catalogue": economy["client"].get("/v1/catalog", headers=economy["headers"]).json(),
        }
        path = (
            Path(__file__).resolve().parents[2]
            / "frontend/MovementForest/Resources/Fixtures/collection-contract.json"
        )
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
