"""Permanent per-account, per-variant stage discovery and pinned-progress backfill."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import insert

revision = "0009_catalog_discovery"
down_revision = "0008_scheduled_visitors"
branch_labels = None
depends_on = None
STAGES = ("sprout", "seedling", "young", "adult")


def backfill(connection):
    """Self-contained and repeat-safe; never reads current species defaults."""
    state = sa.table(
        "catalog_discovery_state", sa.column("owner_id", sa.Uuid()), sa.column("version")
    )
    discoveries = sa.table(
        "catalog_stage_discoveries",
        sa.column("owner_id", sa.Uuid()),
        sa.column("species_id"),
        sa.column("variant_id"),
        sa.column("stage"),
    )
    connection.execute(
        sa.text(
            "INSERT INTO catalog_discovery_state (owner_id, version) "
            "SELECT id, 0 FROM users ON CONFLICT DO NOTHING"
        )
    )
    changed_owners, batch = set(), []

    def flush():
        if batch:
            changed_owners.update(
                connection.execute(
                    insert(discoveries)
                    .values(batch)
                    .on_conflict_do_nothing()
                    .returning(discoveries.c.owner_id)
                ).scalars()
            )
            batch.clear()

    for row in connection.execute(
        sa.text(
            "SELECT p.owner_id, p.species_id, p.variant_id, p.growth_micro_units, "
            "g.thresholds, g.maximum_growth_micro_units FROM owned_plants p "
            "LEFT JOIN growth_profiles g ON g.id = p.growth_profile_id "
            "AND g.version = p.growth_profile_version"
        )
    ).mappings():
        thresholds = row["thresholds"]
        values = [thresholds.get(stage) for stage in STAGES] if isinstance(thresholds, dict) else []
        if (
            len(values) != 4
            or set(thresholds) != set(STAGES)
            or any(
                type(value) is not int or not 0 <= value <= 9223372036854775807 for value in values
            )
            or values[0] != 0
            or any(a >= b for a, b in zip(values, values[1:], strict=False))
            or row["maximum_growth_micro_units"] < values[-1]
        ):
            raise RuntimeError("Catalog discovery backfill requires valid pinned growth profiles")
        for stage in STAGES[1:]:
            if row["growth_micro_units"] >= thresholds[stage]:
                batch.append(
                    dict(
                        owner_id=row["owner_id"],
                        species_id=row["species_id"],
                        variant_id=row["variant_id"],
                        stage=stage,
                    )
                )
        if len(batch) >= 1000:
            flush()
    flush()
    for owner in changed_owners:
        connection.execute(
            state.update().where(state.c.owner_id == owner).values(version=state.c.version + 1)
        )


def upgrade():
    op.create_table(
        "catalog_discovery_state",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("version", sa.BigInteger(), nullable=False, server_default="0"),
        sa.CheckConstraint("version >= 0", name="version"),
    )
    op.create_table(
        "catalog_stage_discoveries",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("species_id", sa.String(100), primary_key=True),
        sa.Column("variant_id", sa.String(100), primary_key=True),
        sa.Column("stage", sa.String(16), primary_key=True),
        sa.Column(
            "recorded_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()
        ),
        sa.ForeignKeyConstraint(
            ["species_id", "variant_id"], ["plant_variants.species_id", "plant_variants.variant_id"]
        ),
        sa.CheckConstraint("stage IN ('seedling', 'young', 'adult')", name="stage"),
    )
    backfill(op.get_bind())


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT EXISTS (SELECT 1 FROM catalog_stage_discoveries)")):
        raise RuntimeError("Earned catalog discoveries require the current schema")
    op.drop_table("catalog_stage_discoveries")
    op.drop_table("catalog_discovery_state")
