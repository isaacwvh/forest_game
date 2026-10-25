from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import Field, model_validator

from forest_api.calculations import Definition, VisitorCurve
from forest_api.schemas import DTO


class VisitorRuleDefinition(Definition):
    skill_policy_version: str = Field(default="b8-caps-v1", min_length=1, max_length=100)
    curve: VisitorCurve
    # Slot grid must remain stable across rule versions.
    slot_seconds: Literal[30] = 30
    lease_seconds: int = Field(default=45, ge=30, le=120)
    heartbeat_seconds: int = Field(default=10, ge=5, le=15)
    opportunity_seconds: int = Field(default=20, ge=15, le=25)
    gap_slots: int = Field(default=3, ge=1, le=20)
    tokens_per_visit: int = Field(default=1, ge=1, le=1_000_000)
    tutorial_first_visitor: bool = False

    @model_validator(mode="after")
    def timing(self):
        if self.curve.slot_seconds != 30:
            raise ValueError("Visitor slots use the stable 30-second grid")
        if self.opportunity_seconds < self.heartbeat_seconds + 5:
            raise ValueError("Opportunity lifetime must allow a fair presentation window")
        if self.lease_seconds < self.heartbeat_seconds + self.opportunity_seconds:
            raise ValueError("Lease must cover heartbeat delay and opportunity presentation")
        return self


class VisitorRequest(DTO):
    request_id: UUID


class StartVisitorSession(VisitorRequest):
    installation_id: UUID


class SessionVisitorRequest(StartVisitorSession):
    pass


class VisitorOpportunityDTO(DTO):
    opportunity_id: UUID
    session_id: UUID
    issued_at: datetime
    expires_at: datetime
    visual_key: Literal["forest-butterfly-v1"] = "forest-butterfly-v1"
    tokens: str


class VisitorSessionDTO(DTO):
    session_id: UUID
    installation_id: UUID
    lease_expires_at: datetime


class VisitorSummary(DTO):
    garden_id: UUID
    server_time: datetime
    version: int
    context_id: UUID
    rule_version: str
    is_fixture: bool
    total_attraction_micro_units: str
    sources: list[dict]
    stored_visits_micro_units: str
    claimable_visits: str
    capacity: int
    offline_visits_per_hour: str
    seconds_until_full: int | None
    token_balance: str
    economy_version: int = 0
    hosted_active: str
    hosted_offline: str
    hosted_total: str
    heartbeat_seconds: int
    session: VisitorSessionDTO | None
    opportunities: list[VisitorOpportunityDTO]


class VisitorRewardResult(DTO):
    request_id: UUID
    event_id: UUID | None
    visits: str
    tokens: str
    summary: VisitorSummary
