"""Typed daily totals and recorded workouts with independent availability."""

from datetime import date, datetime, timedelta
from uuid import UUID

from pydantic import AwareDatetime, Field, field_validator, model_validator

from forest_api.schemas import DTO, GardenDTO


class Observation(DTO):
    observed_at: AwareDatetime

    @field_validator("observed_at", mode="before")
    @classmethod
    def timestamp(cls, value):
        if not isinstance(value, (str, datetime)):
            raise ValueError("Use an ISO timestamp with an offset")
        return value


class DailyQuantities(DTO):
    # Decimal strings preserve cumulative metres/kcal to 0.001 without JSON float drift.
    walking_running_distance_metres: str | None = Field(
        default=None, pattern=r"^[0-9]{1,9}(\.[0-9]{1,3})?$"
    )
    active_energy_kcal: str | None = Field(default=None, pattern=r"^[0-9]{1,7}(\.[0-9]{1,3})?$")
    flights_climbed: int | None = Field(default=None, strict=True, ge=0, le=1_000_000)


class EnrolActivity(Observation, DailyQuantities):
    request_id: UUID
    installation_id: UUID
    # Replacing a device requires compare-and-swap; a sync cannot replace one.
    expected_device_id: UUID | None = None
    steps: int | None = Field(default=None, strict=True, ge=0, le=1_000_000_000)
    workouts_available: bool = False


class ActivityDayInput(DailyQuantities):
    game_date: date
    steps: int | None = Field(strict=True, ge=0, le=1_000_000_000)

    @field_validator("game_date", mode="before")
    @classmethod
    def calendar_date(cls, value):
        if not isinstance(value, (str, date)) or isinstance(value, datetime):
            raise ValueError("Use an ISO calendar date")
        return value


class WorkoutSegment(DTO):
    original_type: int = Field(strict=True, ge=0, le=10000)
    start: AwareDatetime
    end: AwareDatetime
    duration_milliseconds: int = Field(strict=True, ge=0, le=86_400_000)

    @model_validator(mode="after")
    def valid_interval(self):
        if self.end <= self.start:
            raise ValueError("Workout intervals must have positive elapsed time")
        if self.duration_milliseconds * 1000 > (self.end - self.start) // timedelta(microseconds=1):
            raise ValueError("Eligible duration cannot exceed elapsed time")
        return self


class WorkoutInput(WorkoutSegment):
    workout_id: UUID
    source_bundle_identifier: str = Field(min_length=1, max_length=255)
    was_user_entered: bool | None = None
    has_segments: bool = False
    segments: list[WorkoutSegment] = Field(default_factory=list, max_length=256)

    @model_validator(mode="after")
    def valid_segments(self):
        if any(s.start < self.start or s.end > self.end for s in self.segments):
            raise ValueError("Segments must be inside the parent workout")
        if self.segments and not self.has_segments:
            raise ValueError("Declare segment accounting explicitly")
        if sum(s.duration_milliseconds for s in self.segments) > self.duration_milliseconds:
            raise ValueError("Segment duration cannot exceed the parent eligible duration")
        return self


class SyncActivity(Observation):
    request_id: UUID
    installation_id: UUID
    device_id: UUID
    days: list[ActivityDayInput] = Field(min_length=1, max_length=7)
    workouts_available: bool = False
    workouts: list[WorkoutInput] = Field(default_factory=list, max_length=500)

    @model_validator(mode="after")
    def unique_dates(self):
        if len({day.game_date for day in self.days}) != len(self.days):
            raise ValueError("Duplicate game dates")
        if len({w.workout_id for w in self.workouts}) != len(self.workouts):
            raise ValueError("Duplicate workout identities in one upload")
        if self.workouts and not self.workouts_available:
            raise ValueError("Workout records require an available workout observation")
        if sum(len(w.segments) for w in self.workouts) > 2000:
            raise ValueError("Split workout uploads into batches of at most 2000 segments")
        return self


class DeviceDTO(DTO):
    device_id: UUID
    installation_id: UUID
    enrolled_at: datetime
    baseline_date: date | None
    baseline_observed_at: datetime | None
    baseline_steps: int | None
    ready: bool
    metric_baselines: dict = Field(default_factory=dict)


class EnrolResult(DTO):
    request_id: UUID
    device: DeviceDTO


class DayResult(DTO):
    game_date: date
    available: bool
    baseline_established: bool = False
    newly_eligible_steps: int
    water_steps: int
    credited_steps: int
    rule_version: str
    activity_credit_id: UUID | None = None
    metrics: dict = Field(default_factory=dict)


class SyncResult(DTO):
    request_id: UUID
    accepted_at: datetime
    device: DeviceDTO
    days: list[DayResult]
    garden: GardenDTO
    activity_steps: str
    first_maturity_count: int
    recap_id: UUID | None
    workouts: list[dict] = Field(default_factory=list)
    activity_metrics: dict = Field(default_factory=dict)


class ActivityStatus(DTO):
    server_time: datetime
    game_timezone: str
    supported_metrics: list[str]
    reconciliation_days: int
    queued_upload_max_age_days: int
    device: DeviceDTO | None
    activity_steps: str
    first_maturity_count: int
    last_sync_at: datetime | None
    activity_metrics: dict = Field(default_factory=dict)


class AcknowledgeRecap(DTO):
    request_id: UUID


class RecapDTO(DTO):
    recap_id: UUID
    created_at: datetime
    payload: dict


class RecapList(DTO):
    recaps: list[RecapDTO]
    next_cursor: UUID | None


class RecapAcknowledgement(DTO):
    request_id: UUID
    recap_id: UUID
    acknowledged_at: datetime
