"""Additive account progression contracts. All large quantities use decimal strings."""

from datetime import datetime

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
