"""Durable, bounded daily context for activity-dependent garden skills."""

from datetime import date
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, Date, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class DailySkillActivity(Base):
    __tablename__ = "daily_skill_activity"
    __table_args__ = (CheckConstraint("flights >= 0", name="flights"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    flights: Mapped[int] = mapped_column(BigInteger)
