"""Lazy serverless visitor accounting. No per-garden timers or process-local state.

The account and garden locks serialize every path, including existing edits/syncs.
All timestamps within one operation use its single post-lock clock boundary.
"""

import math
import secrets
from datetime import UTC, datetime, timedelta
from fractions import Fraction
from uuid import uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from forest_api import services
from forest_api.calculations import (
    MAX_INTEGER,
    MICRO,
    read_remainder,
    remainder_state,
    visitor_parameters,
)
from forest_api.errors import ApiError
from forest_api.models import GameCatalogue, Garden, GardenPlacement, OwnedPlant
from forest_api.visitor_models import (
    VisitorContext,
    VisitorOpportunity,
    VisitorRewardEvent,
    VisitorRules,
    VisitorSession,
    VisitorSettlement,
    VisitorState,
    VisitorStorageLot,
    VisitorThrottle,
    VisitorWallet,
    VisitorWalletEntry,
)
from forest_api.visitor_schemas import (
    VisitorOpportunityDTO,
    VisitorRewardResult,
    VisitorRuleDefinition,
    VisitorSessionDTO,
    VisitorSummary,
)

SLOT_SECONDS = 30
EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def slot_at(instant: datetime) -> int:
    return (instant - EPOCH) // timedelta(seconds=SLOT_SECONDS)


def fraction_json(value: Fraction) -> dict:
    return {"numerator": str(value.numerator), "denominator": str(value.denominator)}


def fraction_read(value: dict) -> Fraction:
    return Fraction(int(value["numerator"]), int(value["denominator"]))


def rule_at(session, settings, boundary):
    rule = session.scalar(
        select(VisitorRules)
        .where(VisitorRules.effective_at <= boundary)
        .order_by(VisitorRules.effective_at.desc())
        .limit(1)
    )
    if rule is None or rule.is_fixture and settings.environment not in {"local", "test"}:
        raise ApiError(503, "visitor_rules_unavailable", "Visitor rules are not available")
    try:
        definition = VisitorRuleDefinition.model_validate(rule.rules)
    except ValueError as exc:
        raise ApiError(503, "invalid_visitor_rules", "Visitor rules require maintenance") from exc
    if definition.curve.slot_seconds != SLOT_SECONDS:
        raise ApiError(503, "invalid_visitor_rules", "Visitor slot grid requires maintenance")
    return rule, definition


def create_context(session, settings, garden, boundary):
    rule, definition = rule_at(session, settings, boundary)
    presenter = services.PlantPresenter(session)
    rows = session.execute(
        select(OwnedPlant, GardenPlacement)
        .join(GardenPlacement, GardenPlacement.plant_id == OwnedPlant.id)
        .where(GardenPlacement.garden_id == garden.id)
        .order_by(OwnedPlant.id)
    )
    sources = []
    for plant, placement in rows:
        dto = presenter.plant(plant, placement)
        sources.append(
            {
                "plantId": str(plant.id),
                "stage": dto.growth_stage,
                "attractionMicroUnits": dto.base_attraction_micro_units,
                "profile": dto.pinned_profiles.attraction.model_dump(mode="json", by_alias=True),
            }
        )
    skills = services.skill_snapshot(session, garden, presenter=presenter, boundary=boundary)
    attraction = skills.attraction()
    parameters = visitor_parameters(attraction, len(sources), definition.curve)
    parameters["capacity"] = skills.capacity(
        definition.curve.base_capacity, definition.curve.maximum_capacity
    )
    context = VisitorContext(
        id=uuid4(),
        garden_id=garden.id,
        effective_at=boundary,
        rule_version=rule.version,
        snapshot={
            "sources": sources,
            "attraction": str(attraction),
            "probability": fraction_json(parameters["active_probability"]),
            "offlineRate": fraction_json(parameters["offline_rate"]),
            "capacity": parameters["capacity"],
            "rules": definition.model_dump(mode="json"),
            "skills": skills.summary(),
        },
    )
    session.add(context)
    session.flush()
    return context


