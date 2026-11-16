"""Bulk-load pinned, placed item emitters; never treat items as plant recipients."""

from sqlalchemy import select

from forest_api.item_models import ItemIdentity, ItemPlacement, ItemSkillBinding, ItemSkillProfile
from forest_api.skill_rules import SkillEffect
from forest_api.skills import ItemFacts


def placed_profiles(session, garden):
    return session.execute(
        select(ItemIdentity, ItemSkillProfile)
        .join(ItemPlacement, ItemPlacement.item_id == ItemIdentity.id)
        .join(
            ItemSkillBinding,
            (ItemSkillBinding.item_id == ItemIdentity.item_id)
            & (ItemSkillBinding.item_version == ItemIdentity.item_version),
        )
        .join(
            ItemSkillProfile,
            (ItemSkillProfile.id == ItemSkillBinding.profile_id)
            & (ItemSkillProfile.version == ItemSkillBinding.profile_version),
        )
        .where(ItemPlacement.garden_id == garden.id, ItemIdentity.owner_id == garden.owner_id)
        .order_by(ItemIdentity.id)
    ).all()


def facts(session, garden):
    from forest_api.activity_inputs import WORKOUT_TYPES

    result = []
    for identity, profile in placed_profiles(session, garden):
        effects = []
        for raw in profile.rules["effects"]:
            metrics = (
                ["workout_minutes." + kind for kind in sorted(set(WORKOUT_TYPES.values()))]
                if raw.get("metric") == "workouts"
                else [raw.get("metric")]
            )
            effects.extend(
                SkillEffect.model_validate({**raw, "metric": metric}) for metric in metrics
            )
        result.append(
            ItemFacts(
                str(identity.id),
                identity.item_id,
                identity.item_version,
                profile.id,
                profile.version,
                tuple(effects),
                profile.rules.get("dailyGrant"),
            )
        )
    return tuple(result)


def descriptions(session, definition):
    binding = session.get(ItemSkillBinding, (definition.id, definition.version))
    if binding is None:
        return []
    profile = session.get(ItemSkillProfile, (binding.profile_id, binding.profile_version))
    if profile.rules.get("dailyGrant"):
        return [
            {
                "id": profile.id,
                "name": "Morning Rain",
                "description": (
                    "+2.5 water per planted plant at account-local midnight. "
                    "Rainharp and plant must be placed at reset. Duplicate harps apply once."
                ),
            }
        ]
    return [
        {"id": e["id"], "name": e["name"], "description": e["description"]}
        for e in profile.rules["effects"]
    ]
