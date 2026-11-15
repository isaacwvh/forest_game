"""Separate item copies, permanent acquisition identity and durable commerce facts."""

from datetime import datetime
from decimal import Decimal
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from forest_api.models import Base


class ItemDefinition(Base):
    __tablename__ = "item_definitions"
    __table_args__ = (
        CheckConstraint("version > 0", name="version"),
        CheckConstraint(
            "clearance_radius > 0 AND clearance_radius <> 'NaN'::numeric", name="radius"
        ),
        CheckConstraint("rarity IN ('common', 'rare', 'epic', 'legendary')", name="rarity"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    display_name: Mapped[str] = mapped_column(String(100))
    description: Mapped[str] = mapped_column(Text)
    rarity: Mapped[str] = mapped_column(String(32))
    asset_version: Mapped[str] = mapped_column(String(100))
    model_key: Mapped[str] = mapped_column(Text)
    thumbnail_key: Mapped[str] = mapped_column(Text)
    clearance_radius: Mapped[Decimal] = mapped_column(Numeric(9, 3))


class ItemIdentity(Base):
    __tablename__ = "item_identities"
    __table_args__ = (
        UniqueConstraint("id", "owner_id"),
        UniqueConstraint("owner_id", "source", "reference", "ordinal"),
        CheckConstraint("ordinal >= 0", name="ordinal"),
        ForeignKeyConstraint(
            ["item_id", "item_version"], ["item_definitions.id", "item_definitions.version"]
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    item_id: Mapped[str] = mapped_column(String(100))
    item_version: Mapped[int] = mapped_column(Integer)
    source: Mapped[str] = mapped_column(String(64))
    reference: Mapped[str] = mapped_column(String(255))
    ordinal: Mapped[int] = mapped_column(Integer)
    acquired_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class OwnedItem(Base):
    __tablename__ = "owned_items"
    __table_args__ = (
        ForeignKeyConstraint(
            ["id", "owner_id"], ["item_identities.id", "item_identities.owner_id"]
        ),
        UniqueConstraint("id", "owner_id"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)


class ItemPlacement(Base):
    __tablename__ = "item_placements"
    __table_args__ = (
        ForeignKeyConstraint(["item_id", "owner_id"], ["owned_items.id", "owned_items.owner_id"]),
        ForeignKeyConstraint(["garden_id", "owner_id"], ["gardens.id", "gardens.owner_id"]),
        CheckConstraint("x >= 0 AND x <> 'NaN'::numeric", name="x"),
        CheckConstraint("y >= 0 AND y <> 'NaN'::numeric", name="y"),
        CheckConstraint("rotation_degrees >= 0 AND rotation_degrees < 360", name="rotation"),
    )
    item_id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column()
    garden_id: Mapped[UUID] = mapped_column(index=True)
    x: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    y: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    rotation_degrees: Mapped[Decimal] = mapped_column(Numeric(5, 2))


class ItemValueDefinition(Base):
    __tablename__ = "item_value_definitions"
    __table_args__ = (
        ForeignKeyConstraint(
            ["item_id", "item_version"], ["item_definitions.id", "item_definitions.version"]
        ),
        CheckConstraint("token_value >= 4 AND resale_basis_points = 2500", name="value"),
    )
    item_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    item_version: Mapped[int] = mapped_column(Integer, primary_key=True)
    valuation_version: Mapped[str] = mapped_column(String(100))
    token_value: Mapped[int] = mapped_column(BigInteger)
    resale_basis_points: Mapped[int] = mapped_column(Integer)


class ItemValuation(Base):
    __tablename__ = "item_valuations"
    __table_args__ = (
        CheckConstraint("token_value >= 4 AND resale_basis_points = 2500", name="value"),
    )
    owned_item_id: Mapped[UUID] = mapped_column(ForeignKey("item_identities.id"), primary_key=True)
    valuation_version: Mapped[str] = mapped_column(String(100))
    token_value: Mapped[int] = mapped_column(BigInteger)
    resale_basis_points: Mapped[int] = mapped_column(Integer)


class ItemShopOffer(Base):
    __tablename__ = "item_shop_offers"
    __table_args__ = (
        ForeignKeyConstraint(
            ["item_id", "item_version"],
            ["item_value_definitions.item_id", "item_value_definitions.item_version"],
        ),
        CheckConstraint("version > 0 AND token_cost >= 4", name="value"),
        Index("uq_item_shop_active_offer", "id", unique=True, postgresql_where=text("active")),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    item_id: Mapped[str] = mapped_column(String(100))
    item_version: Mapped[int] = mapped_column(Integer)
    token_cost: Mapped[int] = mapped_column(BigInteger)
    active: Mapped[bool] = mapped_column(Boolean, server_default="true")


class ItemSale(Base):
    __tablename__ = "item_sales"
    __table_args__ = (
        ForeignKeyConstraint(
            ["owned_item_id", "owner_id"], ["item_identities.id", "item_identities.owner_id"]
        ),
        UniqueConstraint("owner_id", "request_id"),
        CheckConstraint("tokens > 0", name="tokens"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    owned_item_id: Mapped[UUID] = mapped_column(unique=True)
    request_id: Mapped[UUID] = mapped_column()
    payload_hash: Mapped[str] = mapped_column(String(64))
    tokens: Mapped[int] = mapped_column(BigInteger)
    receipt: Mapped[dict] = mapped_column(JSONB)
    sold_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
