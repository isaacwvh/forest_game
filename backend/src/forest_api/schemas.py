import re
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import (
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    PlainSerializer,
    WithJsonSchema,
    field_validator,
    model_validator,
)
from pydantic.alias_generators import to_camel

from forest_api.skill_rules import SkillEffect

STAGES = ("sprout", "seedling", "young", "adult")
Stage = Literal["sprout", "seedling", "young", "adult"]
MicroAmount = Annotated[int, Field(strict=True, ge=0, le=9223372036854775807)]
# Geometry is JSON numbers for the native client; micro-unit bigint values use strings.
GroundNumber = Annotated[Decimal, PlainSerializer(float, return_type=float, when_used="json")]


class DTO(BaseModel):
    model_config = ConfigDict(alias_generator=to_camel, populate_by_name=True, extra="forbid")


class StageAmounts(DTO):
    sprout: MicroAmount
    seedling: MicroAmount
    young: MicroAmount
    adult: MicroAmount

    def ordered(self) -> list[int]:
        return [getattr(self, stage) for stage in STAGES]


class GrowthDefinition(DTO):
    thresholds: StageAmounts
    maximum_growth_micro_units: MicroAmount

    @model_validator(mode="after")
    def valid_thresholds(self) -> "GrowthDefinition":
        values = self.thresholds.ordered()
        if values[0] != 0 or any(a >= b for a, b in zip(values, values[1:], strict=False)):
            raise ValueError("Growth thresholds must start at 0 and strictly increase")
        if self.maximum_growth_micro_units < values[-1]:
            raise ValueError("Growth maximum must reach the adult stage")
        return self


class AttractionDefinition(DTO):
    stage_attraction: StageAmounts
    gameplay_tags: list[str] = Field(default_factory=list, max_length=64)

    @model_validator(mode="after")
    def increasing(self) -> "AttractionDefinition":
        values = self.stage_attraction.ordered()
        if any(a >= b for a, b in zip(values, values[1:], strict=False)):
            raise ValueError("Stage attraction must strictly increase")
        return self


class BehaviourDefinition(DTO):
    schema_version: Literal[1, 2] = 1
    metric_multipliers: dict[str, Annotated[float, Field(ge=0, allow_inf_nan=False)]]
    conditional_modifiers: list[dict] = Field(default_factory=list, max_length=0)
    garden_effects: list[SkillEffect] = Field(default_factory=list, max_length=64)

    @model_validator(mode="before")
    @classmethod
    def exact_version(cls, value):
        if isinstance(value, dict):
            version = value.get("schemaVersion", value.get("schema_version", 1))
            if type(version) is not int:
                raise ValueError("Behaviour versions require integers")
        return value

    @model_validator(mode="after")
    def versioned_effects(self):
        if self.schema_version == 1 and self.garden_effects:
            raise ValueError("Schema 1 supports neutral effects only")
        if len({effect.id for effect in self.garden_effects}) != len(self.garden_effects):
            raise ValueError("Effect IDs must be unique in a profile")
        units = {}
        for effect in self.garden_effects:
            key = effect.system, effect.scope, effect.metric, effect.stacking_group
            if units.setdefault(key, effect.operation) != effect.operation:
                raise ValueError("A stacking group cannot mix percentage and flat units")
        from forest_api.calculations import exact

        for value in self.metric_multipliers.values():
            exact(value)
        return self

    @field_validator("metric_multipliers")
    @classmethod
    def known_metric_shapes(cls, values: dict) -> dict:
        daily = {"steps", "walking_running_distance_km", "active_energy_kcal", "flights_climbed"}
        if any(
            key not in daily
            and key != "workout_minutes.*"
            and not re.fullmatch(r"workout_minutes\.[a-z][a-z_]{0,63}", key)
            for key in values
        ):
            raise ValueError("Unknown activity metric")
        return values


class ProfileRef(DTO):
    id: str
    version: int


