"""Permanent step-earned gem grants; independent of expiring response/recap payloads."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class GemGrant(Base):
    __tablename__ = "gem_grants"
    __table_args__ = (
        UniqueConstraint("owner_id", "source_id", name="uq_gem_grants_source"),
        UniqueConstraint("owner_id", "end_milestone", name="uq_gem_grants_milestone"),
        CheckConstraint(
            "start_milestone >= 0 AND end_milestone > start_milestone "
            "AND amount = end_milestone - start_milestone",
            name="amounts",
        ),
        CheckConstraint("kind IN ('steps', 'backfill')", name="kind"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    source_id: Mapped[UUID] = mapped_column()
    kind: Mapped[str] = mapped_column(String(16))
    rules_version: Mapped[str] = mapped_column(String(64))
    start_milestone: Mapped[int] = mapped_column(BigInteger)
    end_milestone: Mapped[int] = mapped_column(BigInteger)
    amount: Mapped[int] = mapped_column(BigInteger)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
