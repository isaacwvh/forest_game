from fractions import Fraction

import pytest
from pydantic import ValidationError

from forest_api.calculations import (
    MICRO,
    CalculationRules,
    MetricRate,
    VisitorCurve,
    attraction,
    calculate_growth,
    capped_quantity,
    exact,
    read_remainder,
    stage_for,
    visitor_parameters,
)

THRESHOLDS = {"sprout": 0, "seedling": 100 * MICRO, "young": 400 * MICRO, "adult": 1000 * MICRO}
ATTRACTION = {"sprout": 2 * MICRO, "seedling": 5 * MICRO, "young": 12 * MICRO, "adult": 20 * MICRO}


def curve(**changes):
    return VisitorCurve(
        k_micro_units=20 * MICRO,
        starter_probability="0.1",
        maximum_probability="0.8",
        slot_seconds=30,
        offline_fraction="0.25",
        offline_rate_cap_per_second="0.01",
        base_capacity=30,
        maximum_capacity=120,
        **changes,
    )


@pytest.mark.parametrize(
    "coefficient,expected", [(0, 0), (1, 10), (1.5, 15), ("0.333333", 3.33333)]
)
def test_normalisation_and_exact_coefficients(coefficient, expected):
    rate = MetricRate(normalisation="1000", water_micro_units=10 * MICRO)
    result = calculate_growth(
        {"steps": 1000}, {"steps": rate}, {"steps": coefficient}, 0, 1000 * MICRO, {}
    )
    assert result.growth == int(Fraction(str(expected)) * MICRO)


def test_metrics_sum_independently_and_omitted_means_zero():
    rate = MetricRate(normalisation="1", water_micro_units=MICRO)
    rates = dict.fromkeys(["steps", "walking_running_distance_km", "workout_minutes.running"], rate)
    result = calculate_growth(
        {"steps": 10, "walking_running_distance_km": 2, "workout_minutes.running": 3},
        rates,
        {"steps": 1, "workout_minutes.running": 2},
        0,
        100 * MICRO,
        {},
    )
    assert result.growth == 16 * MICRO


@pytest.mark.parametrize("chunks", [[1, 1, 1], [2, 1], [3], [1] * 300])
def test_fractional_carry_is_chunk_invariant(chunks):
    rate = MetricRate(normalisation="3", water_micro_units=1)
    growth, state = 0, {}
    for amount in chunks:
        result = calculate_growth(
            {"steps": amount}, {"steps": rate}, {"steps": 1}, growth, 1000, state
        )
        growth, state = result.growth, result.fractional_state
    single = calculate_growth({"steps": sum(chunks)}, {"steps": rate}, {"steps": 1}, 0, 1000, {})
    assert (growth, state) == (single.growth, single.fractional_state)


def test_maturity_clamp_and_adult_discard_overflow():
    rate = MetricRate(normalisation="1", water_micro_units=10)
    result = calculate_growth(
        {"steps": 1},
        {"steps": rate},
        {"steps": 1},
        995,
        1000,
        {"numerator": "1", "denominator": "3"},
    )
    assert result.growth == 1000 and result.awarded == 5 and result.fractional_state == {}
    assert result.maturity_clamped
    assert (
        calculate_growth({"steps": 9}, {"steps": rate}, {"steps": 1}, 1000, 1000, {}).awarded == 0
    )


@pytest.mark.parametrize(
    "value,stage",
    [
        (0, "sprout"),
        (99 * MICRO, "sprout"),
        (100 * MICRO, "seedling"),
        (400 * MICRO, "young"),
        (1000 * MICRO, "adult"),
    ],
)
def test_cumulative_stages_and_placed_attraction(value, stage):
    assert stage_for(value, THRESHOLDS) == stage
    assert attraction(value, THRESHOLDS, ATTRACTION, placed=True) == ATTRACTION[stage]
    assert attraction(value, THRESHOLDS, ATTRACTION, placed=False) == 0


def test_curve_empty_floor_bounds_and_capacity():
    definition = curve()
    assert visitor_parameters(0, 0, definition)["offline_rate"] == 0
    assert visitor_parameters(0, 1, definition)["active_probability"] == Fraction(1, 10)
    prior = Fraction(0)
    for amount in [0, 2 * MICRO, 20 * MICRO, 1000 * MICRO, 10**18]:
        result = visitor_parameters(amount, 1, definition)
        assert prior <= result["active_probability"] <= Fraction(8, 10)
        assert result["offline_rate"] <= Fraction(1, 100)
        assert result["capacity"] == 30
        prior = result["active_probability"]


@pytest.mark.parametrize(
    "field,value",
    [
        ("k_micro_units", 0),
        ("slot_seconds", 0),
        ("starter_probability", "0.9"),
        ("maximum_probability", "1.1"),
        ("offline_fraction", "1"),
        ("offline_rate_cap_per_second", "-1"),
        ("base_capacity", 121),
        ("strategy", "arbitrary_code"),
    ],
)
def test_invalid_visitor_configuration(field, value):
    data = curve().model_dump()
    data[field] = value
    with pytest.raises(ValidationError):
        VisitorCurve.model_validate(data)


@pytest.mark.parametrize(
    "value", [True, "NaN", "Infinity", "-1", "0.0000001", "1000001", "invalid", {}]
)
def test_invalid_coefficients(value):
    with pytest.raises(ValueError):
        exact(value)


def test_caps_are_applied_to_cumulative_inputs():
    rate = MetricRate(normalisation="1", water_micro_units=1, daily_cap=100)
    assert capped_quantity(70, rate) + capped_quantity(130, rate) - capped_quantity(70, rate) == 100
    with pytest.raises(ValueError):
        read_remainder({"numerator": "2", "denominator": "1"})
    with pytest.raises(ValidationError):
        CalculationRules(metrics={"arbitrary": rate}, visitors=curve())
