"""Reconciled, bounded history maintenance. No live-account state is recomputed."""

from datetime import UTC, datetime, timedelta
from fractions import Fraction
from uuid import UUID

from fastapi.responses import JSONResponse
from sqlalchemy import func, select, text

from forest_api import growth_history, recovery, services
from forest_api.errors import ApiError
from forest_api.history_models import GrowthDaySummary, GrowthProvenance, VisitorDaySummary
from forest_api.models import (
    ActivityCredit,
    ApiRequest,
    Garden,
    PlantGrowthCredit,
    RewardEvent,
    RewardRecap,
    User,
)
from forest_api.visitor_models import (
    VisitorContext,
    VisitorOpportunity,
    VisitorRewardEvent,
    VisitorSchedule,
    VisitorSession,
    VisitorSettlement,
    VisitorState,
    VisitorStorageLot,
    VisitorWallet,
    VisitorWalletEntry,
)


def recover_welcome(session, user, body, digest, target):
    event = session.scalar(
        select(VisitorRewardEvent).where(
            VisitorRewardEvent.owner_id == user.id,
            VisitorRewardEvent.kind == "active_welcome",
            VisitorRewardEvent.source_id == target,
        )
    )
    if event is None or event.receipt is None:
        return None
    if session.info.get("recovery_version") != 1 or not event.receipt["recoverable"]:
        raise ApiError(
            426, "recovery_client_update_required", "Update the app to recover this visitor"
        )
    # Alias identities commit too; otherwise the alias UUID could be reused for a
    # different target after a response loss. JSONResponse avoids exception rollback.
    facts = {k: v for k, v in event.receipt.items() if k != "recoverable"}
    services.record_request(session, user.id, body, "visitor_welcome", digest, facts)
    session.flush()
    row = session.get(ApiRequest, (user.id, body.request_id))
    row.response = None
    return JSONResponse({"recovery": recovery.envelope(row)})


def rational(value):
    return Fraction(int(value.get("numerator", "0")), int(value.get("denominator", "1")))


def saved(value):
    return {"numerator": str(value.numerator), "denominator": str(value.denominator)}


def earliest_mutable_activity_date(now, timezone):
    """Conservative bound only: these batches never delete day/workout watermarks."""
    from zoneinfo import ZoneInfo

    return (now.astimezone(UTC) - timedelta(days=30, minutes=5)).astimezone(
        ZoneInfo(timezone)
    ).date() - timedelta(days=6)


def day_summary(session, garden, day, rule, kind):
    key = (garden, day, rule, kind)
    row = session.get(VisitorDaySummary, key)
    if row is None:
        row = VisitorDaySummary(
            garden_id=garden,
            day=day,
            rule_version=rule,
            kind=kind,
            microseconds=0,
            generated={},
            discarded={},
            visits=0,
            tokens=0,
        )
        session.add(row)
        session.flush()
    return row


def roll_settlement(session, row, context):
    """Split the linear interval at UTC midnight with exact rational totals."""
    total_us = (row.end_at - row.start_at) // timedelta(microseconds=1)
    generated = rational(row.detail.get("generated", {}))
    discarded = rational(row.detail.get("discarded", {}))
    start = row.start_at.astimezone(UTC)
    end_at = row.end_at.astimezone(UTC)
    remaining_capacity = rational(row.detail.get("after", {})) - rational(
        row.detail.get("before", {})
    )
    while start < end_at:
        end = min(
            end_at,
            datetime.combine(start.date() + timedelta(days=1), datetime.min.time(), tzinfo=UTC),
        )
        microseconds = (end - start) // timedelta(microseconds=1)
        produced = generated * Fraction(microseconds, total_us)
        # Capacity fills chronologically; never smear discarded overflow across days.
        retained = min(max(Fraction(0), remaining_capacity), produced)
        lost = produced - retained if row.mode == "inactive" else Fraction(0)
        remaining_capacity -= retained
        summary = day_summary(session, row.garden_id, start.date(), context.rule_version, row.mode)
        summary.microseconds += microseconds
        summary.generated = saved(rational(summary.generated) + produced)
        summary.discarded = saved(rational(summary.discarded) + lost)
        start = end
    # Reject malformed legacy evidence rather than silently inventing summaries.
    if (
        row.mode == "inactive"
        and generated - (rational(row.detail["after"]) - rational(row.detail["before"]))
        != discarded
    ):
        raise ValueError("Unreconciled visitor settlement")
    session.delete(row)


