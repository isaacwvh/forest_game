"""Reproducible development pacing checks; not measured human capture performance."""

import random

from forest_api.calculations import visitor_parameters
from forest_api.visitor_schemas import VisitorRuleDefinition
from forest_api.visitors import slot_succeeds


def simulate(definition, attraction, placed_count, *, capture=0.5, slots=100_000):
    parameters = visitor_parameters(attraction, placed_count, definition.curve)
    draw, taps = random.Random(41023), random.Random(91023)
    gap = issued = welcomed = 0
    for _ in range(slots):
        gap += 1
        if slot_succeeds(
            parameters["active_probability"],
            gap,
            definition.gap_slots,
            lambda probability: draw.random() < probability,
        ):
            issued += 1
            welcomed += taps.random() < capture
            gap = 0
    hours = slots * definition.curve.slot_seconds / 3600
    return {
        "activeWelcomesPerHour": welcomed / hours,
        "issuedPerHour": issued / hours,
        "offlineVisitsPerHour": float(parameters["offline_rate"] * 3600),
        "capacity": parameters["capacity"],
    }


def main():
    # Exactly the versioned development rule, asserted against the actual seeder
    # by test_development_pacing_model. Real skills remain disabled until B8.
    definition = VisitorRuleDefinition.model_validate(
        {
            "curve": {
                "k_micro_units": 2_000_000,
                "starter_probability": "0.5",
                "maximum_probability": "0.8",
                "slot_seconds": 30,
                "offline_fraction": "0.25",
                "offline_rate_cap_per_second": "0.01",
                "base_capacity": 30,
                "maximum_capacity": 120,
            }
        }
    )
    for label, attraction, placed in [
        ("empty", 0, 0),
        ("starter", 2_000_000, 1),
        ("adult", 20_000_000, 1),
        ("15 adults", 300_000_000, 15),
        ("dense stress", 10**12, 1000),
    ]:
        result = simulate(definition, attraction, placed)
        assert result["issuedPerHour"] <= 120
        if placed:
            assert result["activeWelcomesPerHour"] > result["offlineVisitsPerHour"]
        else:
            assert result["activeWelcomesPerHour"] == result["offlineVisitsPerHour"] == 0
        print(
            f"{label}: issued={result['issuedPerHour']:.2f}/h, "
            f"welcomed at 50% capture={result['activeWelcomesPerHour']:.2f}/h, "
            f"offline={result['offlineVisitsPerHour']:.2f}/h, capacity={result['capacity']}"
        )
    print(
        "PASS: fixture pacing at assumed 50% capture. "
        "Device capture rates remain an acceptance check."
    )


if __name__ == "__main__":
    main()
