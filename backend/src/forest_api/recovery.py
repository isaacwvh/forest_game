"""Bounded completion metadata; maintenance never re-executes a domain operation."""

import json
from datetime import UTC, datetime, timedelta

from sqlalchemy import select

from forest_api.models import ApiRequest, User

CONTROLS = {"visitor_start", "visitor_heartbeat", "visitor_end"}
ORDINARY = {
    "register_account",
    "update_profile",
    "garden_edits",
    "visitor_welcome",
    "visitor_claim",
    "token_exchange",
    "pack_open",
    "activity_sync",
    "activity_enrolment",
}


def retention(operation):
    if operation in CONTROLS:
        return timedelta(hours=24)
    if operation in {"activity_sync", "activity_enrolment"}:
        return timedelta(days=30)
    if operation in {
        "register_account",
        "update_profile",
        "garden_edits",
        "visitor_welcome",
        "visitor_claim",
        "token_exchange",
        "pack_open",
    } or operation.startswith(("recap_ack:", "milestone_claim:")):
        return timedelta(days=7)


def completion(operation, response):
    """Whitelist facts; never retain a garden, skill trace or Health upload."""
    if retention(operation) is None:
        return None
    if operation in {
        "register_account",
        "update_profile",
        "activity_enrolment",
    } or operation.startswith(("recap_ack:", "milestone_claim:")):
        outcome = response
    elif operation in {"token_exchange", "pack_open"}:
        outcome = {k: response[k] for k in ("exchangeId", "openingId") if k in response}
    elif operation in CONTROLS:
        outcome = {"sessionId": (response.get("session") or {}).get("sessionId")}
    else:
        keys = (
            "requestId",
            "eventId",
            "visits",
            "tokens",
            "acceptedAt",
            "recapId",
            "acknowledgedAt",
            "milestoneId",
            "milestoneEventId",
            "tokensEarned",
            "claimedAt",
        )
        outcome = {k: response[k] for k in keys if k in response}
        if "garden" in response:
            outcome["gardenId"] = response["garden"]["gardenId"]
    result = {"version": 1, "outcome": outcome}
    if len(json.dumps(result).encode()) > 8192:
        # Unsupported legacy shapes stay full rather than losing recovery proof.
        return None
    return result


def envelope(record, *, status="completed"):
    return {
        "version": 1,
        "status": status,
        "requestId": str(record.request_id),
        "operation": record.operation,
        "acceptedAt": record.created_at.isoformat(),
        "outcome": record.completion["outcome"],
        "refreshRequired": True,
    }


def maintain(session, *, apply=False, limit=500, now=None):
    """One bounded batch. Lock account before requests, matching mutation writers."""
    if not 1 <= limit <= 5000:
        raise ValueError("limit must be 1..5000")
    now = now or datetime.now(UTC)
    counts = {"examined": 0, "backfilled": 0, "compacted": 0, "deletedControls": 0}
    with session.begin():
        candidates = session.execute(
            select(ApiRequest.user_id, ApiRequest.request_id)
            .where(
                ApiRequest.operation.in_(CONTROLS | ORDINARY)
                | ApiRequest.operation.startswith("recap_ack:")
                | ApiRequest.operation.startswith("milestone_claim:")
            )
            .where(
                (ApiRequest.completion.is_(None))
                | ((ApiRequest.response_expires_at <= now) & ApiRequest.response.is_not(None))
            )
            .order_by(ApiRequest.user_id, ApiRequest.created_at, ApiRequest.request_id)
            .limit(limit)
        ).all()
        for owner, request_id in candidates:
            # Never hold request-row locks while waiting for the account lock.
            if (
                session.scalar(
                    select(User).where(User.id == owner).with_for_update(skip_locked=True)
                )
                is None
            ):
                continue
            row = session.get(ApiRequest, (owner, request_id), populate_existing=True)
            if row is None:
                continue
            counts["examined"] += 1
            facts = row.completion or completion(row.operation, row.response)
            if facts is None:
                continue
            expiry = row.response_expires_at or row.created_at + retention(row.operation)
            if row.completion is None:
                counts["backfilled"] += 1
                if apply:
                    row.completion = facts
                    # Legacy clients never opted in. Their response stays intact.
                    if row.recovery_version == 1:
                        row.response_expires_at = expiry
            if row.recovery_version == 1 and expiry <= now and row.response is not None:
                from forest_api.visitor_models import VisitorControl

                sequenced = row.operation in CONTROLS and session.get(VisitorControl, owner)
                if sequenced and facts.get("sequencedControl"):
                    counts["deletedControls"] += 1
                    if apply:
                        session.delete(row)
                else:
                    counts["compacted"] += 1
                    if apply:
                        row.response = None
        if not apply:
            session.rollback()
    return counts