def locked(session, owner, garden):
    if (
        session.scalar(select(User).where(User.id == owner).with_for_update(skip_locked=True))
        is None
    ):
        return False
    return (
        session.scalar(select(Garden).where(Garden.id == garden).with_for_update(skip_locked=True))
        is not None
    )


def reconcile(session, owner, garden):
    wallet = session.get(VisitorWallet, owner)
    if wallet:
        from forest_api.collection_models import CollectionEvent

        income = session.scalar(
            select(func.coalesce(func.sum(VisitorWalletEntry.amount), 0)).where(
                VisitorWalletEntry.owner_id == owner
            )
        )
        spending = session.scalar(
            select(func.coalesce(func.sum(CollectionEvent.token_delta), 0)).where(
                CollectionEvent.owner_id == owner
            )
        )
        if income + spending != wallet.tokens:
            raise ValueError("Unreconciled wallet; history retained")
        from sqlalchemy import BigInteger, cast

        for kind, expected in (
            ("active_welcome", wallet.hosted_active),
            ("offline_claim", wallet.hosted_offline),
        ):
            actual = session.scalar(
                select(
                    func.coalesce(
                        func.sum(cast(VisitorRewardEvent.detail["visits"].astext, BigInteger)), 0
                    )
                ).where(VisitorRewardEvent.owner_id == owner, VisitorRewardEvent.kind == kind)
            )
            if actual != expected:
                raise ValueError("Unreconciled lifetime hosted counts; history retained")
    state = session.get(VisitorState, garden)
    if state:
        lots = session.scalar(
            select(func.coalesce(func.sum(VisitorStorageLot.visits), 0)).where(
                VisitorStorageLot.garden_id == garden
            )
        )
        if lots != state.stored_whole:
            raise ValueError("Unreconciled stored visitor lots; history retained")


