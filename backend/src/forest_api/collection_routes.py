from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from forest_api import collection
from forest_api.auth import Identity
from forest_api.collection_schemas import ExchangeRequest, OpenPackRequest
from forest_api.dependencies import get_identity, get_session
from forest_api.server_clock import request_clock

router = APIRouter(tags=["collection"])


@router.get("/v1/me/collection")
def summary(
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.read(session, request.app.state.settings, identity)


@router.get("/v1/me/packs")
def packs(
    request: Request,
    limit: int = Query(30, ge=1, le=100),
    after: UUID | None = None,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.read(
        session, request.app.state.settings, identity, kind="packs", limit=limit, after=after
    )


@router.get("/v1/me/pack-openings")
def openings(
    request: Request,
    limit: int = Query(30, ge=1, le=100),
    after: UUID | None = None,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.read(
        session, request.app.state.settings, identity, kind="openings", limit=limit, after=after
    )


@router.get("/v1/pack-definitions/{pack_id}/versions/{version}")
def definition(
    pack_id: str,
    version: int,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.read_definition(
        session, request.app.state.settings, identity, pack_id, version
    )


@router.post("/v1/me/exchanges")
def exchange(
    body: ExchangeRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.mutate(
        session, request.app.state.settings, identity, body, request_clock(request, session)
    )


@router.post("/v1/me/packs/{pack_id}/open")
def open_pack(
    pack_id: UUID,
    body: OpenPackRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
):
    return collection.mutate(
        session,
        request.app.state.settings,
        identity,
        body,
        request_clock(request, session),
        pack_id=pack_id,
    )
