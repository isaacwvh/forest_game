"""Permit a non-retrospective first partial month without changing old schedules."""

from alembic import op

revision = "0022_expedition_launch"
down_revision = "0021_expeditions"
branch_labels = None
depends_on = None


def upgrade():
    from forest_api import expedition_models  # noqa: F401
    from forest_api.models import Base

    Base.metadata.tables["expedition_launches"].create(op.get_bind())
    op.execute(
        "CREATE TRIGGER immutable_expedition_launches BEFORE UPDATE OR DELETE "
        "ON expedition_launches FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )


def downgrade():
    import sqlalchemy as sa

    if op.get_bind().scalar(sa.text("SELECT EXISTS (SELECT 1 FROM expedition_launches)")):
        raise ValueError("Retain the earning cutoff; restore a pre-launch backup")
    op.drop_table("expedition_launches")
