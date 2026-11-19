"""Fixed approved first expedition. Monthly instances reuse this immutable content."""

from copy import deepcopy

VERSION = "forgotten-forest-observatory-v1"
QUESTS = (
    (
        "steps_days_3",
        "Reach at least 5,000 steps on 3 different days during the expedition.",
        3,
        {"itemId": "astronomers-satchel", "version": 1},
    ),
    (
        "run_walk_sessions_3",
        "Complete 3 recorded runs of at least 2 km or recorded walks of at least 15 minutes, "
        "in any combination.",
        3,
        {"tokens": 400},
    ),
    (
        "items_together_4",
        "Have at least 4 items placed in your garden together.",
        4,
        {"tokens": 200},
    ),
    (
        "active_butterflies_100",
        "Tap to welcome 100 butterflies during the expedition. Stored collections do not count.",
        100,
        {"tokens": 250},
    ),
    ("packs_opened_3", "Open 3 packs of any kind during the expedition.", 3, {"gems": 1}),
    (
        "all_stages_together",
        "Have a sprout, seedling, young plant and adult planted together once.",
        4,
        {"tokens": 300},
    ),
    (
        "copies_advanced_4",
        "Help 4 different plant copies advance at least one growth stage during the expedition.",
        4,
        {"packId": "woodland", "version": 20},
    ),
    (
        "tree_herb_butterflies_50",
        "Tap to welcome 50 butterflies while at least one tree and one herb are planted. "
        "Stored collections do not count.",
        50,
        {"tokens": 300},
    ),
    (
        "monthly_steps_30000",
        "Accumulate 30,000 steps during the expedition, with no daily minimum.",
        30000,
        {"tokens": 400},
    ),
)
ITEMS = (
    (
        "astronomers-satchel",
        "Astronomer's Forgotten Satchel",
        "common",
        "0.52",
        "Charts, crumbs, and very ambitious plans. Everything needed for an evening "
        "that might last a little longer than expected.",
        None,
    ),
    (
        "comet-basin",
        "Comet-Catcher's Basin",
        "rare",
        "0.69",
        "Left outside to catch the rain. By morning, it had caught something "
        "considerably farther from home.",
        "guiding_glow",
    ),
    (
        "worldseed-orrery",
        "Worldseed Orrery",
        "legendary",
        "0.92",
        "An ancient seed dreams at the center of three wandering moons. When their paths align, "
        "a springtime older than the forest stirs beneath every root.",
        "alignment_of_worlds",
    ),
)
ALIGNMENT = {
    "type": "daily_placed_steps_flat_water",
    "family": "alignment_of_worlds",
    "name": "Alignment of Worlds",
    "tiers": [
        {"steps": 2000, "water": "3"},
        {"steps": 4000, "water": "4"},
        {"steps": 6000, "water": "5"},
    ],
}


def profile(skill):
    if skill == "alignment_of_worlds":
        return {"effects": [], "triggeredGrants": [deepcopy(ALIGNMENT)]}
    if skill != "guiding_glow":
        raise ValueError("Unknown expedition skill")
    return {
        "effects": [
            {
                "componentVersion": 2,
                "id": skill,
                "name": "Guiding Glow",
                "description": "+3% water from steps while placed. Duplicate Basins apply once.",
                "system": "growth",
                "scope": "activity",
                "metric": "steps",
                "target": "all_planted_plants",
                "magnitude": {"type": "fixed", "value": "0.03"},
                "stackingGroup": "item_guiding_glow",
            }
        ]
    }


def definition(tags):
    return {
        "schemaVersion": 1,
        "name": "Forgotten Forest Observatory",
        "timezone": "UTC",
        "artworkKey": "expeditions/observatory/v1/observatory.png",
        "quests": [
            {
                "id": key,
                "piece": i,
                "description": copy,
                "target": target,
                "reward": deepcopy(reward),
            }
            for i, (key, copy, target, reward) in enumerate(QUESTS)
        ],
        "milestones": [
            {"count": 4, "reward": {"itemId": "comet-basin", "version": 1}},
            {"count": 9, "reward": {"itemId": "worldseed-orrery", "version": 1}},
        ],
        "tags": tags,
    }
