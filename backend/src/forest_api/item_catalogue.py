"""Approved fifteen-item release. Publication is explicit and preview-first."""

import json
from datetime import UTC, timedelta
from decimal import Decimal
from pathlib import Path

from sqlalchemy import func, select, text

from forest_api.item_models import (
    ItemDefinition,
    ItemSkillBinding,
    ItemSkillProfile,
    ItemValueDefinition,
    ShopRelease,
    ShopWeek,
)
from forest_api.item_pricing import token_value_for_rarity
from forest_api.skill_rules import SkillEffect

VERSION = "garden-items-v1"
POLICY = {
    "algorithm": 1,
    "timezone": "UTC",
    "commons": 3,
    "rareDays": 3,
    "epicDays": 2,
    "featuredLimit": 1,
    "welcomeDurationCap": "0.25",
    "clientCapability": 1,
}
SKILLS = {
    "patient_post": ("Patient Post", "offline_capacity", "0.05", None),
    "pollinators_welcome": ("Pollinator's Welcome", "attraction_garden", "0.03", None),
    "celestial_welcome": ("Celestial Welcome", "attraction_garden", "0.045", None),
    "sporeline_surge": ("Sporeline Surge", "activity", "0.04", "workouts"),
    "borrowed_wisdom": ("Borrowed Wisdom", "water", "0.01", None),
    "second_wind": ("Second Wind", "activity", "0.05", "active_energy_kcal"),
    "gentle_hold": ("Gentle Hold", "welcome_duration", "0.20", None),
}


def catalogue():
    rows = json.loads(Path(__file__).with_name("data").joinpath("garden-items-v1.json").read_text())
    for row in rows:
        row["tokenCost"] = token_value_for_rarity(row["rarity"], row["tokenCost"])
    return rows


def profile(skill_id):
    if skill_id == "morning_rain":
        return {"effects": [], "dailyGrant": {"family": "morning_rain", "water": "2.5"}}
    name, scope, amount, metric = SKILLS[skill_id]
    magnitude = {"type": "fixed", "value": amount}
    if skill_id == "borrowed_wisdom":
        magnitude = {"type": "per_species", "value": amount, "maximum": "0.05", "selector": {}}
    effect = {
        "componentVersion": 2,
        "id": skill_id,
        "name": name,
        "description": {
            "patient_post": "+5% offline visitor storage capacity while placed.",
            "pollinators_welcome": "+3% garden attraction while placed.",
            "celestial_welcome": "+4.5% garden attraction while placed.",
            "sporeline_surge": "+4% water from supported workouts while placed.",
            "borrowed_wisdom": "+1% activity water per distinct planted species, up to +5%.",
            "second_wind": "+5% water from active energy while placed.",
            "gentle_hold": "+20% butterfly welcome time while placed.",
        }[skill_id],
        "system": "growth" if scope in {"activity", "water"} else "visitors",
        "scope": scope,
        "metric": metric,
        "target": "all_planted_plants" if scope in {"activity", "water"} else "garden",
        "magnitude": magnitude,
        "stackingGroup": "butterfly_welcome_window"
        if skill_id == "gentle_hold"
        else "item_" + skill_id,
    }
    # Workout families are compiled to canonical metrics by the frozen snapshot.
    validate = {**effect, "metric": "workout_minutes.walking"} if metric == "workouts" else effect
    SkillEffect.model_validate(validate)
    return {"effects": [effect]}


def publish(session, *, apply=False, effective_week=None, version=VERSION, clock=None):
    with session.begin():
        session.execute(text("SELECT pg_advisory_xact_lock(591417020)"))
        now = (clock() if clock else session.scalar(select(func.clock_timestamp()))).astimezone(UTC)
        existing = session.get(ShopRelease, version)
        week = effective_week or (
            existing.effective_week if existing else now.date() - timedelta(days=now.weekday())
        )
        if week.weekday() != 0:
            raise ValueError("A release must start on Monday UTC")
        rows = catalogue()
        if len({r["id"] for r in rows}) != len(rows):
            raise ValueError("Duplicate item identities")
        from forest_api.shop import generate

        validation = generate(rows, seed="publication-validation")
        if any(slot["item"] is None for day in validation["days"] for slot in day["slots"]):
            raise ValueError("Publication needs at least three Commons, one Rare and one Epic")
        if existing:
            if (
                existing.catalogue != rows
                or existing.policy != POLICY
                or existing.effective_week != week
            ):
                raise ValueError("Release versions are immutable")
        else:
            if week < now.date() - timedelta(days=now.weekday()):
                raise ValueError("New catalogue releases cannot be backdated")
            if session.scalar(select(ShopWeek).where(ShopWeek.week_start >= week).limit(1)):
                raise ValueError("Choose a future ungenerated week for a new release")
            for row in rows:
                prefix = f"assets/items/{row['id']}/v1/"
                values = dict(
                    display_name=row["displayName"],
                    description=row["description"],
                    rarity=row["rarity"],
                    asset_version=row["assetVersion"],
                    model_key=prefix + f"models/{row['id']}-standard.usdz",
                    thumbnail_key=prefix + f"ui/{row['id']}-standard.png",
                    clearance_radius=Decimal(row["radius"]),
                )
                key = row["id"], row["version"]
                definition = session.get(ItemDefinition, key)
                new_definition = definition is None
                if definition is None:
                    session.add(ItemDefinition(id=key[0], version=key[1], **values))
                    session.flush()
                elif any(getattr(definition, k) != v for k, v in values.items()):
                    raise ValueError(f"Immutable definition differs: {key}")
                value = session.get(ItemValueDefinition, key)
                if value is None:
                    session.add(
                        ItemValueDefinition(
                            item_id=key[0],
                            item_version=key[1],
                            valuation_version="item-resale-v1",
                            token_value=row["tokenCost"],
                            resale_basis_points=2500,
                        )
                    )
                if row["skillId"]:
                    rules = profile(row["skillId"])
                    old = session.get(ItemSkillProfile, (row["skillId"], 1))
                    if old is None:
                        session.add(ItemSkillProfile(id=row["skillId"], version=1, rules=rules))
                        session.flush()
                    elif old.rules != rules:
                        raise ValueError("Skill profiles are immutable")
                    binding = session.get(ItemSkillBinding, key)
                    if binding is None:
                        if not new_definition:
                            raise ValueError(
                                "Adding a skill requires a new item definition version"
                            )
                        session.add(
                            ItemSkillBinding(
                                item_id=key[0],
                                item_version=key[1],
                                profile_id=row["skillId"],
                                profile_version=1,
                            )
                        )
                    elif (binding.profile_id, binding.profile_version) != (row["skillId"], 1):
                        raise ValueError("Skill bindings are immutable")
            session.flush()
            session.add(
                ShopRelease(
                    version=version,
                    effective_week=week,
                    catalogue=rows,
                    policy=POLICY,
                    published_at=now,
                )
            )
            session.flush()
        result = {
            "applied": apply,
            "release": version,
            "effectiveWeek": week.isoformat(),
            "items": len(rows),
            "skills": 8,
            "prices": {r["id"]: r["tokenCost"] for r in rows},
        }
        if not apply:
            session.rollback()
        return result