def visitors(session, *, now, limit, counts):
    cutoff = now - timedelta(days=7)
    remaining = limit
    query = (
        select(VisitorSettlement, Garden.owner_id)
        .join(Garden, Garden.id == VisitorSettlement.garden_id)
        .where(
            Garden.owner_id == session.info["history_owner"],
            VisitorSettlement.end_at <= cutoff,
            VisitorSettlement.end_at - VisitorSettlement.start_at <= timedelta(days=366),
        )
        .order_by(VisitorSettlement.start_at)
        .limit(remaining)
    )
    for row, owner in session.execute(query):
        if not locked(session, owner, row.garden_id):
            continue
        state = session.get(VisitorState, row.garden_id)
        if state is None or row.end_at > state.settled_at:
            counts["skipped"] += 1
            continue
        roll_settlement(session, row, session.get(VisitorContext, row.context_id))
        counts["settlements"] += 1
        remaining -= 1
    session.flush()
    query = (
        select(VisitorRewardEvent, Garden.id)
        .join(Garden, Garden.owner_id == VisitorRewardEvent.owner_id)
        .where(
            Garden.owner_id == session.info["history_owner"],
            VisitorRewardEvent.created_at <= cutoff,
            VisitorRewardEvent.summarized_at.is_(None),
            VisitorRewardEvent.kind.in_(["active_welcome", "offline_claim"]),
        )
        .order_by(VisitorRewardEvent.created_at)
        .limit(max(0, remaining))
    )
    for row, garden in session.execute(query):
        if not locked(session, row.owner_id, garden):
            continue
        detail = row.detail
        lots = detail.get("lots", [])
        if sum(int(lot["visits"]) for lot in lots) != int(detail["visits"]) or sum(
            int(lot["tokens"]) for lot in lots
        ) != int(detail["tokens"]):
            raise ValueError("Unreconciled visitor earning lots")
        for lot in lots:
            summary = day_summary(
                session, garden, row.created_at.astimezone(UTC).date(), lot["ruleVersion"], row.kind
            )
            summary.visits += int(lot["visits"])
            summary.tokens += int(lot["tokens"])
        row.summarized_at = now
        counts["earnings"] += 1
        remaining -= 1
    session.flush()
    query = (
        select(VisitorOpportunity, Garden.owner_id)
        .join(Garden, Garden.id == VisitorOpportunity.garden_id)
        .where(
            Garden.owner_id == session.info["history_owner"],
            VisitorOpportunity.expires_at <= cutoff,
            VisitorOpportunity.status.in_(["expired", "welcomed"]),
            ~select(VisitorRewardEvent.id)
            .where(
                VisitorRewardEvent.source_id == VisitorOpportunity.id,
                VisitorRewardEvent.receipt["recoverable"].as_boolean().is_(False),
            )
            .exists(),
        )
        .order_by(VisitorOpportunity.expires_at)
        .limit(max(0, remaining))
    )
    for row, owner in session.execute(query):
        if not locked(session, owner, row.garden_id):
            continue
        state = session.get(VisitorState, row.garden_id)
        schedule = session.get(VisitorSchedule, row.garden_id)
        covered = (
            state
            and state.ever_issued
            and (
                (row.slot >= 0 and row.slot <= state.last_slot)
                or (
                    row.slot < 0
                    and schedule
                    and -row.slot <= schedule.sequence
                    and schedule.tutorial_used
                )
            )
        )
        if not covered:
            counts["skipped"] += 1
            continue
        if row.status == "welcomed":
            event = session.scalar(
                select(VisitorRewardEvent).where(
                    VisitorRewardEvent.owner_id == owner,
                    VisitorRewardEvent.kind == "active_welcome",
                    VisitorRewardEvent.source_id == row.id,
                )
            )
            if event is None or row.result is None:
                counts["skipped"] += 1
                continue
            if event.receipt is None:
                original = session.get(ApiRequest, (owner, UUID(row.result["requestId"])))
                if original is None or original.recovery_version != 1:
                    event.receipt = {"recoverable": False}
                    counts["legacyProtected"] += 1
                    continue
                event.receipt = {
                    **recovery.completion("visitor_welcome", row.result)["outcome"],
                    "acceptedAt": event.created_at.isoformat(),
                    "recoverable": True,
                }
            if not event.receipt["recoverable"]:
                counts["legacyProtected"] += 1
                continue
            if (
                str(event.id) != row.result["eventId"]
                or event.receipt["tokens"] != row.result["tokens"]
            ):
                raise ValueError("Unreconciled original visitor receipt")
        session.delete(row)
        counts["opportunities"] += 1
        remaining -= 1
    session.flush()
    # Foreign-key dependencies are queried explicitly; never cascade live state.
    for model, date_column, references in [
        (
            VisitorSession,
            VisitorSession.ended_at,
            [
                select(VisitorOpportunity.id).where(
                    VisitorOpportunity.session_id == VisitorSession.id
                )
            ],
        ),
        (
            VisitorContext,
            VisitorContext.effective_at,
            [
                select(VisitorState.garden_id).where(VisitorState.context_id == VisitorContext.id),
                select(VisitorSchedule.garden_id).where(
                    VisitorSchedule.context_id == VisitorContext.id
                ),
                select(VisitorOpportunity.id).where(
                    VisitorOpportunity.context_id == VisitorContext.id
                ),
                select(VisitorSettlement.id).where(
                    VisitorSettlement.context_id == VisitorContext.id
                ),
            ],
        ),
    ]:
        query = (
            select(model, Garden.owner_id)
            .join(Garden, Garden.id == model.garden_id)
            .where(
                Garden.owner_id == session.info["history_owner"],
                date_column <= cutoff,
                *(~ref.exists() for ref in references),
            )
            .order_by(date_column)
            .limit(max(0, remaining))
        )
        for row, owner in session.execute(query):
            if locked(session, owner, row.garden_id):
                session.delete(row)
                counts["dependencies"] += 1
                remaining -= 1
        session.flush()


