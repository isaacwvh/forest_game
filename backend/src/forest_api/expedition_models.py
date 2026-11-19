"""Permanent UTC expedition identities, evidence, rewards and step-triggered grants."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    String,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class ExpeditionTemplate(Base):
    __tablename__ = "expedition_templates"
    version: Mapped[str] = mapped_column(String(100), primary_key=True)
    definition: Mapped[dict] = mapped_column(JSONB)
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ExpeditionSchedule(Base):
    __tablename__ = "expedition_schedule"
    month: Mapped[date] = mapped_column(Date, primary_key=True)
    template_version: Mapped[str] = mapped_column(ForeignKey("expedition_templates.version"))
    published_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ExpeditionLaunch(Base):
    """Optional first partial month; later calendar runs ignore this cutoff."""

    __tablename__ = "expedition_launches"
    __table_args__ = (
        CheckConstraint(
            "starts_at >= (month::timestamp AT TIME ZONE 'UTC') AND "
            "starts_at < ((month + INTERVAL '1 month') AT TIME ZONE 'UTC')",
            name="interval",
        ),
    )
    month: Mapped[date] = mapped_column(ForeignKey("expedition_schedule.month"), primary_key=True)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ExpeditionRun(Base):
    __tablename__ = "expedition_runs"
    __table_args__ = (UniqueConstraint("owner_id", "month"), UniqueConstraint("id", "owner_id"))
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    month: Mapped[date] = mapped_column(Date)
    template_version: Mapped[str] = mapped_column(ForeignKey("expedition_templates.version"))
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ends_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    evidence_until: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    progress_version: Mapped[int] = mapped_column(BigInteger, default=0)
    progress: Mapped[dict] = mapped_column(JSONB, default=dict)
    contributions: Mapped[dict] = mapped_column(JSONB, default=dict)


class ExpeditionDay(Base):
    __tablename__ = "expedition_days"
    __table_args__ = (CheckConstraint("steps >= 0", name="steps"),)
    run_id: Mapped[UUID] = mapped_column(ForeignKey("expedition_runs.id"), primary_key=True)
    device_id: Mapped[UUID] = mapped_column(ForeignKey("activity_devices.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    starts_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    steps: Mapped[int] = mapped_column(BigInteger, default=0)
    steps_through: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    workouts_through: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class ExpeditionWorkout(Base):
    __tablename__ = "expedition_workouts"
    run_id: Mapped[UUID] = mapped_column(ForeignKey("expedition_runs.id"), primary_key=True)
    workout_id: Mapped[UUID] = mapped_column(primary_key=True)
    payload: Mapped[dict] = mapped_column(JSONB)
    intervals: Mapped[list] = mapped_column(JSONB)
    outcome: Mapped[str] = mapped_column(String(64))


class ExpeditionEntitlement(Base):
    __tablename__ = "expedition_entitlements"
    __table_args__ = (UniqueConstraint("run_id", "reward_key"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    run_id: Mapped[UUID] = mapped_column(ForeignKey("expedition_runs.id"), index=True)
    reward_key: Mapped[str] = mapped_column(String(100))
    earned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    reward: Mapped[dict] = mapped_column(JSONB)


class ExpeditionClaim(Base):
    __tablename__ = "expedition_claims"
    entitlement_id: Mapped[UUID] = mapped_column(
        ForeignKey("expedition_entitlements.id"), primary_key=True
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    receipt: Mapped[dict] = mapped_column(JSONB)


class ExpeditionBonusGrant(Base):
    __tablename__ = "expedition_bonus_grants"
    __table_args__ = (CheckConstraint("amount > 0", name="amount"),)
    entitlement_id: Mapped[UUID] = mapped_column(
        ForeignKey("expedition_entitlements.id"), primary_key=True
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    amount: Mapped[int] = mapped_column(BigInteger)


class ItemStepState(Base):
    __tablename__ = "item_step_state"
    __table_args__ = (CheckConstraint("steps >= 0", name="steps"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    family: Mapped[str] = mapped_column(String(100), primary_key=True)
    steps: Mapped[int] = mapped_column(BigInteger, default=0)


class ItemStepGrant(Base):
    __tablename__ = "item_step_grants"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    family: Mapped[str] = mapped_column(String(100), primary_key=True)
    tier: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    boundary: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    provenance: Mapped[dict] = mapped_column(JSONB)
