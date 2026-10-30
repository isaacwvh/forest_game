"""Durable B6 state. All writers lock user -> garden -> visitor state -> wallet."""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    String,
    UniqueConstraint,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class VisitorRules(Base):
    __tablename__ = "visitor_rules"
    version: Mapped[str] = mapped_column(String(100), primary_key=True)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), unique=True, index=True)
    is_fixture: Mapped[bool] = mapped_column(Boolean)
    rules: Mapped[dict] = mapped_column(JSONB)


class VisitorControl(Base):
    """One control high-water mark per account, independent of arrival cursors."""

    __tablename__ = "visitor_controls"
    __table_args__ = (CheckConstraint("sequence >= 0", name="sequence"),)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    sequence: Mapped[int] = mapped_column(BigInteger, default=0)
    request_id: Mapped[UUID | None] = mapped_column()
    operation: Mapped[str | None] = mapped_column(String(100))
    payload_hash: Mapped[str | None] = mapped_column(String(64))
    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class VisitorContext(Base):
    __tablename__ = "visitor_contexts"
    __table_args__ = (Index("ix_visitor_contexts_effective_at", "effective_at"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), index=True)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    rule_version: Mapped[str] = mapped_column(ForeignKey("visitor_rules.version"))
    snapshot: Mapped[dict] = mapped_column(JSONB)


class VisitorState(Base):
    __tablename__ = "garden_visitor_state"
    __table_args__ = (
        CheckConstraint("stored_whole >= 0 AND version >= 0 AND gap_slots >= 0", name="amounts"),
    )
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), primary_key=True)
    settled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    context_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_contexts.id"))
    stored_whole: Mapped[int] = mapped_column(BigInteger, default=0)
    remainder: Mapped[dict] = mapped_column(JSONB, default=dict)
    last_slot: Mapped[int] = mapped_column(BigInteger)
    gap_slots: Mapped[int] = mapped_column(Integer, default=0)
    version: Mapped[int] = mapped_column(BigInteger, default=0)
    ever_issued: Mapped[bool] = mapped_column(Boolean, default=False, server_default="false")


class VisitorStorageLot(Base):
    __tablename__ = "visitor_storage_lots"
    __table_args__ = (CheckConstraint("visits >= 0 AND tokens_per_visit > 0", name="amounts"),)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), primary_key=True)
    rule_version: Mapped[str] = mapped_column(ForeignKey("visitor_rules.version"), primary_key=True)
    visits: Mapped[int] = mapped_column(BigInteger)
    tokens_per_visit: Mapped[int] = mapped_column(BigInteger)


class VisitorSession(Base):
    __tablename__ = "visitor_sessions"
    __table_args__ = (
        Index("ix_visitor_sessions_ended_at", "ended_at"),
        CheckConstraint(
            "lease_expires_at >= started_at AND (ended_at IS NULL OR ended_at >= started_at)",
            name="interval",
        ),
        Index(
            "uq_visitor_active_owner",
            "owner_id",
            unique=True,
            postgresql_where=text("ended_at IS NULL"),
        ),
        Index(
            "uq_visitor_active_garden",
            "garden_id",
            unique=True,
            postgresql_where=text("ended_at IS NULL"),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), index=True)
    installation_id: Mapped[UUID] = mapped_column()
    started_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    lease_expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    arrival_protocol: Mapped[int] = mapped_column(Integer, default=1, server_default="1")


class VisitorSettlement(Base):
    __tablename__ = "visitor_settlements"
    __table_args__ = (
        Index("ix_visitor_settlements_end_at", "end_at"),
        UniqueConstraint("garden_id", "start_at"),
        CheckConstraint("end_at > start_at", name="interval"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), index=True)
    context_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_contexts.id"))
    start_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    end_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    mode: Mapped[str] = mapped_column(String(16))
    detail: Mapped[dict] = mapped_column(JSONB)


class VisitorOpportunity(Base):
    __tablename__ = "visitor_opportunities"
    __table_args__ = (
        UniqueConstraint("garden_id", "slot"),
        CheckConstraint(
            "tokens > 0 AND status IN ('issued', 'welcomed', 'expired')", name="status_reward"
        ),
        Index(
            "ix_visitor_pending",
            "garden_id",
            "expires_at",
            postgresql_where=text("status = 'issued'"),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), index=True)
    session_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_sessions.id"))
    context_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_contexts.id"))
    slot: Mapped[int] = mapped_column(BigInteger)
    issued_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    rule_version: Mapped[str] = mapped_column(ForeignKey("visitor_rules.version"))
    tokens: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[str] = mapped_column(String(16))
    # The original receipt also handles another request UUID for the same welcome.
    result: Mapped[dict | None] = mapped_column(JSONB)


class VisitorWallet(Base):
    __tablename__ = "visitor_wallets"
    __table_args__ = (
        CheckConstraint(
            "tokens >= 0 AND hosted_active >= 0 AND hosted_offline >= 0", name="amounts"
        ),
        CheckConstraint("economy_version >= 0", name="economy_version"),
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    tokens: Mapped[int] = mapped_column(BigInteger, default=0)
    economy_version: Mapped[int] = mapped_column(BigInteger, server_default="0")
    hosted_active: Mapped[int] = mapped_column(BigInteger, default=0)
    hosted_offline: Mapped[int] = mapped_column(BigInteger, default=0)


class VisitorRewardEvent(Base):
    __tablename__ = "visitor_reward_events"
    __table_args__ = (
        UniqueConstraint("owner_id", "kind", "source_id"),
        Index(
            "ix_visitor_reward_events_pending_summary",
            "created_at",
            postgresql_where=text(
                "summarized_at IS NULL AND kind IN ('active_welcome', 'offline_claim')"
            ),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    kind: Mapped[str] = mapped_column(String(32))
    source_id: Mapped[UUID] = mapped_column()
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    detail: Mapped[dict] = mapped_column(JSONB)
    receipt: Mapped[dict | None] = mapped_column(JSONB(none_as_null=True))
    summarized_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class VisitorWalletEntry(Base):
    __tablename__ = "visitor_wallet_entries"
    __table_args__ = (CheckConstraint("amount > 0", name="amount"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    event_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_reward_events.id"), unique=True)
    amount: Mapped[int] = mapped_column(BigInteger)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class VisitorThrottle(Base):
    __tablename__ = "visitor_throttles"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    window_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    requests: Mapped[int] = mapped_column(Integer)


class VisitorSchedule(Base):
    __tablename__ = "visitor_schedules"
    __table_args__ = (CheckConstraint("sequence >= 0", name="sequence"),)
    garden_id: Mapped[UUID] = mapped_column(ForeignKey("gardens.id"), primary_key=True)
    context_id: Mapped[UUID] = mapped_column(ForeignKey("visitor_contexts.id"))
    next_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    remaining: Mapped[dict] = mapped_column(JSONB, default=dict)
    sequence: Mapped[int] = mapped_column(BigInteger, default=0)
    tutorial_used: Mapped[bool] = mapped_column(Boolean, default=False)


class VisitorEconomyConversion(Base):
    __tablename__ = "visitor_economy_conversions"
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    version: Mapped[str] = mapped_column(String(100), primary_key=True)
    converted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    detail: Mapped[dict] = mapped_column(JSONB)
