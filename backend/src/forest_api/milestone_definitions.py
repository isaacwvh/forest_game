"""Finite, versioned reward data. Threshold IDs never change when content grows."""

VERSION = "milestones-woodland-v1"
PACK_VERSION = 20
RARITY_COUNTS = {"common": 10, "rare": 10, "epic": 7, "legendary": 3}


def quest(
    key, track, metric, threshold, title, *, tokens=0, gems=0, pack=None, quantity=1, category=None
):
    return {
        "milestoneId": key,
        "track": track,
        "category": category,
        "metric": metric,
        "threshold": threshold,
        "title": title,
        "rewardTokens": str(tokens),
        "rewardGems": str(gems),
        "rewardPacks": (
            [
                {
                    "packId": pack,
                    "version": PACK_VERSION,
                    "quantity": quantity,
                    "displayName": "Enchanted Woodland"
                    if pack == "select-woodland"
                    else "Standard Woodland",
                }
            ]
            if pack
            else []
        ),
    }


def definitions():
    result = [
        quest("steps_new_beginnings", "steps", "opening", 1, "New Beginnings", pack="woodland")
    ]
    steps = (
        (1000, 0, 0, "woodland", 1),
        (5000, 300, 0, None, 0),
        (10000, 300, 0, None, 0),
        (25000, 600, 0, None, 0),
        (50000, 900, 0, None, 0),
        (100000, 0, 0, "select-woodland", 1),
        (200000, 1200, 2, None, 0),
        (300000, 1200, 2, None, 0),
        (400000, 1200, 2, None, 0),
        (500000, 0, 5, "select-woodland", 1),
        (750000, 2400, 5, None, 0),
        (1000000, 0, 10, "select-woodland", 1),
        (1500000, 3600, 10, None, 0),
        (2000000, 0, 15, "select-woodland", 1),
        (3000000, 4800, 20, None, 0),
        (5000000, 0, 30, "select-woodland", 2),
    )
    for n, tokens, gems, pack, quantity in steps:
        result.append(
            quest(
                f"steps_{n}",
                "steps",
                "steps",
                n,
                f"{n:,} lifetime steps",
                tokens=tokens,
                gems=gems,
                pack=pack,
                quantity=quantity,
            )
        )
    butterflies = (
        (1, 0, 0),
        (3, 75, 0),
        (10, 75, 0),
        (25, 150, 0),
        (100, 300, 0),
        (250, 450, 0),
        (500, 600, 0),
        (1000, 600, 0),
        (2000, 900, 0),
        (5000, 1200, 0),
        (10000, 1800, 3),
        (25000, 3000, 5),
        (50000, 4800, 10),
        (100000, 7200, 15),
    )
    for n, tokens, gems in butterflies:
        result.append(
            quest(
                f"butterfly_{n}",
                "butterfly",
                "butterflies",
                n,
                f"{n:,} {'butterfly' if n == 1 else 'butterflies'} welcomed",
                tokens=tokens,
                gems=gems,
                pack="woodland" if n == 1 else None,
            )
        )
    result.append(
        quest(
            "growth_first_seedling",
            "growth",
            "seedling",
            1,
            "First seedling grown through activity",
            tokens=150,
            category="maturity",
        )
    )
    maturity = (
        (1, 0, 0, "woodland", 1),
        (5, 600, 0, None, 0),
        (10, 0, 0, "woodland", 1),
        (25, 1800, 3, None, 0),
        (50, 0, 5, "select-woodland", 1),
        (100, 3600, 10, None, 0),
        (250, 0, 20, "select-woodland", 2),
        (500, 6000, 30, None, 0),
    )
    for n, tokens, gems, pack, quantity in maturity:
        result.append(
            quest(
                f"growth_mature_{n}",
                "growth",
                "maturity",
                n,
                "First mature plant grown through activity"
                if n == 1
                else f"{n:,} distinct plant copies matured",
                tokens=tokens,
                gems=gems,
                pack=pack,
                quantity=quantity,
                category="maturity",
            )
        )
    discovery = {
        "common": ((3, 300, 0), (5, 600, 0), (10, 1200, 0)),
        "rare": ((1, 300, 0), (3, 600, 0), (5, 1200, 0), (10, 2400, 0)),
        "epic": ((1, 600, 0), (3, 1200, 0), (5, 2400, 0), (7, 3600, 5)),
        "legendary": ((1, 1200, 0), (2, 2400, 0), (3, 4800, 5)),
    }
    for rarity, tiers in discovery.items():
        for n, tokens, gems in tiers:
            result.append(
                quest(
                    f"discovery_{rarity}_{n}",
                    "growth",
                    f"discovery_{rarity}",
                    n,
                    f"Discover {n} unique {rarity.title()} species",
                    tokens=tokens,
                    gems=gems,
                    category="discovery",
                )
            )
    result.extend(
        [
            quest(
                "special_day_10000",
                "special",
                "daily_steps",
                10000,
                "At least 10,000 steps in one day",
                tokens=300,
            ),
            quest(
                "special_day_20000",
                "special",
                "daily_steps",
                20000,
                "At least 20,000 steps in one day",
                tokens=600,
            ),
            quest(
                "special_run_5km",
                "special",
                "running_metres",
                5000,
                "One run of at least 5 km",
                pack="woodland",
            ),
            quest(
                "special_workout_60min",
                "special",
                "workout_minutes",
                60,
                "One workout of at least 60 active minutes",
                pack="woodland",
            ),
            quest(
                "special_run_10km",
                "special",
                "running_metres",
                10000,
                "One run of at least 10 km",
                pack="select-woodland",
            ),
            quest(
                "special_days_7_in_14",
                "special",
                "rolling_days",
                7,
                "Activity on 7 days within 14 days",
                tokens=600,
            ),
            quest(
                "special_days_30",
                "special",
                "activity_days",
                30,
                "Activity on 30 distinct days",
                pack="woodland",
                gems=5,
            ),
            quest(
                "special_days_100",
                "special",
                "activity_days",
                100,
                "Activity on 100 distinct days",
                pack="select-woodland",
                gems=10,
            ),
        ]
    )
    for order, item in enumerate(result):
        item["order"] = order
        item["scope"] = (
            "lifetime"
            if item["track"] != "special"
            else {
                "daily_steps": "game_date",
                "running_metres": "single_workout",
                "workout_minutes": "single_workout",
                "rolling_days": "rolling_14_days",
            }.get(item["metric"], "lifetime")
        )
    return result


def event_definitions(event_id):
    result = [
        quest(
            f"event_{event_id}_growth",
            "event",
            "growth",
            1,
            "Earn growth on a planted sprout",
            tokens=300,
        ),
        quest(
            f"event_{event_id}_butterflies",
            "event",
            "butterflies",
            50,
            "Welcome or collect 50 butterflies",
            tokens=300,
        ),
        quest(
            f"event_{event_id}_days_3",
            "event",
            "activity_days",
            3,
            "Complete 3 activity days",
            tokens=600,
        ),
        quest(
            f"event_{event_id}_days_5",
            "event",
            "activity_days",
            5,
            "Complete 5 activity days",
            pack="woodland",
        ),
    ]
    for order, item in enumerate(result):
        item.update(order=order, scope="event", eventId=event_id)
    return result
