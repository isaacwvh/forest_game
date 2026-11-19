"""Reward-only immutable item publication; never modifies the shop pools."""

from decimal import Decimal

from forest_api.expedition_definitions import ITEMS, profile
from forest_api.item_models import ItemDefinition, ItemSkillBinding, ItemSkillProfile


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
