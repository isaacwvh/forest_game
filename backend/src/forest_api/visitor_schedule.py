"""Bounded server-authorized arrival batches. No reward or per-second timer work."""

import math
import secrets
from datetime import timedelta
from fractions import Fraction
from uuid import uuid4

from sqlalchemy import select

from forest_api.calculations import read_remainder
from forest_api.visitor_models import VisitorContext, VisitorOpportunity, VisitorSchedule

MAX_BATCH = 128
MAX_VISIBLE = 12


def jitter():
    # Inclusive symmetric endpoints give exactly one expected arrival-credit.
    return Fraction(1, 2) + Fraction(secrets.randbelow(1_000_001), 1_000_000)


def saved(value):
    return {"numerator": str(value.numerator), "denominator": str(value.denominator)}


def waiting(value):
    # Waiting thresholds range up to 1.5 arrival credits, unlike a water remainder.
    result = Fraction(int(value["numerator"]), int(value["denominator"]))
    if not 0 <= result <= Fraction(3, 2):
        raise ValueError("Invalid scheduled arrival waiting state")
    return result


def rate(context):
    return read_remainder(context.snapshot.get("activeRate", {}))


def pause(session, garden_id, boundary):
    """Freeze the first unfinished waiting interval, cancelling future identities."""
    row = session.get(VisitorSchedule, garden_id)
    if row is None or row.next_at is None:
        return
    context = session.get(VisitorContext, row.context_id)
    future = session.scalars(
        select(VisitorOpportunity)
        .where(
            VisitorOpportunity.garden_id == garden_id,
            VisitorOpportunity.status == "issued",
            VisitorOpportunity.issued_at >= boundary,
        )
        .order_by(VisitorOpportunity.issued_at)
    ).all()
    next_at = future[0].issued_at if future else row.next_at
    if next_at >= boundary:
        row.remaining = saved(
            min(
                Fraction(3, 2),
                Fraction((next_at - boundary) // timedelta(microseconds=1), 1_000_000)
                * rate(context),
            )
        )
    else:
        # A missed unscheduled deadline is not an instant reward on re-entry.
        row.remaining = saved(jitter())
    row.next_at = None
    for opportunity in future:
        opportunity.status = "expired"
    session.flush()


def plan(session, garden, state, active, boundary):
    context = session.get(VisitorContext, state.context_id)
    if context.snapshot["rules"].get("arrival_protocol", 1) != 2 or active.arrival_protocol != 2:
        return
    arrival_rate = rate(context)
    if not arrival_rate:
        return
    row = session.get(VisitorSchedule, garden.id)
    if row is None:
        has_history = (
            session.scalar(
                select(VisitorOpportunity.id)
                .where(VisitorOpportunity.garden_id == garden.id)
                .limit(1)
            )
            is not None
        )
        row = VisitorSchedule(
            garden_id=garden.id,
            context_id=context.id,
            sequence=0,
            remaining={},
            tutorial_used=has_history,
        )
        session.add(row)
        session.flush()
    if row.context_id != context.id and row.next_at is not None:
        pause(session, garden.id, boundary)
    row.context_id = context.id
    if row.next_at is None:
        if not row.tutorial_used:
            remaining = min(Fraction(1), arrival_rate * 5)
            row.tutorial_used = True
        else:
            remaining = waiting(row.remaining) if row.remaining else jitter()
        row.next_at = boundary + timedelta(
            microseconds=math.ceil(remaining / arrival_rate * 1_000_000)
        )
        row.remaining = {}
    if row.next_at < boundary:
        row.next_at = boundary + timedelta(
            microseconds=math.ceil(jitter() / arrival_rate * 1_000_000)
        )
    lifetime = timedelta(seconds=context.snapshot["rules"]["opportunity_seconds"])
    # Every advertised arrival gets its full welcome window inside the lease.
    horizon = active.lease_expires_at - lifetime
    pending = session.scalars(
        select(VisitorOpportunity).where(
            VisitorOpportunity.garden_id == garden.id,
            VisitorOpportunity.status == "issued",
        )
    ).all()
    for _ in range(max(0, MAX_BATCH - len(pending))):
        if row.next_at > horizon:
            break
        occupied = {
            (-item.slot - 1) % MAX_VISIBLE
            for item in pending
            if item.slot < 0 and item.issued_at <= row.next_at < item.expires_at
        }
        for _lane in range(MAX_VISIBLE):
            row.sequence += 1
            if (row.sequence - 1) % MAX_VISIBLE not in occupied:
                break
        else:
            # Bound visual congestion even if a custom future policy is denser.
            row.next_at = min(item.expires_at for item in pending if item.expires_at > row.next_at)
            break
        opportunity = VisitorOpportunity(
            id=uuid4(),
            garden_id=garden.id,
            session_id=active.id,
            context_id=context.id,
            slot=-row.sequence,
            issued_at=row.next_at,
            expires_at=row.next_at + lifetime,
            rule_version=context.rule_version,
            tokens=context.snapshot["rules"]["tokens_per_visit"],
            status="issued",
        )
        session.add(opportunity)
        pending.append(opportunity)
        row.next_at += timedelta(microseconds=math.ceil(jitter() / arrival_rate * 1_000_000))
    session.flush()
