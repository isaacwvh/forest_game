"""Earn sprout artwork on acquisition, including previously sold pack results."""

import sqlalchemy as sa
from alembic import op

revision = "0016_sprout_discovery"
down_revision = "0015_woodland_release"
branch_labels = None
depends_on = None


def backfill(connection):
    # Live copies, permanent reached stages and immutable opening receipts are
    # independent evidence of acquisition. Identity/sale rows alone lack variants.
    # One version increment per changed owner; reruns insert nothing.
    connection.execute(
        sa.text("""
        WITH candidates AS (
          SELECT owner_id, species_id, variant_id FROM owned_plants
          UNION
          SELECT owner_id, species_id, variant_id FROM catalog_stage_discoveries
          UNION
          SELECT e.owner_id, v.species_id, v.variant_id
          FROM collection_events e
          JOIN plant_variants v
            ON v.species_id = e.receipt->'plant'->>'speciesId'
           AND v.variant_id = e.receipt->'plant'->>'variantId'
          WHERE e.operation = 'pack_open'
        ), inserted AS (
          INSERT INTO catalog_stage_discoveries (owner_id, species_id, variant_id, stage)
          SELECT owner_id, species_id, variant_id, 'sprout' FROM candidates
          ON CONFLICT DO NOTHING
          RETURNING owner_id
        )
        UPDATE catalog_discovery_state SET version = version + 1
        WHERE owner_id IN (SELECT owner_id FROM inserted)
    """)
    )


def upgrade():
    op.drop_constraint(
        op.f("ck_catalog_stage_discoveries_stage"), "catalog_stage_discoveries", type_="check"
    )
    op.create_check_constraint(
        "stage", "catalog_stage_discoveries", "stage IN ('sprout', 'seedling', 'young', 'adult')"
    )
    backfill(op.get_bind())


def downgrade():
    # The previous policy exposes all sprouts unconditionally. Removing only
    # sprout rows restores that policy without removing earned later stages.
    op.execute("DELETE FROM catalog_stage_discoveries WHERE stage = 'sprout'")
    op.drop_constraint(
        op.f("ck_catalog_stage_discoveries_stage"), "catalog_stage_discoveries", type_="check"
    )
    op.create_check_constraint(
        "stage", "catalog_stage_discoveries", "stage IN ('seedling', 'young', 'adult')"
    )
