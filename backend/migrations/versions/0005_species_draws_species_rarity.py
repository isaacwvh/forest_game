"""Species rarity for hierarchical packs. Existing pack JSON/awards stay immutable."""

import sqlalchemy as sa
from alembic import op

revision = "0005_species_draws"
down_revision = "0004_collection"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "plant_species",
        sa.Column("rarity", sa.String(32), server_default="development_unbalanced", nullable=False),
    )
    op.create_check_constraint("rarity", "plant_species", "rarity ~ '^[a-z][a-z0-9_]{0,31}$'")


def downgrade():
    op.drop_constraint(op.f("ck_plant_species_rarity"), "plant_species", type_="check")
    op.drop_column("plant_species", "rarity")
