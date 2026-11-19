"""Owner-scoped expedition routes; legacy event contracts are unchanged."""

from datetime import timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import select
from sqlalchemy.orm import Session

from forest_api import expeditions, services
from forest_api.auth import Identity
from forest_api.collection_schemas import OpenPackRequest
from forest_api.dependencies import get_identity, get_session
from forest_api.errors import ApiError
from forest_api.expedition_models import ExpeditionRun
from forest_api.expedition_schemas import ExpeditionEvidence
from forest_api.server_clock import request_clock

router = APIRouter(tags=["expeditions"])


def capable(request):
    if request.headers.get("X-Forest-Expeditions") != "1":
        raise ApiError(426, "expedition_update_required", "Update the app to use expeditions")


@router.get("/v1/me/expeditions/current")
def current(
    request: Request,
    retry_older: bool = Query(False, alias="retryOlder"),
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    capable(request)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        garden = services.lock_garden(session, user.id, write=True)
        now = request_clock(request, session)()
        from forest_api.daily_items import settle_due

        settle_due(session, request.app.state.settings, garden, now)
        expeditions.observe_garden(session, garden, now)
        run = expeditions.run_for(session, user.id, now)
        previous = (
            expeditions.run_for(
                session, user.id, expeditions.month_start(now) - timedelta(microseconds=1)
            )
            if run and now < expeditions.month_start(now) + timedelta(days=7)
            else None
        )
        return {
            "serverNow": now.isoformat(),
            "current": expeditions.present(session, run, now, retry_older=retry_older)
            if run
            else None,
            "previous": [expeditions.present(session, previous, now, retry_older=retry_older)]
            if previous and now < previous.evidence_until
            else [],
        }


@router.get("/v1/me/expeditions")
def archive(
    request: Request,
    before: UUID | None = None,
    limit: int = Query(12, ge=1, le=50),
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    capable(request)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        now = request_clock(request, session)()
        query = select(ExpeditionRun).where(ExpeditionRun.owner_id == user.id)
        if before:
            cursor = session.get(ExpeditionRun, before)
            if cursor is None or cursor.owner_id != user.id:
                raise ApiError(404, "expedition_not_found", "Expedition not found")
            query = query.where(ExpeditionRun.month < cursor.month)
        rows = list(session.scalars(query.order_by(ExpeditionRun.month.desc()).limit(limit + 1)))
        return {
            "runs": [expeditions.present(session, r, now) for r in rows[:limit]],
            "nextCursor": str(rows[limit - 1].id) if len(rows) > limit else None,
        }


@router.get("/v1/me/expeditions/{run_id}")
def detail(
    run_id: UUID,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    capable(request)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        run = session.get(ExpeditionRun, run_id)
        if run is None or run.owner_id != user.id:
            raise ApiError(404, "expedition_not_found", "Expedition not found")
        return expeditions.present(session, run, request_clock(request, session)())


@router.post("/v1/me/expeditions/{run_id}/evidence")
def evidence(
    run_id: UUID,
    body: ExpeditionEvidence,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    capable(request)
    from forest_api.expedition_evidence import submit

    return submit(
        session, request.app.state.settings, identity, run_id, body, request_clock(request, session)
    )


@router.post("/v1/me/expeditions/{run_id}/rewards/{entitlement_id}/claim")
def claim(
    run_id: UUID,
    entitlement_id: UUID,
    body: OpenPackRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    capable(request)
    from forest_api.expedition_rewards import claim as grant

    return grant(
        session,
        request.app.state.settings,
        identity,
        run_id,
        entitlement_id,
        body,
        request_clock(request, session),
    )