class PinnedProfiles(DTO):
    growth: ProfileRef
    behaviour: ProfileRef
    attraction: ProfileRef


class RegisterAccount(DTO):
    request_id: UUID
    username: str = Field(min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_]+$")
    display_name: str = Field(min_length=1, max_length=64)
    game_timezone: str = Field(min_length=1, max_length=64)

    @field_validator("username")
    @classmethod
    def normalized_username(cls, value: str) -> str:
        return value.lower()

    @field_validator("display_name")
    @classmethod
    def valid_display_name(cls, value: str) -> str:
        value = value.strip()
        if not value or any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid display name")
        return value

    @field_validator("game_timezone")
    @classmethod
    def known_timezone(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except (ZoneInfoNotFoundError, ValueError) as exc:
            raise ValueError("Unknown IANA timezone") from exc
        return value


class UpdateProfile(DTO):
    request_id: UUID
    username: str | None = Field(
        default=None, min_length=3, max_length=32, pattern=r"^[A-Za-z0-9_]+$"
    )
    display_name: str | None = Field(default=None, min_length=1, max_length=64)

    @field_validator("username")
    @classmethod
    def normalized_username(cls, value: str | None) -> str | None:
        return RegisterAccount.normalized_username(value) if value is not None else value

    @field_validator("display_name")
    @classmethod
    def valid_display_name(cls, value: str | None) -> str | None:
        return RegisterAccount.valid_display_name(value) if value is not None else value

    @model_validator(mode="after")
    def at_least_one_field(self) -> "UpdateProfile":
        if self.username is None and self.display_name is None:
            raise ValueError("At least one profile field is required")
        if any(getattr(self, name) is None for name in self.model_fields_set - {"request_id"}):
            raise ValueError("Profile fields cannot be null")
        return self


class UserDTO(DTO):
    user_id: UUID
    username: str
    display_name: str
    game_timezone: str
    created_at: datetime


class AccountDTO(DTO):
    profile: UserDTO
    garden_id: UUID
    starter_plant_id: UUID


class PlacementDTO(DTO):
    garden_id: UUID
    x: GroundNumber
    y: GroundNumber
    rotation_degrees: GroundNumber


class GrowthProgressDTO(DTO):
    stage_start_micro_units: str
    next_stage_micro_units: str | None
    maximum_growth_micro_units: str


class PlantDTO(DTO):
    plant_id: UUID
    species_id: str
    variant_id: str
    pinned_profiles: PinnedProfiles
    growth_micro_units: str
    growth_stage: Stage
    base_attraction_micro_units: str
    contributes_attraction: bool
    model_key: str
    thumbnail_key: str
    placement: PlacementDTO | None
    growth_progress: GrowthProgressDTO | None = None
    garden_skills: list[dict] = Field(default_factory=list)


class InventoryDTO(DTO):
    plants: list[PlantDTO]
    next_cursor: UUID | None


class GardenDTO(DTO):
    garden_id: UUID
    width: GroundNumber
    depth: GroundNumber
    visibility: Literal["friends", "private"]
    coordinate_unit: Literal["garden_unit"] = "garden_unit"
    garden_unit_metres: GroundNumber
    catalog_version: str
    layout_version: int
    state_version: int
    plants: list[PlantDTO]
    total_attraction_micro_units: str = "0"
    skill_summary: dict | None = None


class StageAssetDTO(DTO):
    model_key: str
    thumbnail_key: str


class VariantDTO(DTO):
    variant_id: str
    display_name: str
    description: str
    rarity: str  # Legacy metadata; catalogue grouping/new draws use species rarity.
    asset_catalog_key: str
    asset_catalog_version: str
    profile_overrides: dict[str, ProfileRef | None]
    stages: dict[Stage, StageAssetDTO]


class SpeciesDTO(DTO):
    species_id: str
    display_name: str
    rarity: str = "development_unbalanced"
    description: str
    clearance_radius: GroundNumber
    is_fixture: bool
    default_profiles: PinnedProfiles
    variants: list[VariantDTO]


class CatalogueDTO(DTO):
    catalog_version: str
    is_fixture: bool
    coordinate_unit: Literal["garden_unit"] = "garden_unit"
    garden_unit_metres: GroundNumber
    coordinate_decimal_places: Literal[3] = 3
    rotation_decimal_places: Literal[2] = 2
    species: list[SpeciesDTO]
    profiles: dict[str, list[dict]]


def canonical_number(value: object, places: int, maximum: Decimal) -> Decimal:
    # Never coerce strings, booleans or nulls into a placement coordinate.
    if type(value) not in {int, float, Decimal}:
        raise ValueError("A JSON number is required")
    number = Decimal(str(value))
    if not number.is_finite() or number < 0 or number > maximum:
        raise ValueError("Number outside the supported range")
    try:
        canonical = number.quantize(Decimal(1).scaleb(-places))
    except InvalidOperation as exc:
        raise ValueError("Invalid number precision") from exc
    if number != canonical:
        raise ValueError("Excess numeric precision")
    return canonical.copy_abs()  # Canonicalise negative zero, too.


COORDINATE_JSON_SCHEMA = {
    "type": "number",
    "minimum": 0,
    "maximum": 999999.999,
    "multipleOf": 0.001,
}
YAW_JSON_SCHEMA = {"type": "number", "minimum": 0, "maximum": 359.99, "multipleOf": 0.01}

Coordinate = Annotated[
    Decimal,
    BeforeValidator(lambda value: canonical_number(value, 3, Decimal("999999.999"))),
    PlainSerializer(float, return_type=float, when_used="json"),
    WithJsonSchema(COORDINATE_JSON_SCHEMA, mode="validation"),
]
Yaw = Annotated[
    Decimal,
    BeforeValidator(lambda value: canonical_number(value, 2, Decimal("359.99"))),
    PlainSerializer(float, return_type=float, when_used="json"),
    WithJsonSchema(YAW_JSON_SCHEMA, mode="validation"),
]


class PlantAction(DTO):
    action: Literal["plant"]
    plant_id: UUID
    x: Coordinate
    y: Coordinate
    rotation_degrees: Yaw


class MoveAction(DTO):
    action: Literal["move"]
    plant_id: UUID
    x: Coordinate
    y: Coordinate
    rotation_degrees: Annotated[Yaw | None, WithJsonSchema(YAW_JSON_SCHEMA, mode="validation")] = (
        Field(default=None, json_schema_extra=lambda schema: schema.pop("default", None))
    )

    @model_validator(mode="after")
    def no_explicit_null_rotation(self) -> "MoveAction":
        if "rotation_degrees" in self.model_fields_set and self.rotation_degrees is None:
            raise ValueError("Omit rotation to preserve it; null is invalid")
        return self


class RotateAction(DTO):
    action: Literal["rotate"]
    plant_id: UUID
    rotation_degrees: Yaw


class StoreAction(DTO):
    action: Literal["store"]
    plant_id: UUID


PlacementAction = Annotated[
    PlantAction | MoveAction | RotateAction | StoreAction, Field(discriminator="action")
]


class GardenEditRequest(DTO):
    request_id: UUID
    expected_layout_version: Annotated[int, Field(strict=True, ge=0, le=9223372036854775807)]
    catalog_version: str = Field(min_length=1, max_length=100)
    actions: list[PlacementAction] = Field(min_length=1, max_length=100)

    @model_validator(mode="after")
    def unique_plants(self) -> "GardenEditRequest":
        if len({action.plant_id for action in self.actions}) != len(self.actions):
            raise ValueError("Each plant may appear only once per edit")
        return self


class GardenEditResult(DTO):
    request_id: UUID
    garden: GardenDTO
    updated_plants: list[PlantDTO]
