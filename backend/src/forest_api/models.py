"""Relational ownership, immutable configuration and B4/B5 activity accounting."""

from datetime import date, datetime
from decimal import Decimal
from uuid import UUID, uuid4

from sqlalchemy import (
    BigInteger,
    Boolean,
    CheckConstraint,
    Date,
    DateTime,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    MetaData,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    metadata = MetaData(
        naming_convention={
            "ix": "ix_%(table_name)s_%(column_0_name)s",
            "uq": "uq_%(table_name)s_%(column_0_name)s",
            "ck": "ck_%(table_name)s_%(constraint_name)s",
            "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
            "pk": "pk_%(table_name)s",
        }
    )


class Timestamps:
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class User(Timestamps, Base):
    __tablename__ = "users"
    __table_args__ = (
        UniqueConstraint("auth_issuer", "auth_subject"),
        CheckConstraint("username ~ '^[a-z0-9_]{3,32}$'", name="username_format"),
        CheckConstraint("char_length(btrim(display_name)) BETWEEN 1 AND 64", name="display_name"),
        CheckConstraint("status IN ('active', 'disabled')", name="status"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    auth_issuer: Mapped[str] = mapped_column(Text)
    auth_subject: Mapped[str] = mapped_column(String(255))
    username: Mapped[str] = mapped_column(String(32))
    display_name: Mapped[str] = mapped_column(String(64))
    game_timezone: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16), server_default="active")


Index("uq_users_username_normalized", func.lower(User.username), unique=True)


class Garden(Timestamps, Base):
    __tablename__ = "gardens"
    __table_args__ = (
        UniqueConstraint("id", "owner_id"),
        CheckConstraint("width > 0 AND width <> 'NaN'::numeric", name="width"),
        CheckConstraint("depth > 0 AND depth <> 'NaN'::numeric", name="depth"),
        CheckConstraint("visibility IN ('friends', 'private')", name="visibility"),
        CheckConstraint("layout_version >= 0 AND state_version >= 0", name="versions"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), unique=True)
    width: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    depth: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    visibility: Mapped[str] = mapped_column(String(16), server_default="friends")
    layout_version: Mapped[int] = mapped_column(BigInteger, server_default="0")
    state_version: Mapped[int] = mapped_column(BigInteger, server_default="0")


class GrowthProfile(Base):
    __tablename__ = "growth_profiles"
    __table_args__ = (
        CheckConstraint("version > 0", name="version"),
        CheckConstraint("maximum_growth_micro_units > 0", name="maximum"),
        CheckConstraint("jsonb_typeof(thresholds) = 'object'", name="thresholds_object"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    thresholds: Mapped[dict] = mapped_column(JSONB)
    maximum_growth_micro_units: Mapped[int] = mapped_column(BigInteger)


class BehaviourProfile(Base):
    __tablename__ = "growth_rule_profiles"
    __table_args__ = (
        CheckConstraint("version > 0", name="version"),
        CheckConstraint("jsonb_typeof(rules) = 'object'", name="rules_object"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    rules: Mapped[dict] = mapped_column(JSONB)


class AttractionProfile(Base):
    __tablename__ = "attraction_profiles"
    __table_args__ = (
        CheckConstraint("version > 0", name="version"),
        CheckConstraint("jsonb_typeof(stage_attraction) = 'object'", name="stages_object"),
        CheckConstraint("jsonb_typeof(gameplay_tags) = 'array'", name="tags_array"),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    version: Mapped[int] = mapped_column(Integer, primary_key=True)
    stage_attraction: Mapped[dict] = mapped_column(JSONB)
    gameplay_tags: Mapped[list] = mapped_column(JSONB)


def profile_foreign_keys(prefix: str = "") -> tuple:
    return tuple(
        ForeignKeyConstraint(
            [f"{prefix}{kind}_profile_id", f"{prefix}{kind}_profile_version"],
            [f"{table}.id", f"{table}.version"],
        )
        for kind, table in (
            ("growth", "growth_profiles"),
            ("behaviour", "growth_rule_profiles"),
            ("attraction", "attraction_profiles"),
        )
    )


class Species(Base):
    __tablename__ = "plant_species"
    __table_args__ = (
        *profile_foreign_keys(),
        CheckConstraint("rarity ~ '^[a-z][a-z0-9_]{0,31}$'", name="rarity"),
        CheckConstraint(
            "clearance_radius > 0 AND clearance_radius <> 'NaN'::numeric", name="clearance_radius"
        ),
    )
    id: Mapped[str] = mapped_column(String(100), primary_key=True)
    display_name: Mapped[str] = mapped_column(String(100))
    rarity: Mapped[str] = mapped_column(String(32), server_default="development_unbalanced")
    description: Mapped[str] = mapped_column(Text)
    clearance_radius: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    growth_profile_id: Mapped[str] = mapped_column(String(100))
    growth_profile_version: Mapped[int] = mapped_column(Integer)
    behaviour_profile_id: Mapped[str] = mapped_column(String(100))
    behaviour_profile_version: Mapped[int] = mapped_column(Integer)
    attraction_profile_id: Mapped[str] = mapped_column(String(100))
    attraction_profile_version: Mapped[int] = mapped_column(Integer)
    enabled: Mapped[bool] = mapped_column(Boolean)
    is_fixture: Mapped[bool] = mapped_column(Boolean, server_default="false")
    properties: Mapped[dict] = mapped_column(JSONB, server_default="{}")


class Variant(Base):
    __tablename__ = "plant_variants"
    __table_args__ = (
        *profile_foreign_keys(),
        *tuple(
            CheckConstraint(
                f"({kind}_profile_id IS NULL) = ({kind}_profile_version IS NULL)",
                name=f"{kind}_override_pair",
            )
            for kind in ("growth", "behaviour", "attraction")
        ),
    )
    species_id: Mapped[str] = mapped_column(ForeignKey("plant_species.id"), primary_key=True)
    variant_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    display_name: Mapped[str] = mapped_column(String(100))
    description: Mapped[str] = mapped_column(Text)
    # Historical schema-1 packs use this field. New packs use Species.rarity.
    rarity: Mapped[str] = mapped_column(String(32))
    enabled: Mapped[bool] = mapped_column(Boolean)
    asset_catalog_key: Mapped[str] = mapped_column(Text)
    asset_catalog_version: Mapped[str] = mapped_column(String(100))
    growth_profile_id: Mapped[str | None] = mapped_column(String(100))
    growth_profile_version: Mapped[int | None] = mapped_column(Integer)
    behaviour_profile_id: Mapped[str | None] = mapped_column(String(100))
    behaviour_profile_version: Mapped[int | None] = mapped_column(Integer)
    attraction_profile_id: Mapped[str | None] = mapped_column(String(100))
    attraction_profile_version: Mapped[int | None] = mapped_column(Integer)


class PlantStage(Base):
    __tablename__ = "plant_stages"
    __table_args__ = (
        ForeignKeyConstraint(
            ["species_id", "variant_id"], ["plant_variants.species_id", "plant_variants.variant_id"]
        ),
        CheckConstraint("stage IN ('sprout', 'seedling', 'young', 'adult')", name="stage"),
    )
    species_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    variant_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    stage: Mapped[str] = mapped_column(String(16), primary_key=True)
    model_key: Mapped[str] = mapped_column(Text)
    thumbnail_key: Mapped[str] = mapped_column(Text)


class OwnedPlant(Timestamps, Base):
    __tablename__ = "owned_plants"
    __table_args__ = (
        *profile_foreign_keys(),
        ForeignKeyConstraint(
            ["species_id", "variant_id"], ["plant_variants.species_id", "plant_variants.variant_id"]
        ),
        UniqueConstraint("id", "owner_id"),
        UniqueConstraint("owner_id", "acquisition_source", "acquisition_reference"),
        CheckConstraint("growth_micro_units >= 0", name="growth"),
        CheckConstraint("jsonb_typeof(fractional_state) = 'object'", name="fractional_object"),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True, default=uuid4)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    species_id: Mapped[str] = mapped_column(String(100))
    variant_id: Mapped[str] = mapped_column(String(100))
    growth_profile_id: Mapped[str] = mapped_column(String(100))
    growth_profile_version: Mapped[int] = mapped_column(Integer)
    behaviour_profile_id: Mapped[str] = mapped_column(String(100))
    behaviour_profile_version: Mapped[int] = mapped_column(Integer)
    attraction_profile_id: Mapped[str] = mapped_column(String(100))
    attraction_profile_version: Mapped[int] = mapped_column(Integer)
    growth_micro_units: Mapped[int] = mapped_column(BigInteger, server_default="0")
    fractional_state: Mapped[dict] = mapped_column(JSONB, server_default="{}")
    acquisition_source: Mapped[str] = mapped_column(String(64))
    acquisition_reference: Mapped[str] = mapped_column(String(255))
    first_matured_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class CatalogDiscoveryState(Base):
    __tablename__ = "catalog_discovery_state"
    __table_args__ = (CheckConstraint("version >= 0", name="version"),)

    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    version: Mapped[int] = mapped_column(BigInteger, server_default="0")


class CatalogStageDiscovery(Base):
    __tablename__ = "catalog_stage_discoveries"
    __table_args__ = (
        ForeignKeyConstraint(
            ["species_id", "variant_id"], ["plant_variants.species_id", "plant_variants.variant_id"]
        ),
        CheckConstraint("stage IN ('seedling', 'young', 'adult')", name="stage"),
    )

    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    species_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    variant_id: Mapped[str] = mapped_column(String(100), primary_key=True)
    stage: Mapped[str] = mapped_column(String(16), primary_key=True)
    recorded_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )


class GardenPlacement(Base):
    __tablename__ = "garden_placements"
    __table_args__ = (
        ForeignKeyConstraint(
            ["plant_id", "owner_id"], ["owned_plants.id", "owned_plants.owner_id"]
        ),
        ForeignKeyConstraint(["garden_id", "owner_id"], ["gardens.id", "gardens.owner_id"]),
        CheckConstraint("x >= 0 AND x <> 'NaN'::numeric", name="x"),
        CheckConstraint("y >= 0 AND y <> 'NaN'::numeric", name="y"),
        CheckConstraint("rotation_degrees >= 0 AND rotation_degrees < 360", name="rotation"),
    )
    plant_id: Mapped[UUID] = mapped_column(primary_key=True)
    # Redundant key only to enforce owner equality through both composite FKs.
    owner_id: Mapped[UUID] = mapped_column()
    garden_id: Mapped[UUID] = mapped_column(index=True)
    x: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    y: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    rotation_degrees: Mapped[Decimal] = mapped_column(Numeric(5, 2))


class GameCatalogue(Base):
    __tablename__ = "game_catalogue"
    __table_args__ = (
        CheckConstraint("id = 1", name="singleton"),
        CheckConstraint("unit_metres > 0 AND unit_metres <> 'NaN'::numeric", name="unit_metres"),
        CheckConstraint("board_width > 0 AND board_width <> 'NaN'::numeric", name="board_width"),
        CheckConstraint("board_depth > 0 AND board_depth <> 'NaN'::numeric", name="board_depth"),
        ForeignKeyConstraint(
            ["starter_species_id", "starter_variant_id"],
            ["plant_variants.species_id", "plant_variants.variant_id"],
        ),
    )
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    version: Mapped[str] = mapped_column(String(100))
    is_fixture: Mapped[bool] = mapped_column(Boolean)
    unit_metres: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    board_width: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    board_depth: Mapped[Decimal] = mapped_column(Numeric(9, 3))
    starter_species_id: Mapped[str] = mapped_column(String(100))
    starter_variant_id: Mapped[str] = mapped_column(String(100))


class ApiRequest(Base):
    __tablename__ = "api_requests"
    user_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    request_id: Mapped[UUID] = mapped_column(primary_key=True)
    operation: Mapped[str] = mapped_column(String(100))
    payload_hash: Mapped[str] = mapped_column(String(64))
    response: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class EconomyConfig(Base):
    __tablename__ = "economy_configs"
    __table_args__ = (CheckConstraint("jsonb_typeof(rules) = 'object'", name="rules_object"),)
    version: Mapped[str] = mapped_column(String(100), primary_key=True)
    effective_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True, unique=True)
    is_fixture: Mapped[bool] = mapped_column(Boolean)
    rules: Mapped[dict] = mapped_column(JSONB)


class SkillPolicy(Base):
    __tablename__ = "skill_policies"
    __table_args__ = (CheckConstraint("jsonb_typeof(rules) = 'object'", name="rules_object"),)
    version: Mapped[str] = mapped_column(String(100), primary_key=True)
    rules: Mapped[dict] = mapped_column(JSONB)


class ActivityDevice(Base):
    __tablename__ = "activity_devices"
    __table_args__ = (
        UniqueConstraint("id", "owner_id"),
        CheckConstraint("revoked_at IS NULL OR revoked_at >= enrolled_at", name="revocation"),
        CheckConstraint(
            "(baseline_at IS NULL AND baseline_observed_at IS NULL "
            "AND baseline_date IS NULL AND baseline_steps IS NULL) OR (baseline_at IS NOT NULL "
            "AND baseline_observed_at IS NOT NULL AND baseline_date IS NOT NULL "
            "AND baseline_at >= enrolled_at AND baseline_steps IS NOT NULL "
            "AND baseline_steps >= 0)",
            name="baseline",
        ),
        Index(
            "uq_activity_active_owner",
            "owner_id",
            unique=True,
            postgresql_where=text("revoked_at IS NULL"),
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    installation_id: Mapped[UUID] = mapped_column()
    enrolled_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    baseline_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    baseline_observed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    baseline_date: Mapped[date | None] = mapped_column(Date)
    baseline_steps: Mapped[int | None] = mapped_column(BigInteger)
    metric_baselines: Mapped[dict] = mapped_column(JSONB, default=dict, server_default="{}")


class ActivityDay(Base):
    __tablename__ = "activity_days"
    __table_args__ = (
        CheckConstraint(
            "credited_steps >= 0 AND baseline_steps >= 0 AND baseline_credit_steps >= 0",
            name="steps",
        ),
        CheckConstraint("observed_steps IS NULL OR observed_steps >= 0", name="observed"),
        CheckConstraint("bucket_end > bucket_start", name="interval"),
        ForeignKeyConstraint(
            ["device_id", "owner_id"], ["activity_devices.id", "activity_devices.owner_id"]
        ),
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    game_date: Mapped[date] = mapped_column(Date, primary_key=True)
    game_timezone: Mapped[str] = mapped_column(String(64))
    bucket_start: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    bucket_end: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    device_id: Mapped[UUID] = mapped_column()
    rule_version: Mapped[str] = mapped_column(ForeignKey("economy_configs.version"))
    baseline_steps: Mapped[int] = mapped_column(BigInteger, default=0)
    baseline_credit_steps: Mapped[int] = mapped_column(BigInteger, default=0)
    observed_steps: Mapped[int | None] = mapped_column(BigInteger)
    observed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    is_available: Mapped[bool] = mapped_column(Boolean)
    credited_steps: Mapped[int] = mapped_column(BigInteger, default=0)


class ActivityCredit(Base):
    __tablename__ = "activity_credits"
    __table_args__ = (
        ForeignKeyConstraint(
            ["owner_id", "game_date"], ["activity_days.owner_id", "activity_days.game_date"]
        ),
        ForeignKeyConstraint(
            ["device_id", "owner_id"], ["activity_devices.id", "activity_devices.owner_id"]
        ),
        UniqueConstraint("owner_id", "game_date", "request_id"),
        CheckConstraint(
            "start_steps >= 0 AND end_steps >= start_steps "
            "AND water_steps >= 0 AND water_steps <= end_steps - start_steps "
            "AND (end_steps > start_steps OR metric_quantities <> '{}'::jsonb)",
            name="range",
        ),
    )
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    game_date: Mapped[date] = mapped_column(Date)
    device_id: Mapped[UUID] = mapped_column()
    request_id: Mapped[UUID] = mapped_column()
    rule_version: Mapped[str] = mapped_column(ForeignKey("economy_configs.version"))
    start_steps: Mapped[int] = mapped_column(BigInteger)
    end_steps: Mapped[int] = mapped_column(BigInteger)
    water_steps: Mapped[int] = mapped_column(BigInteger)
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    metric_quantities: Mapped[dict] = mapped_column(JSONB, default=dict, server_default="{}")


class PlantGrowthCredit(Base):
    __tablename__ = "plant_growth_credits"
    __table_args__ = (
        CheckConstraint("before_growth >= 0 AND after_growth >= before_growth", name="growth"),
    )
    plant_id: Mapped[UUID] = mapped_column(ForeignKey("owned_plants.id"), primary_key=True)
    activity_credit_id: Mapped[UUID] = mapped_column(
        ForeignKey("activity_credits.id"), primary_key=True
    )
    before_growth: Mapped[int] = mapped_column(BigInteger)
    after_growth: Mapped[int] = mapped_column(BigInteger)
    context: Mapped[dict] = mapped_column(JSONB)


class PlayerProgress(Base):
    __tablename__ = "player_progress"
    __table_args__ = (
        CheckConstraint("activity_steps >= 0 AND first_maturity_count >= 0", name="counters"),
    )
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), primary_key=True)
    activity_steps: Mapped[int] = mapped_column(BigInteger, default=0)
    first_maturity_count: Mapped[int] = mapped_column(BigInteger, default=0)
    last_sync_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    first_seedling_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    activity_metrics: Mapped[dict] = mapped_column(JSONB, default=dict, server_default="{}")


class RewardEvent(Base):
    __tablename__ = "reward_events"
    __table_args__ = (UniqueConstraint("owner_id", "request_id"),)
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    request_id: Mapped[UUID] = mapped_column()
    accepted_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    payload: Mapped[dict] = mapped_column(JSONB)


class RewardRecap(Base):
    __tablename__ = "reward_recaps"
    id: Mapped[UUID] = mapped_column(primary_key=True)
    owner_id: Mapped[UUID] = mapped_column(ForeignKey("users.id"), index=True)
    event_id: Mapped[UUID] = mapped_column(ForeignKey("reward_events.id"), unique=True)
    payload: Mapped[dict] = mapped_column(JSONB)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
