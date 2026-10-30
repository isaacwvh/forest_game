"""Add reconciled summaries, shared provenance and durable visitor receipt facts."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0011_compact_history"
down_revision = "0010_compact_recovery"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "garden_visitor_state",
        sa.Column("ever_issued", sa.Boolean(), nullable=False, server_default="false"),
    )
    op.execute(
        "UPDATE garden_visitor_state s SET ever_issued = true WHERE EXISTS "
        "(SELECT 1 FROM visitor_opportunities o WHERE o.garden_id = s.garden_id)"
    )
    op.add_column("visitor_reward_events", sa.Column("receipt", JSONB(), nullable=True))
    op.add_column(
        "visitor_reward_events",
        sa.Column("summarized_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_table(
        "growth_provenance",
        sa.Column("id", sa.String(64), primary_key=True),
        sa.Column("payload", JSONB(), nullable=False),
    )
    op.execute(
        "CREATE TRIGGER immutable_provenance BEFORE UPDATE ON growth_provenance "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )
    op.add_column("plant_growth_credits", sa.Column("provenance_id", sa.String(64), nullable=True))
    op.create_foreign_key(
        "fk_plant_growth_credits_provenance_id_growth_provenance",
        "plant_growth_credits",
        "growth_provenance",
        ["provenance_id"],
        ["id"],
    )
    for column in ("activity_credit_id", "provenance_id"):
        op.create_index(f"ix_plant_growth_credits_{column}", "plant_growth_credits", [column])
    op.create_index(
        "ix_visitor_reward_events_pending_summary",
        "visitor_reward_events",
        ["created_at"],
        postgresql_where=sa.text(
            "summarized_at IS NULL AND kind IN ('active_welcome', 'offline_claim')"
        ),
    )
    op.create_index(
        "ix_reward_recaps_pending_compaction",
        "reward_recaps",
        ["acknowledged_at"],
        postgresql_where=sa.text("acknowledged_at IS NOT NULL AND NOT (payload ? 'compacted')"),
    )
    op.create_table(
        "visitor_day_summaries",
        sa.Column("garden_id", sa.Uuid(), sa.ForeignKey("gardens.id"), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column(
            "rule_version", sa.String(100), sa.ForeignKey("visitor_rules.version"), primary_key=True
        ),
        sa.Column("kind", sa.String(32), primary_key=True),
        sa.Column("microseconds", sa.BigInteger(), nullable=False),
        sa.Column("generated", JSONB(), nullable=False),
        sa.Column("discarded", JSONB(), nullable=False),
        sa.Column("visits", sa.BigInteger(), nullable=False),
        sa.Column("tokens", sa.BigInteger(), nullable=False),
        sa.CheckConstraint("microseconds >= 0 AND visits >= 0 AND tokens >= 0", name="amounts"),
    )
    op.create_table(
        "growth_day_summaries",
        sa.Column("plant_id", sa.Uuid(), sa.ForeignKey("owned_plants.id"), primary_key=True),
        sa.Column("day", sa.Date(), primary_key=True),
        sa.Column(
            "rule_version",
            sa.String(100),
            sa.ForeignKey("economy_configs.version"),
            primary_key=True,
        ),
        sa.Column("profile_key", sa.String(64), primary_key=True),
        sa.Column("profiles", JSONB(), nullable=False),
        sa.Column("awarded", sa.BigInteger(), nullable=False),
        sa.Column("skill_bonus", sa.BigInteger(), nullable=False),
        sa.Column("credit_count", sa.BigInteger(), nullable=False),
        sa.CheckConstraint("awarded >= 0 AND credit_count > 0", name="amounts"),
    )
    for table, column in (
        ("visitor_settlements", "end_at"),
        ("visitor_contexts", "effective_at"),
        ("visitor_sessions", "ended_at"),
        ("activity_credits", "accepted_at"),
        ("reward_events", "accepted_at"),
    ):
        op.create_index(f"ix_{table}_{column}", table, [column])
    op.execute("DROP TRIGGER immutable_visitor_history ON visitor_reward_events")
    op.execute("""
        CREATE FUNCTION forest_reward_recovery_metadata() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF (to_jsonb(NEW) - 'receipt' - 'summarized_at') IS DISTINCT FROM
             (to_jsonb(OLD) - 'receipt' - 'summarized_at') OR
             (OLD.receipt IS NOT NULL AND NEW.receipt IS DISTINCT FROM OLD.receipt) OR
             (NEW.receipt IS NOT DISTINCT FROM OLD.receipt AND
              NEW.summarized_at IS NOT DISTINCT FROM OLD.summarized_at) OR
             (OLD.summarized_at IS NOT NULL AND
              NEW.summarized_at IS DISTINCT FROM OLD.summarized_at)
          THEN RAISE EXCEPTION 'Visitor reward facts are immutable' USING ERRCODE = '23514';
          END IF;
          RETURN NEW;
        END $$;
        CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON visitor_reward_events
        FOR EACH ROW EXECUTE FUNCTION forest_reward_recovery_metadata();
    """)
    op.execute("DROP TRIGGER immutable_credit ON reward_events")
    op.execute("""
        CREATE FUNCTION forest_compact_growth_event() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF current_setting('forest.history_compaction', true) = 'on' AND
             (to_jsonb(NEW) - 'payload') = (to_jsonb(OLD) - 'payload') AND
             NEW.payload = jsonb_build_object('compacted', 1, 'kind', 'activity_growth',
                 'creditIds', coalesce(OLD.payload->'creditIds', '[]'::jsonb)) AND
             NOT EXISTS (SELECT 1 FROM reward_recaps
                         WHERE event_id = OLD.id AND acknowledged_at IS NULL)
          THEN RETURN NEW; END IF;
          RAISE EXCEPTION 'Growth events are immutable' USING ERRCODE = '23514';
        END $$;
        CREATE TRIGGER immutable_credit BEFORE UPDATE ON reward_events
        FOR EACH ROW EXECUTE FUNCTION forest_compact_growth_event();
    """)
    op.execute("""
        CREATE OR REPLACE FUNCTION forest_recap_ack_only() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF current_setting('forest.history_compaction', true) = 'on' AND
             OLD.acknowledged_at IS NOT NULL AND
             (to_jsonb(NEW) - 'payload') = (to_jsonb(OLD) - 'payload') AND
             NEW.payload = jsonb_build_object('compacted', 1, 'eventId', OLD.event_id::text)
          THEN RETURN NEW; END IF;
          IF NEW.id IS DISTINCT FROM OLD.id OR NEW.owner_id IS DISTINCT FROM OLD.owner_id OR
             NEW.event_id IS DISTINCT FROM OLD.event_id OR
             NEW.created_at IS DISTINCT FROM OLD.created_at OR
             NEW.payload IS DISTINCT FROM OLD.payload OR
             (OLD.acknowledged_at IS NOT NULL AND
              NEW.acknowledged_at IS DISTINCT FROM OLD.acknowledged_at)
          THEN RAISE EXCEPTION 'Recap is immutable' USING ERRCODE = '23514'; END IF;
          RETURN NEW;
        END $$;
    """)


def downgrade():
    connection = op.get_bind()
    if connection.scalar(
        sa.text(
            "SELECT count(*) FROM visitor_opportunities WHERE status = 'welcomed' "
            "AND NOT (result ? 'summary')"
        )
    ):
        raise RuntimeError("Compact visitor receipts require a forward-compatible restore")
    if connection.scalar(
        sa.text(
            "SELECT count(*) FROM garden_visitor_state s WHERE ever_issued AND NOT EXISTS "
            "(SELECT 1 FROM visitor_opportunities o WHERE o.garden_id = s.garden_id) "
            "AND NOT EXISTS (SELECT 1 FROM visitor_schedules q WHERE q.garden_id = s.garden_id "
            "AND q.tutorial_used)"
        )
    ):
        raise RuntimeError("Retired visitor identities require a forward-compatible restore")
    if connection.scalar(
        sa.text("SELECT count(*) FROM visitor_day_summaries")
    ) or connection.scalar(sa.text("SELECT count(*) FROM growth_day_summaries")):
        raise RuntimeError("Compacted history requires a forward fix or tested backup restore")
    # Reconstruct recent shared traces before removing their references.
    for column in ("activity_credit_id", "provenance_id"):
        op.drop_index(f"ix_plant_growth_credits_{column}", table_name="plant_growth_credits")
    op.drop_index("ix_visitor_reward_events_pending_summary", table_name="visitor_reward_events")
    op.drop_index("ix_reward_recaps_pending_compaction", table_name="reward_recaps")
    op.execute("DROP TRIGGER immutable_credit ON plant_growth_credits")
    op.execute(
        "UPDATE plant_growth_credits g SET context = p.payload || g.context "
        "FROM growth_provenance p WHERE p.id = g.provenance_id"
    )
    for table, column in (
        ("visitor_settlements", "end_at"),
        ("visitor_contexts", "effective_at"),
        ("visitor_sessions", "ended_at"),
        ("activity_credits", "accepted_at"),
        ("reward_events", "accepted_at"),
    ):
        op.drop_index(f"ix_{table}_{column}", table_name=table)
    op.drop_table("growth_day_summaries")
    op.drop_table("visitor_day_summaries")
    op.drop_constraint(
        "fk_plant_growth_credits_provenance_id_growth_provenance",
        "plant_growth_credits",
        type_="foreignkey",
    )
    op.drop_column("plant_growth_credits", "provenance_id")
    op.drop_table("growth_provenance")
    op.drop_column("visitor_reward_events", "summarized_at")
    op.drop_column("visitor_reward_events", "receipt")
    op.drop_column("garden_visitor_state", "ever_issued")
    op.execute(
        "CREATE TRIGGER immutable_credit BEFORE UPDATE ON plant_growth_credits "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )
    op.execute("DROP TRIGGER immutable_credit ON reward_events")
    op.execute("DROP FUNCTION forest_compact_growth_event()")
    op.execute(
        "CREATE TRIGGER immutable_credit BEFORE UPDATE ON reward_events "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )
    op.execute("DROP TRIGGER immutable_visitor_history ON visitor_reward_events")
    op.execute("DROP FUNCTION forest_reward_recovery_metadata()")
    op.execute(
        "CREATE TRIGGER immutable_visitor_history BEFORE UPDATE ON visitor_reward_events "
        "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
    )
