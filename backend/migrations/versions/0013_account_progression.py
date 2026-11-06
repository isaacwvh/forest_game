"""Add step-earned gem accounting and progression versions without repricing the game."""

import sqlalchemy as sa
from alembic import op

revision = "0013_account_progression"
down_revision = "0012_inventory_management"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "visitor_wallets", sa.Column("gems", sa.BigInteger(), nullable=False, server_default="0")
    )
    op.add_column(
        "visitor_wallets",
        sa.Column("lifetime_gems_earned", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.add_column(
        "visitor_wallets",
        sa.Column("progression_initialized", sa.Boolean(), nullable=False, server_default="false"),
    )
    op.create_check_constraint(
        "gem_amounts", "visitor_wallets", "gems >= 0 AND lifetime_gems_earned >= gems"
    )
    op.add_column(
        "player_progress",
        sa.Column("progression_version", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.create_check_constraint("progression_version", "player_progress", "progression_version >= 0")
    op.create_table(
        "gem_grants",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("source_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.String(16), nullable=False),
        sa.Column("rules_version", sa.String(64), nullable=False),
        sa.Column("start_milestone", sa.BigInteger(), nullable=False),
        sa.Column("end_milestone", sa.BigInteger(), nullable=False),
        sa.Column("amount", sa.BigInteger(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("owner_id", "source_id", name="uq_gem_grants_source"),
        sa.UniqueConstraint("owner_id", "end_milestone", name="uq_gem_grants_milestone"),
        sa.CheckConstraint(
            "start_milestone >= 0 AND end_milestone > start_milestone "
            "AND amount = end_milestone - start_milestone",
            name="amounts",
        ),
        sa.CheckConstraint("kind IN ('steps', 'backfill')", name="kind"),
    )
    op.create_index("ix_gem_grants_owner_id", "gem_grants", ["owner_id"])


def downgrade():
    op.drop_table("gem_grants")
    op.drop_constraint("gem_amounts", "visitor_wallets", type_="check")
    op.drop_column("visitor_wallets", "progression_initialized")
    op.drop_column("visitor_wallets", "lifetime_gems_earned")
    op.drop_column("visitor_wallets", "gems")
    op.drop_constraint("progression_version", "player_progress", type_="check")
    op.drop_column("player_progress", "progression_version")
