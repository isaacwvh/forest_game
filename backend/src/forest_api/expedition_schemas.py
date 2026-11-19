"""UTC date evidence is deliberately independent of local-day growth uploads."""

from datetime import date
from uuid import UUID

from pydantic import AwareDatetime, Field, model_validator

from forest_api.activity_schemas import WorkoutInput
from forest_api.schemas import DTO


class EvidenceDay(DTO):
    game_date: date
    starts_at: AwareDatetime
    through: AwareDatetime
    steps: int | None = Field(default=None, strict=True, ge=0, le=1_000_000_000)
    workouts_complete: bool = False


class ExpeditionEvidence(DTO):
    schema_version: int = Field(default=1, strict=True, ge=1, le=1)
    request_id: UUID
    device_id: UUID
    installation_id: UUID
    observed_at: AwareDatetime
    days: list[EvidenceDay] = Field(min_length=1, max_length=7)
    workouts: list[WorkoutInput] = Field(default_factory=list, max_length=500)

    @model_validator(mode="after")
    def bounded(self):
        if len({d.game_date for d in self.days}) != len(self.days):
            raise ValueError("Duplicate UTC dates")
        if len({w.workout_id for w in self.workouts}) != len(self.workouts):
            raise ValueError("Duplicate workout identities")
        if sum(len(w.segments) for w in self.workouts) > 2000:
            raise ValueError("Split uploads into at most 2000 segments")
        return self
