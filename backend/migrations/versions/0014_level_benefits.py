"""Level benefits and one-time presentation facts; activation remains explicit."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0014_level_benefits"
down_revision = "0013_account_progression"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "level_benefits_policy",
        sa.Column("version", sa.String(64), primary_key=True),
        sa.Column("effective_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "account_level_state",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("reached_level", sa.BigInteger(), nullable=False),
        sa.Column("presented_level", sa.BigInteger(), nullable=False),
        sa.CheckConstraint(
            "reached_level >= presented_level AND presented_level >= 1", name="levels"
        ),
    )
    op.create_table(
        "level_up_notices",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("source_id", sa.Uuid(), nullable=False),
        sa.Column("from_level", sa.BigInteger(), nullable=False),
        sa.Column("to_level", sa.BigInteger(), nullable=False),
        sa.Column("payload", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True)),
        sa.Column("claim_id", sa.Uuid()),
        sa.Column("installation_id", sa.Uuid()),
        sa.UniqueConstraint("owner_id", "source_id", name="uq_level_notice_source"),
        sa.UniqueConstraint("owner_id", "claim_id", name="uq_level_notice_claim"),
        sa.CheckConstraint("from_level >= 1 AND to_level > from_level", name="levels"),
        sa.CheckConstraint(
            "(consumed_at IS NULL AND claim_id IS NULL AND installation_id IS NULL) OR "
            "(consumed_at IS NOT NULL AND claim_id IS NOT NULL AND installation_id IS NOT NULL)",
            name="claim",
        ),
    )
    op.create_index("ix_level_up_notices_owner_id", "level_up_notices", ["owner_id"])


def downgrade():
    op.drop_table("level_up_notices")
    op.drop_table("account_level_state")
    op.drop_table("level_benefits_policy")
