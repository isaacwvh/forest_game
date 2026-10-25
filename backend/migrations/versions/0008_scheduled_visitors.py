"""Scheduled arrivals and once-only economy conversion records; no automatic grants."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0008_scheduled_visitors"
down_revision = "0007_activity_launch"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "visitor_sessions",
        sa.Column("arrival_protocol", sa.Integer(), nullable=False, server_default="1"),
    )
    op.create_table(
        "visitor_schedules",
        sa.Column("garden_id", sa.Uuid(), sa.ForeignKey("gardens.id"), primary_key=True),
        sa.Column("context_id", sa.Uuid(), sa.ForeignKey("visitor_contexts.id"), nullable=False),
        sa.Column("next_at", sa.DateTime(timezone=True)),
        sa.Column("remaining", JSONB, nullable=False),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("tutorial_used", sa.Boolean(), nullable=False),
        sa.CheckConstraint("sequence >= 0", name="sequence"),
    )
    op.create_table(
        "visitor_economy_conversions",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("version", sa.String(100), primary_key=True),
        sa.Column("converted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("detail", JSONB, nullable=False),
    )
    op.execute(
        "CREATE TRIGGER immutable_record BEFORE UPDATE OR DELETE ON visitor_economy_conversions "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )


def downgrade():
    connection = op.get_bind()
    if connection.scalar(
        sa.text(
            "SELECT EXISTS (SELECT 1 FROM visitor_economy_conversions) "
            "OR EXISTS (SELECT 1 FROM visitor_schedules)"
        )
    ):
        raise RuntimeError(
            "Scheduled visitor state or converted balances require the current schema"
        )
    op.drop_table("visitor_economy_conversions")
    op.drop_table("visitor_schedules")
    op.drop_column("visitor_sessions", "arrival_protocol")
