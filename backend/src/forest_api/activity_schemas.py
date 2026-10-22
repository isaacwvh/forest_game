"""Steps-first wire contract. Unimplemented metrics are rejected, never ignored."""

from datetime import date, datetime
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


class EnrolActivity(Observation):
    request_id: UUID
    installation_id: UUID
    # Replacing a device requires compare-and-swap; a sync cannot replace one.
    expected_device_id: UUID | None = None
    steps: int | None = Field(default=None, strict=True, ge=0, le=1_000_000_000)


class ActivityDayInput(DTO):
    game_date: date
    steps: int | None = Field(strict=True, ge=0, le=1_000_000_000)

    @field_validator("game_date", mode="before")
    @classmethod
    def calendar_date(cls, value):
        if not isinstance(value, (str, date)) or isinstance(value, datetime):
            raise ValueError("Use an ISO calendar date")
        return value


class SyncActivity(Observation):
    request_id: UUID
    installation_id: UUID
    device_id: UUID
    days: list[ActivityDayInput] = Field(min_length=1, max_length=7)

    @model_validator(mode="after")
    def unique_dates(self):
        if len({day.game_date for day in self.days}) != len(self.days):
            raise ValueError("Duplicate game dates")
        return self


class DeviceDTO(DTO):
    device_id: UUID
    installation_id: UUID
    enrolled_at: datetime
    baseline_date: date | None
    baseline_observed_at: datetime | None
    baseline_steps: int | None
    ready: bool


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


class SyncResult(DTO):
    request_id: UUID
    accepted_at: datetime
    device: DeviceDTO
    days: list[DayResult]
    garden: GardenDTO
    activity_steps: str
    first_maturity_count: int
    recap_id: UUID | None


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
