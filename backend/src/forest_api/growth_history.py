"""Shared recent traces and compact, inspectable per-copy outcome facts."""

import hashlib
import json

from sqlalchemy import select

from forest_api.history_models import GrowthProvenance

SHARED = {
    "profiles",
    "ruleVersion",
    "metricRates",
    "metricReceipts",
    "coefficient",
    "normalisation",
    "baseWaterMicroUnits",
    "skills",
    "activityFactor",
    "waterFactor",
}


def fingerprint(value):
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def store(session, credits):
    """All provenance reads/writes are batched, outside recipient calculation loops."""
    payloads, references = {}, []
    for credit in credits:
        shared = {k: v for k, v in credit.context.items() if k in SHARED}
        key = fingerprint(shared)
        payloads[key] = shared
        references.append((credit, key))
    if not payloads:
        return
    existing = set(
        session.scalars(select(GrowthProvenance.id).where(GrowthProvenance.id.in_(payloads)))
    )
    # Account-scoped source provenance includes plant IDs. ON CONFLICT also makes
    # identical neutral shared definitions safe across concurrent accounts.
    from sqlalchemy.dialects.postgresql import insert

    missing = [
        {"id": key, "payload": value}
        for key, value in sorted(payloads.items())
        if key not in existing
    ]
    if missing:
        session.execute(insert(GrowthProvenance).values(missing).on_conflict_do_nothing())
    list(
        session.scalars(
            select(GrowthProvenance.id)
            .where(GrowthProvenance.id.in_(payloads))
            .order_by(GrowthProvenance.id)
            .with_for_update(read=True, key_share=True)
        )
    )
    for credit, key in references:
        credit.context = {k: v for k, v in credit.context.items() if k not in SHARED}
        credit.provenance_id = key
    session.add_all(credits)


def trace(session, credit):
    shared = session.get(GrowthProvenance, credit.provenance_id) if credit.provenance_id else None
    return {**(shared.payload if shared else {}), **credit.context}