def state_for(session, settings, garden, boundary):
    state = session.get(VisitorState, garden.id)
    if state is None:
        # First B6 interaction is the explicit activation boundary. No historical grant.
        context = create_context(session, settings, garden, boundary)
        state = VisitorState(
            garden_id=garden.id,
            settled_at=boundary,
            context_id=context.id,
            stored_whole=0,
            remainder={},
            last_slot=slot_at(boundary),
            gap_slots=0,
            version=0,
        )
        session.add(state)
        if session.get(VisitorWallet, garden.owner_id) is None:
            session.add(
                VisitorWallet(owner_id=garden.owner_id, tokens=0, hosted_active=0, hosted_offline=0)
            )
        session.flush()
    return state


def active_session(session, garden):
    return session.scalar(
        select(VisitorSession).where(
            VisitorSession.garden_id == garden.id, VisitorSession.ended_at.is_(None)
        )
    )


def expire_opportunities(session, garden, boundary, *, close=False):
    for opportunity in session.scalars(
        select(VisitorOpportunity).where(
            VisitorOpportunity.garden_id == garden.id, VisitorOpportunity.status == "issued"
        )
    ):
        if close or opportunity.expires_at <= boundary:
            opportunity.status = "expired"


def checked(value):
    if not 0 <= value <= MAX_INTEGER:
        raise ApiError(503, "visitor_amount_exhausted", "Visitor accounting requires maintenance")
    return value


