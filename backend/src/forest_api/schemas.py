import re
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, PlainSerializer, field_validator, model_validator
from pydantic.alias_generators import to_camel

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
    schema_version: Literal[1] = 1
    metric_multipliers: dict[str, Annotated[float, Field(ge=0, allow_inf_nan=False)]]
    # Handlers land in B8. Reject configured effects until they can be evaluated.
    conditional_modifiers: list[dict] = Field(default_factory=list, max_length=0)
    garden_effects: list[dict] = Field(default_factory=list, max_length=0)

    @field_validator("metric_multipliers")
    @classmethod
    def known_metric_shapes(cls, values: dict) -> dict:
        daily = {"steps", "walking_running_distance_km", "active_energy_kcal", "flights_climbed"}
        if any(
            key not in daily and not re.fullmatch(r"workout_minutes\.[a-z][a-z_]{0,63}", key)
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


class StageAssetDTO(DTO):
    model_key: str
    thumbnail_key: str


class VariantDTO(DTO):
    variant_id: str
    display_name: str
    description: str
    rarity: str
    asset_catalog_key: str
    asset_catalog_version: str
    profile_overrides: dict[str, ProfileRef | None]
    stages: dict[Stage, StageAssetDTO]


class SpeciesDTO(DTO):
    species_id: str
    display_name: str
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
