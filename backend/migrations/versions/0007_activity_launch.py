"""Typed activity, recorded-workout coverage and one-time milestone receipts."""

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision = "0007_activity_launch"
down_revision = "0006_garden_skills"
branch_labels = None
depends_on = None


def upgrade():
    op.add_column(
        "activity_devices",
        sa.Column("metric_baselines", JSONB, nullable=False, server_default="{}"),
    )
    op.add_column(
        "activity_credits",
        sa.Column("metric_quantities", JSONB, nullable=False, server_default="{}"),
    )
    op.add_column(
        "player_progress", sa.Column("activity_metrics", JSONB, nullable=False, server_default="{}")
    )
    op.add_column("player_progress", sa.Column("first_seedling_at", sa.DateTime(timezone=True)))
    op.drop_constraint("uq_activity_credits_owner_id", "activity_credits", type_="unique")
    op.create_unique_constraint(
        "uq_activity_credits_owner_id", "activity_credits", ["owner_id", "game_date", "request_id"]
    )
    op.drop_constraint(op.f("ck_activity_credits_range"), "activity_credits", type_="check")
    op.create_check_constraint(
        op.f("ck_activity_credits_range"),
        "activity_credits",
        "start_steps >= 0 AND end_steps >= start_steps "
        "AND water_steps >= 0 AND water_steps <= end_steps - start_steps "
        "AND (end_steps > start_steps OR metric_quantities <> '{}'::jsonb)",
    )
    op.create_table(
        "activity_metric_days",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("game_date", sa.Date(), primary_key=True),
        sa.Column("metric", sa.String(100), primary_key=True),
        sa.Column("device_id", sa.Uuid(), sa.ForeignKey("activity_devices.id"), nullable=False),
        sa.Column(
            "rule_version", sa.String(100), sa.ForeignKey("economy_configs.version"), nullable=False
        ),
        sa.Column("baseline", sa.BigInteger(), nullable=False),
        sa.Column("baseline_credit", sa.BigInteger(), nullable=False),
        sa.Column("credited", sa.BigInteger(), nullable=False),
        sa.Column("observed", sa.BigInteger()),
        sa.Column("observed_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "baseline >= 0 AND baseline_credit >= 0 AND credited >= 0", name="quantities"
        ),
        sa.CheckConstraint("observed IS NULL OR observed >= 0", name="observed"),
    )
    op.create_table(
        "activity_workouts",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("workout_id", sa.Uuid(), primary_key=True),
        sa.Column("accepted_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("payload", JSONB, nullable=False),
        sa.Column("outcome", sa.String(40), nullable=False),
    )
    op.create_table(
        "activity_workout_days",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("game_date", sa.Date(), primary_key=True),
        sa.Column(
            "rule_version", sa.String(100), sa.ForeignKey("economy_configs.version"), nullable=False
        ),
        sa.Column("covered_intervals", JSONB, nullable=False),
        sa.Column("credited_microseconds", sa.BigInteger(), nullable=False),
        sa.Column("remainder", JSONB, nullable=False),
        sa.CheckConstraint("credited_microseconds >= 0", name="quantity"),
    )
    op.create_table(
        "milestone_claims",
        sa.Column("owner_id", sa.Uuid(), sa.ForeignKey("users.id"), primary_key=True),
        sa.Column("milestone_id", sa.String(100), primary_key=True),
        sa.Column("claimed_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("reward_tokens", sa.BigInteger(), nullable=False),
        sa.Column("receipt", JSONB, nullable=False),
    )
    for table in ("activity_workouts", "milestone_claims"):
        op.execute(
            f"CREATE TRIGGER immutable_record BEFORE UPDATE ON {table} "
            "FOR EACH ROW EXECUTE FUNCTION forest_immutable_profile()"
        )
    op.execute("""
        UPDATE player_progress p SET first_seedling_at = (
          SELECT min(c.accepted_at) FROM plant_growth_credits g
          JOIN activity_credits c ON c.id=g.activity_credit_id
          WHERE c.owner_id=p.owner_id AND g.context->>'afterStage'
            IN ('seedling','young','adult'))
    """)


def downgrade():
    # Older schema cannot represent a credit containing no steps.
    connection = op.get_bind()
    if connection.scalar(
        sa.text(
            "SELECT EXISTS (SELECT 1 FROM activity_credits WHERE metric_quantities <> '{}'::jsonb)"
        )
    ):
        raise RuntimeError("Typed activity credits require the current schema")
    for table in (
        "milestone_claims",
        "activity_workout_days",
        "activity_workouts",
        "activity_metric_days",
    ):
        op.drop_table(table)
    op.drop_constraint("uq_activity_credits_owner_id", "activity_credits", type_="unique")
    op.create_unique_constraint(
        "uq_activity_credits_owner_id", "activity_credits", ["owner_id", "game_date", "end_steps"]
    )
    op.drop_constraint(op.f("ck_activity_credits_range"), "activity_credits", type_="check")
    op.create_check_constraint(
        op.f("ck_activity_credits_range"),
        "activity_credits",
        "start_steps >= 0 AND end_steps > start_steps "
        "AND water_steps >= 0 AND water_steps <= end_steps - start_steps",
    )
    op.drop_column("player_progress", "first_seedling_at")
    op.drop_column("player_progress", "activity_metrics")
    op.drop_column("activity_credits", "metric_quantities")
    op.drop_column("activity_devices", "metric_baselines")
