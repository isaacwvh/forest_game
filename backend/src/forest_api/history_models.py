"""Compact accounting summaries and shared, temporary growth provenance."""

from datetime import date
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, Date, ForeignKey, String
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class VisitorDaySummary(Base):
    __tablename__ = "visitor_day_summaries"
    __table_args__ = (
        CheckConstraint("microseconds >= 0 AND visits >= 0 AND tokens >= 0", name="amounts"),
    )
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    rule_version: Mapped[str] = mapped_column(ForeignKey("visitor_rules.version"), primary_key=True)
    kind: Mapped[str] = mapped_column(String(32), primary_key=True)
    microseconds: Mapped[int] = mapped_column(BigInteger, default=0)
    generated: Mapped[dict] = mapped_column(JSONB, default=dict)
    discarded: Mapped[dict] = mapped_column(JSONB, default=dict)
    visits: Mapped[int] = mapped_column(BigInteger, default=0)
    tokens: Mapped[int] = mapped_column(BigInteger, default=0)


class GrowthProvenance(Base):
    __tablename__ = "growth_provenance"
    id: Mapped[str] = mapped_column(String(64), primary_key=True)
    payload: Mapped[dict] = mapped_column(JSONB)


class GrowthDaySummary(Base):
    __tablename__ = "growth_day_summaries"
    __table_args__ = (CheckConstraint("awarded >= 0 AND credit_count > 0", name="amounts"),)
    plant_id: Mapped[UUID] = mapped_column(ForeignKey("owned_plants.id"), primary_key=True)
    day: Mapped[date] = mapped_column(Date, primary_key=True)
    rule_version: Mapped[str] = mapped_column(
        ForeignKey("economy_configs.version"), primary_key=True
    )
    profile_key: Mapped[str] = mapped_column(String(64), primary_key=True)
    profiles: Mapped[dict] = mapped_column(JSONB)
    awarded: Mapped[int] = mapped_column(BigInteger)
    skill_bonus: Mapped[int] = mapped_column(BigInteger)
    credit_count: Mapped[int] = mapped_column(BigInteger)
