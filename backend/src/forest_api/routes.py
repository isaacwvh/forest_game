from uuid import UUID

from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from forest_api import services
from forest_api.auth import Identity
from forest_api.dependencies import get_identity, get_session
from forest_api.errors import ApiError
from forest_api.exact_json import ExactJSONRoute
from forest_api.placement import edit_garden
from forest_api.schemas import (
    AccountDTO,
    CatalogueDTO,
    GardenDTO,
    GardenEditRequest,
    GardenEditResult,
    InventoryDTO,
    PlantDTO,
    RegisterAccount,
    UpdateProfile,
    UserDTO,
)

router = APIRouter()
placement_router = APIRouter(route_class=ExactJSONRoute)
SCHEMA_REVISION = "0001_b1_b2"


@router.get("/health/live", tags=["health"])
def live() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/health/ready", tags=["health"])
def ready(session: Session = Depends(get_session)) -> dict[str, str]:
    try:
        with session.begin():
            revisions = session.scalars(text("SELECT version_num FROM alembic_version")).all()
            if revisions != [SCHEMA_REVISION]:
                raise ApiError(503, "schema_not_ready", "Database schema is not ready")
    except SQLAlchemyError as exc:
        raise ApiError(503, "database_not_ready", "Database is not ready") from exc
    return {"status": "ready"}


@router.post("/v1/accounts", response_model=AccountDTO, tags=["account"])
def register(
    body: RegisterAccount,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> AccountDTO:
    return services.register_account(session, request.app.state.settings, identity, body)


@router.get("/v1/me", response_model=UserDTO, tags=["account"])
def me(
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> UserDTO:
    with session.begin():
        return services.user_dto(services.get_user(session, identity))


@router.patch("/v1/me", response_model=UserDTO, tags=["account"])
def patch_me(
    body: UpdateProfile,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> UserDTO:
    return services.update_profile(session, identity, body)


@router.get("/v1/catalog", response_model=CatalogueDTO, tags=["catalogue"])
def catalogue(
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> CatalogueDTO:
    return services.read_catalogue(session, request.app.state.settings)


@router.get("/v1/me/garden", response_model=GardenDTO, tags=["garden"])
def garden(
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> GardenDTO:
    return services.read_garden(session, request.app.state.settings, identity)


@router.get("/v1/me/inventory", response_model=InventoryDTO, tags=["inventory"])
def inventory(
    limit: int = Query(default=30, ge=1, le=100),
    after: UUID | None = None,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> InventoryDTO:
    return services.read_inventory(session, identity, limit, after)


@router.get("/v1/me/plants/{plant_id}", response_model=PlantDTO, tags=["inventory"])
def plant(
    plant_id: UUID,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> PlantDTO:
    return services.read_plant(session, identity, plant_id)


@placement_router.post("/v1/me/garden/edits", response_model=GardenEditResult, tags=["garden"])
def garden_edits(
    body: GardenEditRequest,
    request: Request,
    identity: Identity = Depends(get_identity),
    session: Session = Depends(get_session),
) -> GardenEditResult:
    return edit_garden(session, request.app.state.settings, identity, body)


router.include_router(placement_router)
