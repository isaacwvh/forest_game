"""Validate future replacements against the client's bounded evaluator vocabulary."""

import re

from forest_api import collection
from forest_api.expedition_definitions import QUESTS
from forest_api.item_models import ItemDefinition


def validate_content(session, settings, version, data):
    if not re.fullmatch(r"[a-z][a-z0-9_-]{0,99}", version):
        raise ValueError("Use a stable version identifier")
    if (
        data.get("schemaVersion") != 1
        or data.get("timezone") != "UTC"
        or not 1 <= len(data.get("name", "")) <= 100
    ):
        raise ValueError("Unsupported expedition content")
    if (
        not re.fullmatch(r"expeditions/[a-z0-9_/-]+\.png", data.get("artworkKey", ""))
        or ".." in data["artworkKey"]
    ):
        raise ValueError("Use a versioned bundled expedition painting")
    quests = data.get("quests", [])
    if (
        len(quests) != 9
        or {q["id"] for q in quests} != {q[0] for q in QUESTS}
        or {q["piece"] for q in quests} != set(range(9))
    ):
        raise ValueError("Exactly nine supported quests must map one-to-one to pieces")
    for quest in quests:
        if (
            type(quest["target"]) is not int
            or not 1 <= quest["target"] <= 1_000_000_000
            or not 1 <= len(quest["description"]) <= 500
        ):
            raise ValueError("Invalid quest threshold or description")
    milestones = data.get("milestones", [])
    if len(milestones) != 2 or {m["count"] for m in milestones} != {4, 9}:
        raise ValueError("Keep independent four- and nine-quest milestones")
    for reward in [q["reward"] for q in quests] + [m["reward"] for m in milestones]:
        if len(set(reward) & {"tokens", "gems", "itemId", "packId"}) != 1:
            raise ValueError("Each reward must have exactly one supported component")
        if "itemId" in reward:
            if (
                set(reward) != {"itemId", "version"}
                or session.get(ItemDefinition, (reward["itemId"], reward["version"])) is None
            ):
                raise ValueError("Reward item must be published with a pinned version")
        elif "packId" in reward:
            if set(reward) != {"packId", "version"}:
                raise ValueError("Pin the pack version")
            collection.pack_contract(session, settings, reward["packId"], reward["version"])
        elif len(reward) != 1 or any(
            type(v) is not int or not 1 <= v <= 9223372036854775807 for v in reward.values()
        ):
            raise ValueError("Invalid currency reward")