def inactive_interval(session, state, context, start, end):
    rate = fraction_read(context.snapshot["offlineRate"])
    duration = Fraction((end - start) // timedelta(microseconds=1), 1_000_000)
    generated = duration * rate
    before = Fraction(state.stored_whole) + read_remainder(state.remainder)
    capacity = context.snapshot["capacity"]
    # Earned amounts above a reduced cap survive; production pauses.
    after = before if before >= capacity else min(Fraction(capacity), before + generated)
    new_whole = after.numerator // after.denominator
    added = new_whole - state.stored_whole
    if added:
        lot = session.get(VisitorStorageLot, (state.garden_id, context.rule_version))
        if lot is None:
            lot = VisitorStorageLot(
                garden_id=state.garden_id,
                rule_version=context.rule_version,
                visits=0,
                tokens_per_visit=context.snapshot["rules"]["tokens_per_visit"],
            )
            session.add(lot)
        lot.visits = checked(lot.visits + added)
    state.stored_whole = checked(new_whole)
    state.remainder = remainder_state(after - new_whole)
    return {
        "before": fraction_json(before),
        "after": fraction_json(after),
        "generated": fraction_json(generated),
        "discarded": fraction_json(generated - (after - before)),
    }


def active_interval(session, state, context, active, start, end, boundary, can_issue, draw):
    first = max(state.last_slot + 1, slot_at(start) + 1)
    last = slot_at(end)
    # A slot exactly at a closing lease/context boundary belongs to the NEXT interval.
    if EPOCH + timedelta(seconds=last * SLOT_SECONDS) == end:
        last -= 1
    # Only a current slot may be presented. Historical slots are durably missed.
    # No RNG loops for missed hours/years and no backfilled gap protection.
    eligible_slot = slot_at(boundary)
    opportunity = None
    probability = fraction_read(context.snapshot["probability"])
    if can_issue and first <= eligible_slot <= last and probability > 0:
        existing = session.scalar(
            select(VisitorOpportunity).where(
                VisitorOpportunity.garden_id == state.garden_id,
                VisitorOpportunity.status == "issued",
            )
        )
        if existing is None:
            state.gap_slots += 1
            rule = context.snapshot["rules"]
            if slot_succeeds(probability, state.gap_slots, rule["gap_slots"], draw):
                issued = EPOCH + timedelta(seconds=eligible_slot * SLOT_SECONDS)
                expires = min(
                    issued + timedelta(seconds=rule["opportunity_seconds"]), active.lease_expires_at
                )
                # Give a fair full presentation window. Late polls miss this slot.
                if expires - boundary >= timedelta(
                    seconds=rule["opportunity_seconds"] - rule["heartbeat_seconds"]
                ):
                    opportunity = VisitorOpportunity(
                        id=uuid4(),
                        garden_id=state.garden_id,
                        session_id=active.id,
                        context_id=context.id,
                        slot=eligible_slot,
                        issued_at=issued,
                        expires_at=expires,
                        rule_version=context.rule_version,
                        tokens=rule["tokens_per_visit"],
                        status="issued",
                    )
                    session.add(opportunity)
                    state.gap_slots = 0
    state.last_slot = max(state.last_slot, last)
    return {
        "firstSlot": first,
        "lastSlot": last,
        "issued": str(opportunity.id) if opportunity else None,
    }


def random_draw(probability):
    return secrets.randbelow(probability.denominator) < probability.numerator


def slot_succeeds(probability, gap_slots, maximum_gap, draw):
    return probability > 0 and (gap_slots >= maximum_gap or draw(probability))


def settle(session, settings, garden, boundary, *, can_issue=False, draw=random_draw):
    services.get_catalogue_state(session, settings, lock=True)
    state = state_for(session, settings, garden, boundary)
    boundary = max(boundary, state.settled_at).astimezone(UTC)
    expire_opportunities(session, garden, boundary)
    session.flush()
    active = active_session(session, garden)
    # Split only at actual configuration and lease boundaries, never per elapsed second.
    changes = session.scalars(
        select(VisitorRules)
        .where(VisitorRules.effective_at > state.settled_at, VisitorRules.effective_at <= boundary)
        .order_by(VisitorRules.effective_at)
    ).all()
    change_times = {row.effective_at for row in changes}
    cuts = {boundary, *change_times}
    if active and state.settled_at < active.lease_expires_at <= boundary:
        cuts.add(active.lease_expires_at)
    for end in sorted(cuts):
        start = state.settled_at
        context = session.get(VisitorContext, state.context_id)
        if end > start:
            is_active = active is not None and start < active.lease_expires_at
            detail = (
                active_interval(
                    session,
                    state,
                    context,
                    active,
                    start,
                    end,
                    boundary,
                    can_issue and end == boundary and boundary < active.lease_expires_at,
                    draw,
                )
                if is_active
                else inactive_interval(session, state, context, start, end)
            )
            session.add(
                VisitorSettlement(
                    id=uuid4(),
                    garden_id=garden.id,
                    context_id=context.id,
                    start_at=start,
                    end_at=end,
                    mode="active" if is_active else "inactive",
                    detail=detail,
                )
            )
            state.settled_at = end
            state.version = checked(state.version + 1)
        if active and end >= active.lease_expires_at:
            active.ended_at = active.lease_expires_at
            active = None
            expire_opportunities(session, garden, end, close=True)
        if end in change_times:
            state.context_id = create_context(session, settings, garden, end).id
    # The slot at exactly 'boundary' has not been covered by [start,end). It can
    # be decided here using the CURRENT context, once, only during live polling.
    active = active_session(session, garden) if active else None
    current_slot = slot_at(boundary)
    if (
        can_issue
        and active
        and boundary < active.lease_expires_at
        and state.last_slot < current_slot
    ):
        context = session.get(VisitorContext, state.context_id)
        active_interval(
            session,
            state,
            context,
            active,
            EPOCH + timedelta(seconds=(current_slot - 1) * SLOT_SECONDS),
            boundary + timedelta(microseconds=1),
            boundary,
            True,
            draw,
        )
    if not active:
        state.last_slot = max(state.last_slot, current_slot)
    session.flush()
    return state, boundary


def publish_rules(session, settings, version, definition, effective_at, *, is_fixture):
    """Forward-only publication serialised against all settlement paths."""
    if is_fixture and settings.environment not in {"local", "test"}:
        raise ValueError("Fixture visitor rules are restricted to local/test")
    if effective_at.tzinfo is None or definition.curve.slot_seconds != SLOT_SECONDS:
        raise ValueError("Use an aware effective timestamp and the stable 30-second grid")
    with session.begin():
        session.scalar(select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update())
        from forest_api.models import SkillPolicy
        from forest_api.skill_rules import SkillCaps

        policy = session.get(SkillPolicy, definition.skill_policy_version)
        if policy is None:
            raise ValueError("Visitor rules require an existing skill cap policy")
        SkillCaps.model_validate(policy.rules)
        now = session.scalar(select(func.clock_timestamp()))
        latest = session.scalar(select(func.max(VisitorState.settled_at)))
        if effective_at <= now or latest is not None and effective_at <= latest:
            raise ValueError("Visitor rule publication must be in the future")
        session.add(
            VisitorRules(
                version=version,
                effective_at=effective_at,
                is_fixture=is_fixture,
                rules=definition.model_dump(mode="json"),
            )
        )


class VisitorAccounting:
    def __init__(self, settings):
        self.settings = settings

    def before_change(self, session: Session, garden: Garden, boundary: datetime):
        settle(session, self.settings, garden, boundary)

    def after_change(self, session: Session, garden: Garden, boundary: datetime):
        state = session.get(VisitorState, garden.id)
        state.context_id = create_context(
            session, self.settings, garden, max(boundary, state.settled_at)
        ).id
        state.version = checked(state.version + 1)


def summary(session, garden, state, boundary):
    context = session.get(VisitorContext, state.context_id)
    rule = session.get(VisitorRules, context.rule_version)
    wallet = session.get(VisitorWallet, garden.owner_id)
    active = active_session(session, garden)
    stored = Fraction(state.stored_whole) + read_remainder(state.remainder)
    rate = fraction_read(context.snapshot["offlineRate"])
    capacity = context.snapshot["capacity"]
    time_full = (
        0
        if stored >= capacity
        else math.ceil((capacity - stored) / rate)
        if rate and not active
        else None
    )
    opportunities = session.scalars(
        select(VisitorOpportunity)
        .where(
            VisitorOpportunity.garden_id == garden.id,
            VisitorOpportunity.status == "issued",
            VisitorOpportunity.expires_at > boundary,
        )
        .order_by(VisitorOpportunity.slot)
    ).all()
    return VisitorSummary(
        garden_id=garden.id,
        server_time=boundary,
        version=state.version,
        context_id=context.id,
        rule_version=rule.version,
        is_fixture=rule.is_fixture,
        total_attraction_micro_units=context.snapshot["attraction"],
        sources=context.snapshot["sources"],
        stored_visits_micro_units=str(stored.numerator * MICRO // stored.denominator),
        claimable_visits=str(state.stored_whole),
        capacity=capacity,
        offline_visits_per_hour=str(float(rate * 3600)),
        seconds_until_full=time_full,
        token_balance=str(wallet.tokens),
        economy_version=wallet.economy_version,
        hosted_active=str(wallet.hosted_active),
        hosted_offline=str(wallet.hosted_offline),
        hosted_total=str(wallet.hosted_active + wallet.hosted_offline),
        heartbeat_seconds=context.snapshot["rules"]["heartbeat_seconds"],
        session=VisitorSessionDTO(
            session_id=active.id,
            installation_id=active.installation_id,
            lease_expires_at=active.lease_expires_at,
        )
        if active
        else None,
        opportunities=[
            VisitorOpportunityDTO(
                opportunity_id=o.id,
                session_id=o.session_id,
                issued_at=o.issued_at,
                expires_at=o.expires_at,
                tokens=str(o.tokens),
            )
            for o in opportunities
        ],
    )


def throttle(session, owner, boundary):
    row = session.get(VisitorThrottle, owner)
    if row is None:
        row = VisitorThrottle(owner_id=owner, window_at=boundary, requests=0)
        session.add(row)
    if boundary - row.window_at >= timedelta(minutes=1):
        row.window_at, row.requests = boundary, 0
    if row.requests >= 90:
        raise ApiError(429, "visitor_rate_limited", "Wait a minute before trying visitors again")
    row.requests += 1


def read(session, settings, identity, clock):
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        garden = services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        boundary = clock()
        throttle(session, user.id, boundary)
        state, boundary = settle(session, settings, garden, boundary)
        return summary(session, garden, state, boundary)


def mutate(session, settings, identity, body, operation, clock, *, target=None, draw=random_draw):
    payload_hash = services.request_hash(operation + (":" + str(target) if target else ""), body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, payload_hash)
        if previous is not None:
            return previous
        garden = services.lock_garden(session, user.id, write=True)
        services.get_catalogue_state(session, settings, lock=True)
        boundary = clock()
        throttle(session, user.id, boundary)
        state, boundary = settle(
            session,
            settings,
            garden,
            boundary,
            can_issue=operation == "visitor_heartbeat",
            draw=draw,
        )
        active = active_session(session, garden)
        context = session.get(VisitorContext, state.context_id)
        rules = context.snapshot["rules"]
        event_id, visits, tokens = None, 0, 0
        reward_detail = []
        if operation == "visitor_start":
            if active and active.installation_id != body.installation_id:
                raise ApiError(
                    409,
                    "visitor_session_conflict",
                    "Visitors are active on another device. Wait for its lease to expire",
                )
            if not active:
                active = VisitorSession(
                    id=uuid4(),
                    owner_id=user.id,
                    garden_id=garden.id,
                    installation_id=body.installation_id,
                    started_at=boundary,
                    lease_expires_at=boundary + timedelta(seconds=rules["lease_seconds"]),
                )
                session.add(active)
                state.last_slot = max(state.last_slot, slot_at(boundary))
            else:
                active.lease_expires_at = boundary + timedelta(seconds=rules["lease_seconds"])
        elif operation in {"visitor_heartbeat", "visitor_end"}:
            if (
                active is None
                or active.id != target
                or active.installation_id != body.installation_id
            ):
                raise ApiError(
                    409,
                    "visitor_session_inactive",
                    "This visitor session has ended. Reconnect to start again",
                )
            if operation == "visitor_end":
                active.ended_at = boundary
                expire_opportunities(session, garden, boundary, close=True)
            else:
                active.lease_expires_at = boundary + timedelta(seconds=rules["lease_seconds"])
                session.flush()
        elif operation == "visitor_welcome":
            opportunity = session.get(VisitorOpportunity, target)
            if opportunity is None or opportunity.garden_id != garden.id:
                raise ApiError(404, "visitor_not_found", "Visitor not found")
            if opportunity.status == "welcomed":
                result = VisitorRewardResult.model_validate(opportunity.result)
                # Preserve original award and snapshot, including original request UUID.
                services.record_request(session, user.id, body, operation, payload_hash, result)
                return result.model_dump(mode="json", by_alias=True)
            if (
                active is None
                or active.id != opportunity.session_id
                or opportunity.status != "issued"
                or opportunity.expires_at <= boundary
            ):
                raise ApiError(
                    409, "visitor_expired", "This visitor has departed. Wait for the next arrival"
                )
            visits, tokens = 1, opportunity.tokens
            opportunity.status = "welcomed"
            reward_detail = [
                {"ruleVersion": opportunity.rule_version, "visits": 1, "tokens": tokens}
            ]
        elif operation == "visitor_claim":
            visits = state.stored_whole
            for lot in session.scalars(
                select(VisitorStorageLot)
                .where(VisitorStorageLot.garden_id == garden.id)
                .order_by(VisitorStorageLot.rule_version)
            ):
                if lot.visits:
                    tokens = checked(tokens + lot.visits * lot.tokens_per_visit)
                    reward_detail.append(
                        {
                            "ruleVersion": lot.rule_version,
                            "visits": lot.visits,
                            "tokens": lot.visits * lot.tokens_per_visit,
                        }
                    )
                    lot.visits = 0
            state.stored_whole = 0
        else:
            raise ValueError("Unknown visitor operation")
        if visits:
            event_id = uuid4()
            wallet = session.get(VisitorWallet, user.id)
            wallet.tokens = checked(wallet.tokens + tokens)
            wallet.economy_version = checked(wallet.economy_version + 1)
            kind = "active_welcome" if operation == "visitor_welcome" else "offline_claim"
            wallet.hosted_active = checked(
                wallet.hosted_active + (visits if kind == "active_welcome" else 0)
            )
            wallet.hosted_offline = checked(
                wallet.hosted_offline + (visits if kind == "offline_claim" else 0)
            )
            session.add(
                VisitorRewardEvent(
                    id=event_id,
                    owner_id=user.id,
                    kind=kind,
                    source_id=target if target else body.request_id,
                    created_at=boundary,
                    detail={
                        "visits": str(visits),
                        "tokens": str(tokens),
                        "lots": reward_detail,
                        "remainingFraction": state.remainder,
                    },
                )
            )
            session.flush()
            session.add(
                VisitorWalletEntry(
                    id=uuid4(),
                    owner_id=user.id,
                    event_id=event_id,
                    amount=tokens,
                    created_at=boundary,
                )
            )
        state.version = checked(state.version + 1)
        session.flush()
        current_summary = summary(session, garden, state, boundary)
        if operation in {"visitor_claim", "visitor_welcome"}:
            result = VisitorRewardResult(
                request_id=body.request_id,
                event_id=event_id,
                visits=str(visits),
                tokens=str(tokens),
                summary=current_summary,
            )
            if operation == "visitor_welcome":
                opportunity.result = result.model_dump(mode="json", by_alias=True)
        else:
            result = current_summary
        services.record_request(session, user.id, body, operation, payload_hash, result)
        return result.model_dump(mode="json", by_alias=True)
