"""B7 immutable pack contracts and account-scoped economic receipts.

All writers serialize on users first, then gardens/catalogue as in B6. Token
balance remains visitor_wallets.tokens; collection_events is its spending ledger.
"""

from datetime import datetime
from uuid import UUID

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    String,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base, profile_foreign_keys


class PackDefinition(Base):
    __tablename__ = "pack_definitions"
    __table_args__ = (CheckConstraint("version > 0", name="version"),)
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    is_fixture: Mapped[bool] = mapped_column(Boolean)
    definition: Mapped[dict] = mapped_column(JSONB)


class ExchangeOffer(Base):
    __tablename__ = "exchange_offers"
    __table_args__ = (
        ForeignKeyConstraint(
            ["pack_id", "pack_version"], ["pack_definitions.id", "pack_definitions.version"]
        ),
        CheckConstraint("version > 0 AND token_cost > 0", name="amounts"),
        Index("uq_exchange_active_offer", "id", unique=True, postgresql_where=text("active")),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    pack_id: Mapped[str] = mapped_column(String(100))
    pack_version: Mapped[int] = mapped_column(Integer)
    token_cost: Mapped[int] = mapped_column(BigInteger)
    active: Mapped[bool] = mapped_column(Boolean, default=True)


class PackMember(Base):
    """Relational retention guards for the immutable JSON sampling contract."""

    __tablename__ = "pack_members"
    __table_args__ = (
        ForeignKeyConstraint(
            ["pack_id", "pack_version"], ["pack_definitions.id", "pack_definitions.version"]
        ),
        ForeignKeyConstraint(
            ["species_id", "variant_id"], ["plant_variants.species_id", "plant_variants.variant_id"]
        ),
        *profile_foreign_keys(),
    )
    pack_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    pack_version: Mapped[int] = mapped_column(Integer, primary_key=True)
    species_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    variant_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    growth_profile_id: Mapped[str] = mapped_column(String(100))
    growth_profile_version: Mapped[int] = mapped_column(Integer)
    behaviour_profile_id: Mapped[str] = mapped_column(String(100))
    behaviour_profile_version: Mapped[int] = mapped_column(Integer)
    attraction_profile_id: Mapped[str] = mapped_column(String(100))
    attraction_profile_version: Mapped[int] = mapped_column(Integer)


class CollectionEvent(Base):
    __tablename__ = "collection_events"
    __table_args__ = (
        UniqueConstraint("owner_id", "request_id"),
        CheckConstraint("token_delta <= 0", name="token_delta"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    request_id: Mapped[UUID] = mapped_column()
    operation: Mapped[str] = mapped_column(String(100))
    payload_hash: Mapped[str] = mapped_column(String(64))
    token_delta: Mapped[int] = mapped_column(BigInteger)
    receipt: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class OwnedPack(Base):
    __tablename__ = "owned_packs"
    __table_args__ = (
        ForeignKeyConstraint(
            ["pack_id", "pack_version"], ["pack_definitions.id", "pack_definitions.version"]
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    pack_id: Mapped[str] = mapped_column(String(100))
    pack_version: Mapped[int] = mapped_column(Integer)
    exchange_id: Mapped[UUID] = mapped_column(ForeignKey("collection_events.id"), index=True)
    acquired_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PackOpening(Base):
    __tablename__ = "pack_openings"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    pack_id: Mapped[UUID] = mapped_column(ForeignKey("owned_packs.id"), unique=True)
    event_id: Mapped[UUID] = mapped_column(ForeignKey("collection_events.id"), unique=True)
    plant_id: Mapped[UUID] = mapped_column(ForeignKey("owned_plants.id"), unique=True)
    rarity: Mapped[str] = mapped_column(String(32))
    opened_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
