"""Reward-only immutable item publication; never modifies the shop pools."""

from decimal import Decimal

from forest_api.expedition_definitions import ITEMS, profile
from forest_api.item_models import (
    ItemDefinition,
    ItemSkillBinding,
    ItemSkillProfile,
    ItemValueDefinition,
)

# Item_Game_Data.xlsx Items!F23:H24: 25%, rounded down, for these v1 rewards.
# Orrery's valuation cells are blank; it intentionally has no fallback.
TOKEN_VALUES = {("astronomers-satchel", 1): 500, ("comet-basin", 1): 1250}


def approved_valuation(item_id, version):
    value = TOKEN_VALUES.get((item_id, version))
    if value is None:
        return None
    return ItemValueDefinition(
        item_id=item_id,
        item_version=version,
        valuation_version="item-resale-v1",
        token_value=value,
        resale_basis_points=2500,
    )


def publish_items(session):
    for key, name, rarity, radius, description, skill in ITEMS:
        prefix = f"assets/items/{key}/v1/"
        values = dict(
            display_name=name,
            description=description,
            rarity=rarity,
            asset_version="1.0.0",
            model_key=prefix + f"models/{key}-standard.usdz",
            thumbnail_key=prefix + f"ui/{key}-standard.png",
            clearance_radius=Decimal(radius),
        )
        old = session.get(ItemDefinition, (key, 1))
        if old is None:
            session.add(ItemDefinition(id=key, version=1, **values))
            session.flush()
        elif any(getattr(old, k) != v for k, v in values.items()):
            raise ValueError("Immutable reward item differs")
        approved = approved_valuation(key, 1)
        if approved is not None:
            published_value = session.get(ItemValueDefinition, (key, 1))
            if published_value is None:
                session.add(approved)
            elif any(
                getattr(published_value, field) != getattr(approved, field)
                for field in ("valuation_version", "token_value", "resale_basis_points")
            ):
                raise ValueError("Immutable reward item valuation differs")
        if skill:
            rules = profile(skill)
            published = session.get(ItemSkillProfile, (skill, 1))
            if published is None:
                session.add(ItemSkillProfile(id=skill, version=1, rules=rules))
                session.flush()
            elif published.rules != rules:
                raise ValueError("Immutable reward skill differs")
            binding = session.get(ItemSkillBinding, (key, 1))
            if binding is None:
                session.add(
                    ItemSkillBinding(
                        item_id=key, item_version=1, profile_id=skill, profile_version=1
                    )
                )
            elif (binding.profile_id, binding.profile_version) != (skill, 1):
                raise ValueError("Immutable reward skill binding differs")
    session.flush()
