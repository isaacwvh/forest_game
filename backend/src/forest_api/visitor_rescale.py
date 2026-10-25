"""Atomic, explicit ×10 currency/storage conversion and scheduled-visitor publication."""

from copy import deepcopy
from fractions import Fraction
from uuid import NAMESPACE_URL, uuid4, uuid5

from sqlalchemy import func, select, text

from forest_api import collection, visitors
from forest_api.calculations import CalculationRules, read_remainder, remainder_state
from forest_api.collection_models import PackDefinition
from forest_api.collection_schemas import PublishPack, parse_pack
from forest_api.launch_balance import CURVE as OLD_CURVE
from forest_api.launch_balance import RESCALE_VERSION as VERSION
from forest_api.launch_balance import VERSION as PREVIOUS
from forest_api.models import EconomyConfig, GameCatalogue, Garden, SkillPolicy, User
from forest_api.visitor_models import (
    VisitorContext,
    VisitorEconomyConversion,
    VisitorRewardEvent,
    VisitorRules,
    VisitorState,
    VisitorStorageLot,
    VisitorWalletEntry,
)
from forest_api.visitor_schemas import VisitorRuleDefinition

POLICY = "b8-caps-v3"
PACK_VERSION = 11
SCALE = 10
CURVE = {
    **OLD_CURVE,
    "arrival_rate_multiplier": "10",
    "base_capacity": 1500,
    "maximum_capacity": 4500,
    "offline_rate_cap_per_second": "0.1",
}


def convert_owner(session, owner, garden, state, boundary, fraction_context=None):
    wallet = collection.wallet_for(session, owner)
    before_tokens = wallet.tokens
    after_tokens = visitors.checked(before_tokens * SCALE)
    stored = Fraction(state.stored_whole) + read_remainder(state.remainder)
    after_stored = stored * SCALE
    lots = session.scalars(
        select(VisitorStorageLot).where(VisitorStorageLot.garden_id == garden.id)
    ).all()
    if sum(lot.visits for lot in lots) != state.stored_whole:
        raise ValueError("Stored visitor lots must reconcile before conversion")
    for lot in lots:
        lot.visits = visitors.checked(lot.visits * SCALE)
    whole = after_stored.numerator // after_stored.denominator
    carry = whole - state.stored_whole * SCALE
    if carry:
        context = fraction_context or session.get(VisitorContext, state.context_id)
        lot = next((lot for lot in lots if lot.rule_version == context.rule_version), None)
        if lot is None:
            lot = VisitorStorageLot(
                garden_id=garden.id,
                rule_version=context.rule_version,
                tokens_per_visit=context.snapshot["rules"]["tokens_per_visit"],
                visits=0,
            )
            session.add(lot)
        lot.visits = visitors.checked(lot.visits + carry)
    state.stored_whole = visitors.checked(whole)
    state.remainder = remainder_state(after_stored - whole)
    detail = {
        "scale": SCALE,
        "tokensBefore": str(before_tokens),
        "tokensAfter": str(after_tokens),
        "storedBefore": str(stored),
        "storedAfter": str(after_stored),
    }
    session.add(
        VisitorEconomyConversion(
            owner_id=owner, version=VERSION, converted_at=boundary, detail=detail
        )
    )
    if after_tokens > before_tokens:
        event = VisitorRewardEvent(
            id=uuid4(),
            owner_id=owner,
            kind="economy_conversion",
            source_id=uuid5(NAMESPACE_URL, VERSION),
            created_at=boundary,
            detail=detail,
        )
        session.add(event)
        session.flush()
        session.add(
            VisitorWalletEntry(
                id=uuid4(),
                owner_id=owner,
                event_id=event.id,
                amount=after_tokens - before_tokens,
                created_at=boundary,
            )
        )
    wallet.tokens = after_tokens
    wallet.economy_version = visitors.checked(wallet.economy_version + 1)
    active = visitors.active_session(session, garden)
    if active:
        active.ended_at = boundary
    visitors.expire_opportunities(session, garden, boundary, close=True)
    state.version = visitors.checked(state.version + 1)


def publish(session, settings, *, clock=None):
    with session.begin():
        session.execute(text("SELECT pg_advisory_xact_lock(hashtextextended('forest-balance',0))"))
        if session.get(VisitorRules, VERSION) is not None:
            return {"version": VERSION, "alreadyPublished": True}
        # Match live mutation lock order. Concurrent registration is detected below.
        owners = list(session.scalars(select(User.id).order_by(User.id).with_for_update()))
        gardens = list(session.scalars(select(Garden).order_by(Garden.owner_id).with_for_update()))
        catalogue = session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update()
        )
        if catalogue is None or catalogue.version != PREVIOUS:
            raise ValueError("Publish launch-balance-v1 before the visitor rescale")
        if list(session.scalars(select(User.id).order_by(User.id))) != owners:
            raise ValueError("Accounts changed during publication; retry the atomic publication")
        boundary = clock() if clock else session.scalar(select(func.clock_timestamp()))
        latest = [
            session.scalar(select(func.max(column)))
            for column in (
                VisitorState.settled_at,
                VisitorRules.effective_at,
                EconomyConfig.effective_at,
            )
        ]
        if any(value is not None and value >= boundary for value in latest):
            raise ValueError("Wait until existing accounting and configuration times have passed")
        old_policy = session.get(SkillPolicy, "b8-caps-v2")
        caps = {**deepcopy(old_policy.rules), "flatCapacity": 100}
        session.add(SkillPolicy(version=POLICY, rules=caps))
        old_economy = session.get(EconomyConfig, PREVIOUS)
        rules = CalculationRules.model_validate({**old_economy.rules, "visitors": CURVE})
        visitor = VisitorRuleDefinition(
            curve=CURVE,
            skill_policy_version=POLICY,
            arrival_protocol=2,
            capacity_flat_multiplier=10,
            gap_slots=10,
            tutorial_first_visitor=True,
        )
        session.add(
            EconomyConfig(
                version=VERSION,
                effective_at=boundary,
                is_fixture=False,
                rules=rules.model_dump(mode="json"),
            )
        )
        session.add(
            VisitorRules(
                version=VERSION,
                effective_at=boundary,
                is_fixture=False,
                rules=visitor.model_dump(mode="json"),
            )
        )
        catalogue.version = VERSION
        session.flush()
        # Insert forward rules before settling to their boundary. The settlement
        # engine accounts [old_time, boundary) under the frozen old context and
        # switches context at boundary, without earning new-rate history.
        for garden in gardens:
            previous_state = session.get(VisitorState, garden.id)
            fraction_context = (
                session.get(VisitorContext, previous_state.context_id) if previous_state else None
            )
            state, _ = visitors.settle(session, settings, garden, boundary)
            convert_owner(session, garden.owner_id, garden, state, boundary, fraction_context)
        for pack_id, cost in (("woodland", 1200), ("moonwillow", 2400)):
            old = session.get(PackDefinition, (pack_id, 10))
            collection.publish_in_transaction(
                session,
                settings,
                PublishPack(
                    pack_id=pack_id,
                    version=PACK_VERSION,
                    is_fixture=False,
                    offer_id=pack_id,
                    offer_version=PACK_VERSION,
                    token_cost=cost,
                    definition=parse_pack(old.definition),
                ),
            )
        session.flush()
        return {
            "version": VERSION,
            "effectiveAt": boundary.isoformat(),
            "convertedAccounts": len(owners),
            "scale": SCALE,
            "woodlandTokens": 1200,
            "moonwillowTokens": 2400,
        }
