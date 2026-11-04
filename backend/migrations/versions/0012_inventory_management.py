"""Bound live inventory, preserve retired identities and record exact plant sales."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision = "0012_inventory_management"
down_revision = "0011_compact_history"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "plant_identities",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("acquisition_source", sa.String(64), nullable=False),
        sa.Column("acquisition_reference", sa.String(255), nullable=False),
        sa.Column("valuation_version", sa.String(100), nullable=False),
        sa.Column("valuation_rarity", sa.String(32)),
        sa.Column("variant_basis_points", sa.Integer()),
        sa.UniqueConstraint("id", "owner_id"),
        sa.UniqueConstraint("owner_id", "acquisition_source", "acquisition_reference"),
    )
    op.create_index("ix_plant_identities_owner_id", "plant_identities", ["owner_id"])
    # Freeze approved species rarity (never legacy variant rarity), with an explicit
    # mapping for the two historical development species. Unknown art is not priced.
    op.execute("""
        CREATE FUNCTION forest_record_plant_identity() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          INSERT INTO plant_identities
            (id, owner_id, acquisition_source, acquisition_reference,
             valuation_version, valuation_rarity, variant_basis_points)
          SELECT NEW.id, NEW.owner_id, NEW.acquisition_source, NEW.acquisition_reference,
            'plant-resale-v1',
            CASE WHEN s.rarity IN ('common','rare','epic','legendary') THEN s.rarity
                 WHEN s.id = 'oak' THEN 'common'
                 WHEN s.id = 'moonwillow' THEN 'epic' ELSE NULL END,
            CASE WHEN NEW.variant_id = 'standard' THEN 10000
                 WHEN NEW.species_id = 'oak' AND NEW.variant_id = 'blue' THEN 12500
                 WHEN NEW.species_id = 'oak' AND NEW.variant_id = 'vined' THEN 15000
                 WHEN NEW.species_id = 'moonwillow' AND NEW.variant_id = 'golden' THEN 15000
                 ELSE NULL END
          FROM plant_species s WHERE s.id = NEW.species_id
          ON CONFLICT (id) DO NOTHING;
          IF EXISTS (SELECT 1 FROM plant_sales WHERE plant_id = NEW.id) THEN
            RAISE EXCEPTION 'A sold plant cannot be reacquired';
          END IF;
          RETURN NEW;
        END $$
    """)
    op.execute("""
        INSERT INTO plant_identities
          (id, owner_id, acquisition_source, acquisition_reference,
           valuation_version, valuation_rarity, variant_basis_points)
        SELECT p.id, p.owner_id, p.acquisition_source, p.acquisition_reference,
          'plant-resale-v1',
          CASE WHEN s.rarity IN ('common','rare','epic','legendary') THEN s.rarity
               WHEN s.id = 'oak' THEN 'common'
               WHEN s.id = 'moonwillow' THEN 'epic' ELSE NULL END,
          CASE WHEN p.variant_id = 'standard' THEN 10000
               WHEN p.species_id = 'oak' AND p.variant_id = 'blue' THEN 12500
               WHEN p.species_id = 'oak' AND p.variant_id = 'vined' THEN 15000
               WHEN p.species_id = 'moonwillow' AND p.variant_id = 'golden' THEN 15000
               ELSE NULL END
        FROM owned_plants p JOIN plant_species s ON s.id = p.species_id
    """)
    op.create_foreign_key(
        "fk_owned_plants_id_plant_identities",
        "owned_plants",
        "plant_identities",
        ["id", "owner_id"],
        ["id", "owner_id"],
    )
    for table in ("pack_openings", "plant_growth_credits", "growth_day_summaries"):
        op.drop_constraint(f"fk_{table}_plant_id_owned_plants", table, type_="foreignkey")
        op.create_foreign_key(
            f"fk_{table}_plant_id_plant_identities", table, "plant_identities", ["plant_id"], ["id"]
        )
    op.create_table(
        "plant_sales",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("plant_id", sa.Uuid(), sa.ForeignKey("plant_identities.id"), nullable=False),
        sa.Column("request_id", sa.Uuid(), nullable=False),
        sa.Column("payload_hash", sa.String(64), nullable=False),
        sa.Column("tokens", sa.BigInteger(), nullable=False),
        sa.Column("receipt", postgresql.JSONB(), nullable=False),
        sa.Column("sold_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("plant_id"),
        sa.UniqueConstraint("owner_id", "request_id"),
        sa.CheckConstraint("tokens > 0", name="tokens"),
    )
    op.create_index("ix_plant_sales_owner_id", "plant_sales", ["owner_id"])
    for table in ("plant_identities", "plant_sales"):
        op.execute(
            f"CREATE TRIGGER immutable_{table} BEFORE UPDATE ON {table} "
            "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
        )
    op.execute("""
        CREATE TRIGGER owned_plant_identity BEFORE INSERT ON owned_plants
        FOR EACH ROW EXECUTE FUNCTION forest_record_plant_identity()
    """)


def downgrade():
    # Returning to a schema that requires every historical copy to be live would
    # either lose sale facts or resurrect sold plants. Refuse before any DDL.
    if op.get_bind().scalar(sa.text("SELECT EXISTS (SELECT 1 FROM plant_sales)")):
        raise RuntimeError("Cannot downgrade after plant sales; restore a pre-sale backup")
    op.execute("DROP TRIGGER owned_plant_identity ON owned_plants")
    op.execute("DROP FUNCTION forest_record_plant_identity()")
    op.drop_table("plant_sales")
    for table in ("pack_openings", "plant_growth_credits", "growth_day_summaries"):
        op.drop_constraint(f"fk_{table}_plant_id_plant_identities", table, type_="foreignkey")
        op.create_foreign_key(
            f"fk_{table}_plant_id_owned_plants", table, "owned_plants", ["plant_id"], ["id"]
        )
    op.drop_constraint("fk_owned_plants_id_plant_identities", "owned_plants", type_="foreignkey")
    op.drop_table("plant_identities")
