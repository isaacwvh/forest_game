"""Durable milestone tracks and source-aware bonus gems; activation is explicit."""

import sqlalchemy as sa
from alembic import op

revision = "0017_milestone_tracks"
down_revision = "0016_sprout_discovery"
branch_labels = None
depends_on = None

TABLES = (
    "milestone_policies",
    "milestone_state",
    "milestone_days",
    "milestone_species",
    "milestone_entitlements",
    "milestone_bonus_grants",
    "milestone_events",
    "milestone_event_state",
)


def upgrade():
    from forest_api import milestone_models  # noqa: F401
    from forest_api.models import Base

    for name in TABLES:
        Base.metadata.tables[name].create(op.get_bind())
    op.add_column(
        "visitor_wallets",
        sa.Column("step_gems_earned", sa.BigInteger(), nullable=False, server_default="0"),
    )
    op.execute("UPDATE visitor_wallets SET step_gems_earned = lifetime_gems_earned")
    op.create_check_constraint(
        "step_gems",
        "visitor_wallets",
        "step_gems_earned >= 0 AND step_gems_earned <= lifetime_gems_earned",
    )
    op.execute("""
        CREATE FUNCTION forest_immutable_milestone_policy() RETURNS trigger AS $$
        BEGIN
          IF TG_OP = 'DELETE' OR (to_jsonb(NEW) - 'active') <> (to_jsonb(OLD) - 'active') THEN
            RAISE EXCEPTION 'Milestone policies are immutable; publish a new version';
          END IF;
          RETURN NEW;
        END; $$ LANGUAGE plpgsql;
        CREATE TRIGGER immutable_milestone_policy BEFORE UPDATE OR DELETE ON milestone_policies
          FOR EACH ROW EXECUTE FUNCTION forest_immutable_milestone_policy();
        CREATE TRIGGER immutable_milestone_event BEFORE UPDATE OR DELETE ON milestone_events
          FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile();
        CREATE TRIGGER immutable_milestone_entitlement
          BEFORE UPDATE OR DELETE ON milestone_entitlements
          FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile();
        CREATE TRIGGER immutable_milestone_species BEFORE UPDATE OR DELETE ON milestone_species
          FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile();
    """)


def downgrade():
    # A downgrade after awards would lose accounting/recovery facts. Refuse it.
    conn = op.get_bind()
    if conn.scalar(sa.text("SELECT EXISTS (SELECT 1 FROM milestone_policies)")):
        raise ValueError("Retain milestone policy/entitlements; activated downgrade is unsupported")
    op.drop_constraint(op.f("ck_visitor_wallets_step_gems"), "visitor_wallets", type_="check")
    op.drop_column("visitor_wallets", "step_gems_earned")
    for name in reversed(TABLES):
        op.drop_table(name)
    op.execute("DROP FUNCTION forest_immutable_milestone_policy()")
