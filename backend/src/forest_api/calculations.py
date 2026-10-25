"""B4 pure calculations. No clock, persistence, currency or external services."""

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation, localcontext
from fractions import Fraction

from pydantic import BaseModel, ConfigDict, Field, model_validator

from forest_api.schemas import STAGES

MAX_INTEGER = 9223372036854775807
MICRO = 1_000_000


class Definition(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


def exact(value: str | int | float | Decimal) -> Fraction:
    if isinstance(value, bool) or not isinstance(value, (str, int, float, Decimal)):
        raise ValueError("Invalid coefficient type")
    if len(str(value)) > 64:
        raise ValueError("Coefficient token is too long")
    try:
        number = Decimal(str(value))
        if not number.is_finite() or number < 0 or number > 1_000_000:
            raise ValueError("Coefficient outside supported range")
        if number != number.quantize(Decimal("0.000001")):
            raise ValueError("Coefficient requires at most six decimal places")
    except InvalidOperation as exc:
        raise ValueError("Invalid decimal coefficient") from exc
    return Fraction(number)


class MetricRate(Definition):
    # Quantity is in the metric's canonical unit, never a display-formatted number.
    normalisation: str
    water_micro_units: int = Field(ge=0, le=MAX_INTEGER)
    daily_cap: int | None = Field(default=None, ge=0, le=1_000_000_000)

    @model_validator(mode="after")
    def valid(self):
        if exact(self.normalisation) <= 0:
            raise ValueError("Normalisation must be positive")
        return self


class VisitorCurve(Definition):
    strategy: str = "bounded_attraction_v1"
    k_micro_units: int = Field(gt=0, le=MAX_INTEGER)
    starter_probability: str
    maximum_probability: str
    slot_seconds: int = Field(gt=0, le=86400)
    offline_fraction: str
    offline_rate_cap_per_second: str
    base_capacity: int = Field(ge=0, le=1_000_000_000)
    maximum_capacity: int = Field(ge=0, le=1_000_000_000)
    knee_micro_units: int = Field(default=300_000_000, gt=0, le=MAX_INTEGER)
    knee_probability: str = "0.6"
    tail_scale_micro_units: int = Field(default=120_000_000, gt=0, le=MAX_INTEGER)

    @model_validator(mode="after")
    def valid(self):
        if self.strategy not in {"bounded_attraction_v1", "linear_softcap_v2"}:
            raise ValueError("Unsupported curve strategy")
        if not 0 < exact(self.starter_probability) <= exact(self.maximum_probability) <= 1:
            raise ValueError("Invalid probability bounds")
        if not 0 <= exact(self.offline_fraction) < 1:
            raise ValueError("Invalid offline fraction")
        exact(self.offline_rate_cap_per_second)
        if self.base_capacity > self.maximum_capacity:
            raise ValueError("Capacity exceeds maximum")
        if self.strategy == "linear_softcap_v2" and not (
            exact(self.starter_probability)
            < exact(self.knee_probability)
            < exact(self.maximum_probability)
        ):
            raise ValueError("Linear curve requires increasing floor, knee and ceiling")
        return self


class CalculationRules(Definition):
    schema_version: int = Field(default=1, ge=1, le=1)
    metrics: dict[str, MetricRate]
    visitors: VisitorCurve
    workout_daily_cap_seconds: int = Field(default=7200, ge=0, le=86400)

    @model_validator(mode="after")
    def known_metrics(self):
        from forest_api.schemas import BehaviourDefinition

        BehaviourDefinition(metric_multipliers=dict.fromkeys(self.metrics, 1))
        if "steps" not in self.metrics:
            raise ValueError("Steps conversion is required")
        if "workout_minutes.*" in self.metrics:
            raise ValueError("Workout wildcard is a coefficient fallback, not an input metric")
        return self


def stage_for(growth: int, thresholds: dict[str, int]) -> str:
    return next(stage for stage in reversed(STAGES) if growth >= thresholds[stage])


def capped_quantity(quantity: int, rate: MetricRate) -> int:
    return quantity if rate.daily_cap is None else min(quantity, rate.daily_cap)


def read_remainder(state: dict) -> Fraction:
    if not state:
        return Fraction(0)
    if set(state) != {"numerator", "denominator"}:
        raise ValueError("Unsupported fractional accounting state")
    if any(type(value) not in {str, int} for value in state.values()):
        raise ValueError("Fractional state requires exact integer strings")
    try:
        numerator, denominator = int(state["numerator"]), int(state["denominator"])
    except (ValueError, TypeError) as exc:
        raise ValueError("Invalid fractional accounting state") from exc
    if not 0 <= numerator < denominator:
        raise ValueError("Invalid fractional accounting state")
    return Fraction(numerator, denominator)


def remainder_state(value: Fraction) -> dict:
    if not value:
        return {}
    return {"numerator": str(value.numerator), "denominator": str(value.denominator)}


@dataclass(frozen=True)
class GrowthResult:
    growth: int
    fractional_state: dict
    calculated: Fraction
    awarded: int
    maturity_clamped: bool


def calculate_growth(
    quantities: dict[str, int | Fraction],
    rates: dict[str, MetricRate],
    coefficients: dict,
    growth: int,
    maximum: int,
    fractional_state: dict,
    *,
    activity_factors: dict[str, Fraction] | None = None,
    water_factor: Fraction = Fraction(1),
) -> GrowthResult:
    if not 0 <= growth <= maximum <= MAX_INTEGER:
        raise ValueError("Invalid growth bounds")
    if not 1 <= water_factor <= Fraction(5, 2):
        raise ValueError("Water factor exceeds supported bounds")
    calculated = Fraction(0)
    for metric, quantity in quantities.items():
        if quantity < 0 or metric not in rates:
            raise ValueError("Invalid metric quantity")
        rate = rates[metric]
        factor = (activity_factors or {}).get(metric, Fraction(1))
        if not 1 <= factor <= Fraction(5, 2):
            raise ValueError("Activity factor exceeds supported bounds")
        coefficient = coefficients.get(metric)
        if coefficient is None:
            coefficient = (
                coefficients.get("workout_minutes.*", 0)
                if metric.startswith("workout_minutes.")
                else 0
            )
        calculated += (
            Fraction(quantity)
            / exact(rate.normalisation)
            * rate.water_micro_units
            * exact(coefficient)
            * factor
        )
    calculated *= water_factor
    total = calculated + read_remainder(fractional_state)
    remaining = maximum - growth
    if total >= remaining:
        return GrowthResult(maximum, {}, calculated, remaining, total > remaining)
    awarded = total.numerator // total.denominator
    return GrowthResult(
        growth + awarded, remainder_state(total - awarded), calculated, awarded, False
    )


def attraction(growth: int, thresholds: dict, profile: dict, *, placed: bool) -> int:
    return int(profile[stage_for(growth, thresholds)]) if placed else 0


def visitor_parameters(total_attraction: int, placed_count: int, curve: VisitorCurve) -> dict:
    if total_attraction < 0 or placed_count < 0:
        raise ValueError("Invalid attraction")
    probability = Fraction(0)
    if placed_count:
        if curve.strategy == "linear_softcap_v2":
            floor, knee, ceiling = (
                exact(curve.starter_probability),
                exact(curve.knee_probability),
                exact(curve.maximum_probability),
            )
            if total_attraction <= curve.knee_micro_units:
                probability = floor + (knee - floor) * Fraction(
                    total_attraction, curve.knee_micro_units
                )
            else:
                # Freeze the deterministic, high-precision result in the visitor context.
                with localcontext() as context:
                    context.prec = 36
                    decay = (
                        Decimal(
                            -min(
                                total_attraction - curve.knee_micro_units,
                                60 * curve.tail_scale_micro_units,
                            )
                        )
                        / curve.tail_scale_micro_units
                    ).exp()
                probability = ceiling - (ceiling - knee) * Fraction(decay)
        else:
            probability = max(
                exact(curve.starter_probability),
                exact(curve.maximum_probability)
                * total_attraction
                / (total_attraction + curve.k_micro_units),
            )
    offline = min(
        exact(curve.offline_rate_cap_per_second),
        probability / curve.slot_seconds * exact(curve.offline_fraction),
    )
    # Exact fractions are internal configuration results, not issued visitor opportunities.
    return {
        "active_probability": probability,
        "offline_rate": offline,
        "capacity": min(curve.base_capacity, curve.maximum_capacity),
    }
