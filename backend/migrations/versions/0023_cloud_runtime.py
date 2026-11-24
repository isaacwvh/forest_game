"""Shared maintenance control; no game data or publication changes."""

import sqlalchemy as sa
from alembic import op

revision = "0023_cloud_runtime"
down_revision = "0022_expedition_launch"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "runtime_control",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("maintenance", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("release", sa.Text(), server_default="", nullable=False),
        sa.Column(
            "updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("id = 1", name="singleton"),
    )
    op.execute("INSERT INTO runtime_control (id) VALUES (1)")


def downgrade():
    op.drop_table("runtime_control")
