"""Current planned item pricing; acquired-copy valuations remain immutable."""

LEGENDARY_TOKEN_VALUE = 5500


def token_value_for_rarity(rarity, planned_value):
    return LEGENDARY_TOKEN_VALUE if rarity == "legendary" else planned_value