def growth(session, *, now, limit, counts):
    cutoff = now - timedelta(days=30)
    query = (
        select(PlantGrowthCredit, ActivityCredit, Garden.id)
        .join(ActivityCredit, PlantGrowthCredit.activity_credit_id == ActivityCredit.id)
        .join(Garden, Garden.owner_id == ActivityCredit.owner_id)
        .where(
            Garden.owner_id == session.info["history_owner"], ActivityCredit.accepted_at <= cutoff
        )
        .order_by(ActivityCredit.accepted_at, PlantGrowthCredit.plant_id)
        .limit(limit)
    )
    for row, credit, garden in session.execute(query):
        if not locked(session, credit.owner_id, garden):
            continue
        facts = growth_history.trace(session, row)
        if (
            "profiles" not in facts
            or int(facts.get("awardedMicroUnits", -1)) != row.after_growth - row.before_growth
        ):
            raise ValueError("Unreconciled per-copy growth evidence")
        request = session.get(ApiRequest, (credit.owner_id, credit.request_id))
        if request is None or (
            request.completion is None
            and recovery.completion(request.operation, request.response) is None
        ):
            counts["skipped"] += 1
            continue
        if request.completion is None:
            request.completion = recovery.completion(request.operation, request.response)
        profile = {"profiles": facts["profiles"], "skills": facts.get("skills", {})}
        key = (
            row.plant_id,
            credit.game_date,
            credit.rule_version,
            growth_history.fingerprint(profile),
        )
        summary = session.get(GrowthDaySummary, key)
        if summary is None:
            summary = GrowthDaySummary(
                plant_id=row.plant_id,
                day=credit.game_date,
                rule_version=credit.rule_version,
                profile_key=key[-1],
                profiles=profile,
                awarded=0,
                skill_bonus=0,
                credit_count=0,
            )
            session.add(summary)
        summary.awarded += row.after_growth - row.before_growth
        summary.skill_bonus += int(facts.get("skillBonusGrowthMicroUnits", "0"))
        summary.credit_count += 1
        session.delete(row)  # Rollup + source removal are one transaction: retry cannot add twice.
        counts["growthCredits"] += 1
        session.flush()
    # Pending recap payloads remain immutable and readable regardless of age.
    query = (
        select(RewardRecap, Garden.id)
        .join(Garden, Garden.owner_id == RewardRecap.owner_id)
        .where(
            Garden.owner_id == session.info["history_owner"],
            RewardRecap.acknowledged_at <= now - timedelta(days=7),
            ~RewardRecap.payload.has_key("compacted"),
        )
        .order_by(RewardRecap.acknowledged_at)
        .limit(limit)
    )
    for row, garden in session.execute(query):
        if locked(session, row.owner_id, garden):
            row.payload = {"compacted": 1, "eventId": str(row.event_id)}
            counts["recaps"] += 1
    session.flush()
    pending = select(RewardRecap.id).where(
        RewardRecap.event_id == RewardEvent.id, RewardRecap.acknowledged_at.is_(None)
    )
    query = (
        select(RewardEvent, Garden.id)
        .join(Garden, Garden.owner_id == RewardEvent.owner_id)
        .where(
            Garden.owner_id == session.info["history_owner"],
            RewardEvent.accepted_at <= cutoff,
            ~pending.exists(),
            ~RewardEvent.payload.has_key("compacted"),
        )
        .order_by(RewardEvent.accepted_at)
        .limit(limit)
    )
    for row, garden in session.execute(query):
        if locked(session, row.owner_id, garden):
            row.payload = {
                "compacted": 1,
                "kind": "activity_growth",
                "creditIds": row.payload.get("creditIds", []),
            }
            counts["growthEvents"] += 1


def retire_provenance(session, limit, counts):
    # Shared orphan collection must run even when no account has old credits left.
    session.flush()
    unused = (
        select(GrowthProvenance)
        .where(
            ~select(PlantGrowthCredit.plant_id)
            .where(PlantGrowthCredit.provenance_id == GrowthProvenance.id)
            .exists()
        )
        .order_by(GrowthProvenance.id)
        .limit(limit)
        .with_for_update(skip_locked=True)
    )
    for row in session.scalars(unused):
        if (
            session.scalar(
                select(PlantGrowthCredit.plant_id)
                .where(PlantGrowthCredit.provenance_id == row.id)
                .limit(1)
            )
            is None
        ):
            session.delete(row)
            counts["provenance"] += 1


