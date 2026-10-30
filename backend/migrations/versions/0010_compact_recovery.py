"""Compact completion outcomes and bounded visitor control replay."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0010_compact_recovery"
down_revision = "0009_catalog_discovery"
branch_labels = None
depends_on = None


def upgrade():
    op.alter_column("api_requests", "response", nullable=True)
    op.add_column("api_requests", sa.Column("completion", postgresql.JSONB(), nullable=True))
    op.add_column(
        "api_requests", sa.Column("response_expires_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column(
        "api_requests",
        sa.Column("recovery_version", sa.Integer(), server_default="0", nullable=False),
    )
    op.create_check_constraint(
        "recoverable", "api_requests", "response IS NOT NULL OR completion IS NOT NULL"
    )
    op.create_check_constraint(
        "completion_size", "api_requests", "octet_length(completion::text) <= 8192"
    )
    op.create_index("ix_api_requests_response_expires_at", "api_requests", ["response_expires_at"])
    op.create_table(
        "visitor_controls",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("sequence", sa.BigInteger(), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=True),
        sa.Column("operation", sa.String(100), nullable=True),
        sa.Column("payload_hash", sa.String(64), nullable=True),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("sequence >= 0", name="sequence"),
    )


def downgrade():
    # Removing compact proof would turn completed mutations into fresh requests.
    connection = op.get_bind()
    if connection.scalar(sa.text("SELECT count(*) FROM api_requests WHERE response IS NULL")):
        raise RuntimeError("Restore full responses before downgrading compact recovery")
    if connection.scalar(sa.text("SELECT count(*) FROM visitor_controls")):
        raise RuntimeError("Visitor control sequences require a forward-compatible restore")
    op.drop_table("visitor_controls")
    op.drop_index("ix_api_requests_response_expires_at", table_name="api_requests")
    op.drop_constraint(op.f("ck_api_requests_completion_size"), "api_requests", type_="check")
    op.drop_constraint(op.f("ck_api_requests_recoverable"), "api_requests", type_="check")
    for name in ("recovery_version", "response_expires_at", "completion"):
        op.drop_column("api_requests", name)
    op.alter_column("api_requests", "response", nullable=False)
