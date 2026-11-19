"""Read-only garden experiments. No rewards, requests, placements or contexts are written."""

import hashlib
import json
from datetime import UTC, datetime, time, timedelta
from zoneinfo import ZoneInfo

from sqlalchemy import func, select

from forest_api import services
from forest_api.errors import ApiError
from forest_api.models import SkillPolicy, User
from forest_api.skill_rules import CAPS_VERSION, SkillCaps, SkillEffect
from forest_api.skills import ItemFacts, PlantFacts, SkillSnapshot
from forest_api.visitor_models import VisitorRules
from forest_api.visitor_schemas import VisitorRuleDefinition
from forest_api.woodland_models import DailySkillActivity


def strategy_context(session, settings, garden, *, boundary=None):
    boundary = boundary or (
        session.info["clock"]()
        if "clock" in session.info
        else session.scalar(select(func.clock_timestamp()))
    )
    owner = session.get(User, garden.owner_id)
    zone = ZoneInfo(owner.game_timezone)
    day = boundary.astimezone(zone).date()
    expiry = datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(UTC)
    rule = session.scalar(
        select(VisitorRules)
        .where(VisitorRules.effective_at <= boundary)
        .order_by(VisitorRules.effective_at.desc())
        .limit(1)
    )
    upcoming = session.scalar(
        select(VisitorRules.effective_at)
        .where(VisitorRules.effective_at > boundary)
        .order_by(VisitorRules.effective_at)
        .limit(1)
    )
    if upcoming:
        expiry = min(expiry, upcoming)
    policy = session.get(
        SkillPolicy, rule.rules.get("skill_policy_version", CAPS_VERSION) if rule else CAPS_VERSION
    )
    if policy is None:
        raise ApiError(503, "skill_policy_unavailable", "Skill rules require maintenance")
    daily = session.get(DailySkillActivity, (garden.owner_id, day))
    base, maximum, multiplier, welcome = 0, 0, 1, 0
    if rule:
        definition = VisitorRuleDefinition.model_validate(rule.rules)
        from forest_api import level_benefits

        level = (
            level_benefits.account_level(session, garden.owner_id)
            if level_benefits.active(session, boundary)
            else None
        )
        base = (
            level_benefits.base_capacity(level)
            if level is not None
            else definition.curve.base_capacity
        )
        maximum = 3 * base if level is not None else definition.curve.maximum_capacity
        multiplier, welcome = definition.capacity_flat_multiplier, definition.opportunity_seconds
    return {
        "schemaVersion": 1,
        "policyVersion": policy.version,
        "caps": SkillCaps.model_validate(policy.rules).model_dump(by_alias=True),
        "dailyFlights": daily.flights if daily else 0,
        "baseCapacity": base,
        "maximumCapacity": maximum,
        "capacityFlatMultiplier": multiplier,
        "welcomeSeconds": welcome,
        "gameDate": day.isoformat(),
        "validUntil": expiry.isoformat(),
        "ruleVersion": rule.version if rule else None,
    }


def evaluate_proposal(session, settings, garden, catalogue, proposal, boundary):
    context = strategy_context(session, settings, garden, boundary=boundary)
    presenter = services.PlantPresenter(session)
    presenter.preload(list(proposal.plants.values()))
    plants, items, source_state = [], [], []
    for identifier in sorted(proposal.final):
        plant = proposal.plants[identifier]
        dto = presenter.plant(plant, None)
        plants.append(
            PlantFacts(
                str(identifier),
                plant.species_id,
                plant.variant_id,
                dto.growth_stage,
                tuple(dto.gameplay_tags or ()),
                int(dto.base_attraction_micro_units),
                plant.behaviour_profile_id,
                plant.behaviour_profile_version,
                presenter.behaviour(plant),
            )
        )
        source_state.append((str(identifier), dto.growth_micro_units))
    from forest_api.item_skills import rules_for_definition

    for identifier in sorted(proposal.final_items):
        _, identity, definition, _ = proposal.owned_items[identifier]
        rules = rules_for_definition(session, definition)
        items.append(
            ItemFacts(
                str(identifier),
                identity.item_id,
                identity.item_version,
                rules["profileId"],
                rules["profileVersion"],
                tuple(SkillEffect.model_validate(e) for e in rules["effects"]),
                rules["dailyGrant"],
                tuple(rules.get("triggeredGrants", [])),
            )
        )
    snapshot = SkillSnapshot(
        tuple(plants),
        SkillCaps.model_validate(context["caps"]),
        context["policyVersion"],
        flights=context["dailyFlights"],
        items=tuple(items),
    )
    result = {
        "totalAttractionMicroUnits": str(snapshot.attraction()),
        "skillSummary": snapshot.summary(),
        "offlineCapacity": snapshot.capacity(
            context["baseCapacity"],
            context["maximumCapacity"],
            flat_multiplier=context["capacityFlatMultiplier"],
        ),
        "context": context,
    }
    proof = {
        "result": result,
        "growth": source_state,
        "catalog": catalogue.version,
        "layout": garden.layout_version,
        "plants": [
            (str(k), str(v.x), str(v.y), str(v.rotation_degrees))
            for k, v in sorted(proposal.final.items())
        ],
        "items": [
            (str(k), str(v.x), str(v.y), str(v.rotation_degrees))
            for k, v in sorted(proposal.final_items.items())
        ],
    }
    result["fingerprint"] = hashlib.sha256(json.dumps(proof, sort_keys=True).encode()).hexdigest()
    return result


def preview_garden(session, settings, identity, body, clock):
    from forest_api.placement import propose_layout

    with session.begin():
        user = services.get_user(session, identity, lock=True)
        garden = services.lock_garden(session, user.id)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        proposal = propose_layout(session, settings, user, garden, catalogue, body)
        return evaluate_proposal(session, settings, garden, catalogue, proposal, clock())
