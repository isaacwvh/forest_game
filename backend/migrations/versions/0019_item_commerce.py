"""Permanent item offers and durable resale; publication remains explicit."""

import sqlalchemy as sa
from alembic import op

revision = "0019_item_commerce"
down_revision = "0018_garden_items"
branch_labels = None
depends_on = None
TABLES = ("item_value_definitions", "item_valuations", "item_shop_offers", "item_sales")


def upgrade():
    from forest_api import item_models  # noqa: F401
    from forest_api.models import Base

    for name in TABLES:
        Base.metadata.tables[name].create(op.get_bind())
    for name in ("item_value_definitions", "item_valuations", "item_sales"):
        op.execute(f"""CREATE TRIGGER immutable_{name} BEFORE UPDATE OR DELETE ON {name}
            FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()""")
    op.execute("""
        CREATE FUNCTION forest_item_offer_immutable() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'active') <> (to_jsonb(OLD) - 'active') THEN
            RAISE EXCEPTION 'Item offers are immutable; publish a new version';
          END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql;
        CREATE TRIGGER immutable_item_offer BEFORE UPDATE OR DELETE ON item_shop_offers
          FOR EACH ROW EXECUTE FUNCTION forest_item_offer_immutable();
        CREATE FUNCTION forest_no_sold_item() RETURNS trigger AS $$
        BEGIN
          IF EXISTS (SELECT 1 FROM item_sales WHERE owned_item_id = NEW.id) THEN
            RAISE EXCEPTION 'Sold item identities cannot be restored';
          END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql;
        CREATE TRIGGER no_sold_item BEFORE INSERT ON owned_items
          FOR EACH ROW EXECUTE FUNCTION forest_no_sold_item();
    """)


def downgrade():
    if op.get_bind().scalar(sa.text("SELECT EXISTS (SELECT 1 FROM item_value_definitions)")):
        raise ValueError(
            "Retain published item valuation and receipts; restore a pre-commerce backup"
        )
    op.execute("DROP TRIGGER no_sold_item ON owned_items; DROP FUNCTION forest_no_sold_item()")
    for name in reversed(TABLES):
        op.drop_table(name)
    op.execute("DROP FUNCTION forest_item_offer_immutable()")
