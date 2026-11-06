"""Permanent step-earned gem grants; independent of expiring response/recap payloads."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import BigInteger, CheckConstraint, DateTime, ForeignKey, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import JSONB
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


class LevelBenefitsPolicy(Base):
    __tablename__ = "level_benefits_policy"
    version: Mapped[str] = mapped_column(String(64), primary_key=True)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AccountLevelState(Base):
    __tablename__ = "account_level_state"
    __table_args__ = (
        CheckConstraint("reached_level >= presented_level AND presented_level >= 1", name="levels"),
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    reached_level: Mapped[int] = mapped_column(BigInteger)
    presented_level: Mapped[int] = mapped_column(BigInteger)


class LevelUpNotice(Base):
    __tablename__ = "level_up_notices"
    __table_args__ = (
        UniqueConstraint("owner_id", "source_id", name="uq_level_notice_source"),
        UniqueConstraint("owner_id", "claim_id", name="uq_level_notice_claim"),
        CheckConstraint("from_level >= 1 AND to_level > from_level", name="levels"),
        CheckConstraint(
            "(consumed_at IS NULL AND claim_id IS NULL AND installation_id IS NULL) OR "
            "(consumed_at IS NOT NULL AND claim_id IS NOT NULL AND installation_id IS NOT NULL)",
            name="claim",
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    source_id: Mapped[UUID] = mapped_column()
    from_level: Mapped[int] = mapped_column(BigInteger)
    to_level: Mapped[int] = mapped_column(BigInteger)
    payload: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    claim_id: Mapped[UUID | None] = mapped_column()
    installation_id: Mapped[UUID | None] = mapped_column()