def maintain(
    session,
    *,
    apply=False,
    visitor_detail=False,
    growth_detail=False,
    responses=False,
    limit=500,
    now=None,
):
    if not 1 <= limit <= 5000:
        raise ValueError("limit must be 1..5000")
    now = now or datetime.now(UTC)
    counts = {
        name: 0
        for name in (
            "settlements",
            "earnings",
            "opportunities",
            "dependencies",
            "growthCredits",
            "recaps",
            "growthEvents",
            "provenance",
            "skipped",
            "legacyProtected",
        )
    }
    counts["dryRun"] = not apply
    if responses:
        counts["responses"] = recovery.maintain(session, apply=apply, limit=limit, now=now)
    # Choose bounded old work, never scan every account. Each transaction owns
    # only one account/garden, avoiding lock inversion with global publication.
    with session.begin():
        owners = set()
        if visitor_detail:
            for model, time in [
                (VisitorSettlement, VisitorSettlement.end_at),
                (VisitorOpportunity, VisitorOpportunity.expires_at),
                (VisitorContext, VisitorContext.effective_at),
                (VisitorSession, VisitorSession.ended_at),
            ]:
                references = []
                eligible = []
                if model is VisitorSettlement:
                    eligible = [
                        VisitorSettlement.end_at - VisitorSettlement.start_at <= timedelta(days=366)
                    ]
                if model is VisitorContext:
                    references = [
                        select(VisitorState.garden_id).where(
                            VisitorState.context_id == VisitorContext.id
                        ),
                        select(VisitorSchedule.garden_id).where(
                            VisitorSchedule.context_id == VisitorContext.id
                        ),
                        select(VisitorOpportunity.id).where(
                            VisitorOpportunity.context_id == VisitorContext.id
                        ),
                        select(VisitorSettlement.id).where(
                            VisitorSettlement.context_id == VisitorContext.id
                        ),
                    ]
                if model is VisitorSession:
                    references = [
                        select(VisitorOpportunity.id).where(
                            VisitorOpportunity.session_id == VisitorSession.id
                        )
                    ]
                if model is VisitorOpportunity:
                    eligible = [VisitorOpportunity.status.in_(["expired", "welcomed"])]
                    references = [
                        select(VisitorRewardEvent.id).where(
                            VisitorRewardEvent.source_id == VisitorOpportunity.id,
                            VisitorRewardEvent.receipt["recoverable"].as_boolean().is_(False),
                        )
                    ]  # noqa: E712
                owners.update(
                    session.scalars(
                        select(Garden.owner_id)
                        .join(model, model.garden_id == Garden.id)
                        .where(
                            time <= now - timedelta(days=7),
                            *eligible,
                            *(~ref.exists() for ref in references),
                        )
                        .order_by(time)
                        .limit(limit)
                    )
                )
            owners.update(
                session.scalars(
                    select(VisitorRewardEvent.owner_id)
                    .where(
                        VisitorRewardEvent.created_at <= now - timedelta(days=7),
                        VisitorRewardEvent.summarized_at.is_(None),
                        VisitorRewardEvent.kind.in_(["active_welcome", "offline_claim"]),
                    )
                    .order_by(VisitorRewardEvent.created_at)
                    .limit(limit)
                )
            )
        if growth_detail:
            owners.update(
                session.scalars(
                    select(ActivityCredit.owner_id)
                    .join(
                        PlantGrowthCredit, PlantGrowthCredit.activity_credit_id == ActivityCredit.id
                    )
                    .where(ActivityCredit.accepted_at <= now - timedelta(days=30))
                    .limit(limit)
                )
            )
            owners.update(
                session.scalars(
                    select(RewardRecap.owner_id)
                    .where(
                        RewardRecap.acknowledged_at <= now - timedelta(days=7),
                        ~RewardRecap.payload.has_key("compacted"),
                    )
                    .limit(limit)
                )
            )
            owners.update(
                session.scalars(
                    select(RewardEvent.owner_id)
                    .where(
                        RewardEvent.accepted_at <= now - timedelta(days=30),
                        ~RewardEvent.payload.has_key("compacted"),
                        ~select(RewardRecap.id)
                        .where(
                            RewardRecap.event_id == RewardEvent.id,
                            RewardRecap.acknowledged_at.is_(None),
                        )
                        .exists(),
                    )
                    .limit(limit)
                )
            )
    remaining = limit
    for owner in sorted(owners):
        if remaining <= 0:
            break
        with session.begin():
            if not session.scalar(text("SELECT pg_try_advisory_xact_lock(711004006)")):
                counts["busy"] = True
                break
            garden = session.scalar(select(Garden.id).where(Garden.owner_id == owner))
            if not locked(session, owner, garden):
                counts["skipped"] += 1
                continue
            reconcile(session, owner, garden)
            session.info["history_owner"] = owner
            session.execute(text("SET LOCAL forest.history_compaction = 'on'"))
            before_count = sum(value for key, value in counts.items() if type(value) is int)
            if visitor_detail:
                visitors(session, now=now, limit=remaining, counts=counts)
            if growth_detail:
                growth(session, now=now, limit=remaining, counts=counts)
            remaining -= max(
                1, sum(value for key, value in counts.items() if type(value) is int) - before_count
            )
            session.flush()
            if not apply:
                session.rollback()
    if growth_detail:
        with session.begin():
            if session.scalar(text("SELECT pg_try_advisory_xact_lock(711004006)")):
                retire_provenance(session, limit, counts)
                session.flush()
                if not apply:
                    session.rollback()
    with session.begin():
        oldest = session.scalar(select(func.min(VisitorSettlement.end_at)))
        counts["oldestVisitorDetailAt"] = oldest.isoformat() if oldest else None
        oldest = session.scalar(
            select(func.min(ActivityCredit.accepted_at)).join(
                PlantGrowthCredit, PlantGrowthCredit.activity_credit_id == ActivityCredit.id
            )
        )
        counts["oldestGrowthDetailAt"] = oldest.isoformat() if oldest else None
    return counts
