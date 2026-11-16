"""Versioned declarative components. Unsupported mechanics fail closed."""

import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator
from pydantic.alias_generators import to_camel


class Component(BaseModel):
    model_config = ConfigDict(
        extra="forbid", populate_by_name=True, alias_generator=to_camel, strict=True, frozen=True
    )

    @model_validator(mode="before")
    @classmethod
    def version_types(cls, value):
        if isinstance(value, dict):
            for name in (
                "schemaVersion",
                "schema_version",
                "componentVersion",
                "component_version",
            ):
                if name in value and type(value[name]) is not int:
                    raise ValueError("Component versions require integers")
        return value


class PlantSelector(Component):
    species: list[str] = Field(default_factory=list, max_length=64)
    variants: list[str] = Field(default_factory=list, max_length=64)
    stages: list[Literal["sprout", "seedling", "young", "adult"]] = Field(
        default_factory=list, max_length=4
    )
    tags: list[str] = Field(default_factory=list, max_length=64)


class PresenceCondition(Component):
    type: Literal["placed_count"] = "placed_count"
    selector: PlantSelector
    minimum: int = Field(default=1, strict=True, ge=1, le=10000)


class Magnitude(Component):
    type: Literal["fixed", "per_copy", "per_species", "daily_flights"] = "fixed"
    value: str = Field(max_length=64, pattern=r"^[0-9]{1,7}(\.[0-9]{1,6})?$")
    selector: PlantSelector | None = None
    maximum: str | None = Field(default=None, max_length=64, pattern=r"^[0-9]{1,7}(\.[0-9]{1,6})?$")

    @model_validator(mode="after")
    def supported(self):
        from forest_api.calculations import exact

        exact(self.value)
        if self.type == "daily_flights" and self.selector is not None:
            raise ValueError("Daily-flight magnitudes have no selector")
        if self.type in {"per_copy", "per_species", "daily_flights"}:
            if (self.type != "daily_flights" and self.selector is None) or self.maximum is None:
                raise ValueError("Per-copy magnitudes require a selector and maximum")
            exact(self.maximum)
        elif self.selector is not None or self.maximum is not None:
            raise ValueError("Fixed magnitudes have no count selector or maximum")
        return self


class SkillEffect(Component):
    component_version: Literal[1, 2] = 1
    step_band: Literal["first_2000", "after_2000"] | None = Field(
        default=None, exclude_if=lambda v: v is None
    )
    id: str = Field(pattern=r"^[a-z][a-z0-9_]{0,99}$")
    name: str = Field(min_length=1, max_length=80)
    description: str = Field(min_length=1, max_length=500)
    system: Literal["growth", "visitors"]
    scope: Literal[
        "activity",
        "water",
        "attraction_plant",
        "attraction_garden",
        "offline_capacity",
        "welcome_duration",
    ]
    metric: str | None = None
    target: Literal["all_planted_plants", "selected_plants", "garden"]
    recipients: PlantSelector | None = None
    minimum_stage: Literal["adult"] = "adult"
    condition: PresenceCondition | None = None
    operation: Literal["percent", "flat"] = "percent"
    magnitude: Magnitude
    stacking_group: str = Field(pattern=r"^[a-z][a-z0-9_]{0,99}$")
    stacking_rule: Literal["strongest"] = "strongest"

    @model_validator(mode="after")
    def routing(self):
        if self.component_version == 1 and (
            self.step_band is not None or self.magnitude.type in {"per_species", "daily_flights"}
        ):
            raise ValueError("Extended mechanics require component 2")
        if self.step_band and (self.scope != "activity" or self.metric != "steps"):
            raise ValueError("Step bands only apply to step activity")
        if self.magnitude.type == "daily_flights" and self.scope != "attraction_garden":
            raise ValueError("Daily flights only modify garden attraction")
        growth = self.scope in {"activity", "water"}
        if growth != (self.system == "growth"):
            raise ValueError("Effect system and scope disagree")
        plant_scope = growth or self.scope == "attraction_plant"
        if plant_scope != (self.target != "garden"):
            raise ValueError("Scope and recipient target disagree")
        if (self.target == "selected_plants") != (self.recipients is not None):
            raise ValueError("Selected recipients require exactly one selector")
        if self.scope == "activity":
            if self.metric not in {
                "steps",
                "walking_running_distance_km",
                "active_energy_kcal",
                "flights_climbed",
            } and not re.fullmatch(r"workout_minutes\.[a-z][a-z_]{0,63}", self.metric or ""):
                raise ValueError("Activity effects require one canonical metric")
        elif self.metric is not None:
            raise ValueError("Only activity scope accepts a metric")
        if growth and self.operation == "flat":
            raise ValueError("Fixed water and activity grants require persistent entitlements")
        return self


class SkillCaps(Component):
    """All limits are required in persisted policy; values use exact decimal strings."""

    schema_version: Literal[1]
    activity_bonus: str
    water_bonus: str
    plant_attraction_bonus: str
    garden_attraction_bonus: str
    total_attraction_bonus: str
    flat_attraction_points: str
    flat_attraction_base_fraction: str
    capacity_bonus: str
    flat_capacity: int = Field(strict=True, ge=0, le=1000000)

    @model_validator(mode="after")
    def valid(self):
        from forest_api.calculations import exact

        for name in type(self).model_fields:
            if name not in {"schema_version", "flat_capacity"}:
                exact(getattr(self, name))
        return self


CAPS_VERSION = "b8-caps-v1"
CAPS_V1 = {
    "schemaVersion": 1,
    "activityBonus": "1.5",
    "waterBonus": "1.5",
    "plantAttractionBonus": "0.5",
    "gardenAttractionBonus": "0.5",
    "totalAttractionBonus": "1",
    "flatAttractionPoints": "10",
    "flatAttractionBaseFraction": "0.25",
    "capacityBonus": "2",
    "flatCapacity": 10,
}
