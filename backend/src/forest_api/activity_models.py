"""Per-metric watermarks and durable recorded-workout provenance."""

from datetime import date, datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, Date, DateTime, ForeignKey, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class MetricDay(Base):
    __tablename__ = "activity_metric_days"
    __table_args__ = (
        CheckConstraint(
            "baseline >= 0 AND baseline_credit >= 0 AND credited >= 0", name="quantities"
        ),
        CheckConstraint("observed IS NULL OR observed >= 0", name="observed"),
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    metric: Mapped[str] = mapped_column(String(100), primary_key=True)
    device_id: Mapped[UUID] = mapped_column(ForeignKey("activity_devices.id"))
    rule_version: Mapped[str] = mapped_column(ForeignKey("economy_configs.version"))
    baseline: Mapped[int] = mapped_column(BigInteger, default=0)
    baseline_credit: Mapped[int] = mapped_column(BigInteger, default=0)
    credited: Mapped[int] = mapped_column(BigInteger, default=0)
    observed: Mapped[int | None] = mapped_column(BigInteger)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class WorkoutImport(Base):
    __tablename__ = "activity_workouts"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    workout_id: Mapped[UUID] = mapped_column(primary_key=True)
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    payload: Mapped[dict] = mapped_column(JSONB)
    outcome: Mapped[str] = mapped_column(String(40))


class WorkoutDay(Base):
    __tablename__ = "activity_workout_days"
    __table_args__ = (CheckConstraint("credited_microseconds >= 0", name="quantity"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    rule_version: Mapped[str] = mapped_column(ForeignKey("economy_configs.version"))
    covered_intervals: Mapped[list] = mapped_column(JSONB, default=list)
    credited_microseconds: Mapped[int] = mapped_column(BigInteger, default=0)
    remainder: Mapped[dict] = mapped_column(JSONB, default=dict)


class MilestoneClaim(Base):
    __tablename__ = "milestone_claims"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    milestone_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    claimed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    reward_tokens: Mapped[int] = mapped_column(BigInteger)
    receipt: Mapped[dict] = mapped_column(JSONB)
