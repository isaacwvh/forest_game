"""Permanent milestone policy, progress and earned rewards; never compact these facts."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    Index,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class MilestonePolicy(Base):
    __tablename__ = "milestone_policies"
    __table_args__ = (
        Index("uq_milestone_policy_active", "active", unique=True, postgresql_where=text("active")),
    )
    version: Mapped[str] = mapped_column(String(64), primary_key=True)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    active: Mapped[bool] = mapped_column(Boolean)
    definition: Mapped[dict] = mapped_column(JSONB)


class MilestoneState(Base):
    __tablename__ = "milestone_state"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    policy_version: Mapped[str] = mapped_column(ForeignKey("milestone_policies.version"))
    enrolled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    progress: Mapped[dict] = mapped_column(JSONB, default=dict)


class MilestoneDay(Base):
    __tablename__ = "milestone_days"
    __table_args__ = (CheckConstraint("steps >= 0", name="steps"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    steps: Mapped[int] = mapped_column(BigInteger)
    workout_minutes: Mapped[str] = mapped_column(Text)
    active: Mapped[bool] = mapped_column(Boolean)


class MilestoneSpecies(Base):
    __tablename__ = "milestone_species"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    species_id: Mapped[str] = mapped_column(ForeignKey("plant_species.id"), primary_key=True)
    rarity: Mapped[str] = mapped_column(String(32))


class MilestoneEntitlement(Base):
    __tablename__ = "milestone_entitlements"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    milestone_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    policy_version: Mapped[str] = mapped_column(ForeignKey("milestone_policies.version"))
    earned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    definition: Mapped[dict] = mapped_column(JSONB)
    superseded_by: Mapped[str | None] = mapped_column(String(64))
    legacy_id: Mapped[str | None] = mapped_column(String(100))


class MilestoneBonusGrant(Base):
    __tablename__ = "milestone_bonus_grants"
    __table_args__ = (CheckConstraint("amount > 0", name="amount"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    milestone_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    amount: Mapped[int] = mapped_column(BigInteger)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class MilestoneEvent(Base):
    __tablename__ = "milestone_events"
    event_id: Mapped[str] = mapped_column(String(32), primary_key=True)
    policy_version: Mapped[str] = mapped_column(ForeignKey("milestone_policies.version"))
    name: Mapped[str] = mapped_column(String(100))
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    claim_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    definition: Mapped[dict] = mapped_column(JSONB)


class MilestoneEventState(Base):
    __tablename__ = "milestone_event_state"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    event_id: Mapped[str] = mapped_column(ForeignKey("milestone_events.event_id"), primary_key=True)
    progress: Mapped[dict] = mapped_column(JSONB, default=dict)
