from uuid import UUID

from fastapi import APIRouter, Depends, Request
from sqlalchemy.orm import Session

from forest_api import visitors
from forest_api.auth import Identity
from forest_api.dependencies import get_identity, get_session
from forest_api.server_clock import request_clock
from forest_api.visitor_schemas import (
    SessionVisitorRequest,
    StartVisitorSession,
    VisitorRequest,
    VisitorRewardResult,
    VisitorSummary,
)

router = APIRouter(prefix="/v1/me", tags=["visitors"])


@router.get("/visitors", response_model=VisitorSummary)
def read_visitors(
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.read(
        session, request.app.state.settings, identity, request_clock(request, session)
    )


@router.post("/visitor-sessions", response_model=VisitorSummary)
def start(
    body: StartVisitorSession,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        "visitor_start",
        request_clock(request, session),
    )


@router.post("/visitor-sessions/{session_id}/heartbeat", response_model=VisitorSummary)
def heartbeat(
    session_id: UUID,
    body: SessionVisitorRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        "visitor_heartbeat",
        request_clock(request, session),
        target=session_id,
    )


@router.post("/visitor-sessions/{session_id}/end", response_model=VisitorSummary)
def end(
    session_id: UUID,
    body: SessionVisitorRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        "visitor_end",
        request_clock(request, session),
        target=session_id,
    )


@router.post("/visitor-opportunities/{opportunity_id}/welcome", response_model=VisitorRewardResult)
def welcome(
    opportunity_id: UUID,
    body: VisitorRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        "visitor_welcome",
        request_clock(request, session),
        target=opportunity_id,
    )


@router.post("/stored-visits/claim", response_model=VisitorRewardResult)
def claim(
    body: VisitorRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return visitors.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        "visitor_claim",
        request_clock(request, session),
    )
