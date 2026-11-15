"""Separate garden item ownership and placement; no automatic content or grants."""

import sqlalchemy as sa
from alembic import op

revision = "0018_garden_items"
down_revision = "0017_milestone_tracks"
branch_labels = None
depends_on = None
TABLES = ("item_definitions", "item_identities", "owned_items", "item_placements")


def upgrade():
    from forest_api import item_models  # noqa: F401
    from forest_api.models import Base

    for name in TABLES:
        Base.metadata.tables[name].create(op.get_bind())
    for table in ("item_definitions", "item_identities"):
        op.execute(f"""CREATE TRIGGER immutable_{table} BEFORE UPDATE OR DELETE ON {table}
            FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()""")


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT EXISTS (SELECT 1 FROM item_identities)")):
        raise ValueError(
            "Retain permanent item acquisitions; restore a pre-item backup to downgrade"
        )
    for name in reversed(TABLES):
        op.drop_table(name)
