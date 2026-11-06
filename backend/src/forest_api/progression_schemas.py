"""Additive account progression contracts. All large quantities use decimal strings."""

from datetime import datetime
from uuid import UUID

from forest_api.schemas import DTO, UserDTO


class ProgressionSnapshot(DTO):
    rules_version: str
    version: int
    lifetime_recorded_steps: str
    step_xp: str
    total_xp: str
    level: int
    xp_into_level: str
    xp_for_next_level: str
    steps_into_next_gem: int
    steps_per_gem: int
    steps_to_next_gem: int
    plants_grown_to_adulthood: str
    last_sync_at: datetime | None


class AccountWallet(DTO):
    economy_version: int
    token_balance: str
    gem_balance: str
    lifetime_gems_earned: str
    initialized: bool
    hosted_active: str
    hosted_offline: str
    hosted_total: str


class AccountSummary(DTO):
    server_time: datetime
    profile: UserDTO
    progression: ProgressionSnapshot
    wallet: AccountWallet
    benefits: "LevelBenefitsSnapshot | None" = None
    level_up_notice: "LevelUpNoticeDTO | None" = None


class LevelBenefitsSnapshot(DTO):
    policy_version: str
    progression_version: int
    garden_state_version: int
    level: int
    base_offline_capacity: int
    effective_offline_capacity: int
    maximum_offline_capacity: int
    plant_limit: int
    planted_limit: int
    next_base_increase: int
    next_plant_level: int | None
    next_plant_limit: int | None


class LevelUpNoticeDTO(DTO):
    id: UUID
    policy_version: str
    from_level: int
    to_level: int
    base_offline_before: int
    base_offline_after: int
    effective_offline_after: int
    plant_limit_before: int
    plant_limit_after: int


class ClaimLevelUp(DTO):
    request_id: UUID
    installation_id: UUID


class LevelUpClaimResult(DTO):
    notice: LevelUpNoticeDTO
    may_present: bool


AccountSummary.model_rebuild()
