"""Use cases own transactions and return DTOs before the request session closes."""

import hashlib
import json
from uuid import UUID

from sqlalchemy import select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from forest_api.auth import Identity
from forest_api.calculations import stage_for
from forest_api.config import Settings
from forest_api.errors import ApiError
from forest_api.models import (
    ApiRequest,
    AttractionProfile,
    BehaviourProfile,
    GameCatalogue,
    Garden,
    GardenPlacement,
    GrowthProfile,
    OwnedPlant,
    PlantStage,
    Species,
    User,
    Variant,
)
from forest_api.schemas import (
    DTO,
    STAGES,
    AccountDTO,
    AttractionDefinition,
    BehaviourDefinition,
    CatalogueDTO,
    GardenDTO,
    GrowthDefinition,
    GrowthProgressDTO,
    InventoryDTO,
    PinnedProfiles,
    PlacementDTO,
    PlantDTO,
    ProfileRef,
    RegisterAccount,
    SpeciesDTO,
    StageAssetDTO,
    UpdateProfile,
    UserDTO,
    VariantDTO,
)

PROFILE_MODELS = {
    "growth": GrowthProfile,
    "behaviour": BehaviourProfile,
    "attraction": AttractionProfile,
}


def user_dto(user: User) -> UserDTO:
    return UserDTO(
        user_id=user.id,
        username=user.username,
        display_name=user.display_name,
        game_timezone=user.game_timezone,
        created_at=user.created_at,
    )


def get_user(session: Session, identity: Identity, *, lock: bool = False) -> User:
    query = select(User).where(
        User.auth_issuer == identity.issuer, User.auth_subject == identity.subject
    )
    user = session.scalar(query.with_for_update() if lock else query)
    if user is None:
        raise ApiError(403, "account_required", "Complete account setup first")
    if user.status != "active":
        raise ApiError(403, "account_disabled", "Account is disabled")
    return user


def get_catalogue_state(
    session: Session, settings: Settings, *, lock: bool = False
) -> GameCatalogue:
    catalogue = (
        session.scalar(
            select(GameCatalogue).where(GameCatalogue.id == 1).with_for_update(read=True)
        )
        if lock
        else session.get(GameCatalogue, 1)
    )
    if catalogue is None:
        raise ApiError(503, "catalogue_unavailable", "Game catalogue has not been configured")
    if catalogue.is_fixture and settings.environment not in {"local", "test"}:
        raise ApiError(503, "fixture_catalogue_disabled", "Development catalogue is disabled")
    return catalogue


def lock_garden(session: Session, owner_id: UUID, *, write: bool = False) -> Garden:
    garden = session.scalar(
        select(Garden).where(Garden.owner_id == owner_id).with_for_update(read=not write)
    )
    if garden is None:
        raise ApiError(503, "garden_unavailable", "Account garden is unavailable")
    return garden


def profile_refs(row: Species | OwnedPlant) -> PinnedProfiles:
    return PinnedProfiles(
        **{
            kind: ProfileRef(
                id=getattr(row, f"{kind}_profile_id"),
                version=getattr(row, f"{kind}_profile_version"),
            )
            for kind in PROFILE_MODELS
        }
    )


def award_plant(
    session: Session,
    owner_id: UUID,
    species_id: str,
    variant_id: str,
    source: str,
    reference: str,
) -> OwnedPlant:
    """Internal, transaction-required award; never accepts client growth/profile values."""
    species = session.get(Species, species_id)
    variant = session.get(Variant, (species_id, variant_id))
    if species is None or variant is None or not species.enabled or not variant.enabled:
        raise ApiError(503, "plant_unavailable", "Award catalogue entry is unavailable")
    stages = session.scalars(
        select(PlantStage.stage).where(
            PlantStage.species_id == species_id, PlantStage.variant_id == variant_id
        )
    ).all()
    if set(stages) != set(STAGES):
        raise ApiError(503, "plant_unavailable", "Award stage assets are incomplete")
    pinned = {}
    for kind in PROFILE_MODELS:
        use_override = getattr(variant, f"{kind}_profile_id") is not None
        source_row = variant if use_override else species
        pinned[f"{kind}_profile_id"] = getattr(source_row, f"{kind}_profile_id")
        pinned[f"{kind}_profile_version"] = getattr(source_row, f"{kind}_profile_version")
    plant = OwnedPlant(
        owner_id=owner_id,
        species_id=species_id,
        variant_id=variant_id,
        acquisition_source=source,
        acquisition_reference=reference,
        growth_micro_units=0,
        fractional_state={},
        **pinned,
    )
    session.add(plant)
    session.flush()
    return plant


def owned_plant(
    session: Session, owner_id: UUID, plant_id: UUID, *, lock: bool = False
) -> OwnedPlant:
    query = select(OwnedPlant).where(OwnedPlant.id == plant_id, OwnedPlant.owner_id == owner_id)
    plant = session.scalar(query.with_for_update() if lock else query)
    if plant is None:
        # Identical response for nonexistent and another owner's plant.
        raise ApiError(404, "plant_not_found", "Plant not found")
    return plant


def request_hash(operation: str, body: DTO) -> str:
    payload = body.model_dump(mode="json", by_alias=True, exclude={"request_id"})
    canonical = json.dumps([operation, payload], sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def replay(
    session: Session, user_id: UUID, request_id: UUID, operation: str, payload_hash: str
) -> dict | None:
    record = session.get(ApiRequest, (user_id, request_id))
    if record is None:
        return None
    if record.operation != operation or record.payload_hash != payload_hash:
        raise ApiError(409, "idempotency_conflict", "Request ID was used for different input")
    return record.response


def record_request(
    session: Session, user_id: UUID, body: DTO, operation: str, payload_hash: str, response: DTO
) -> None:
    session.add(
        ApiRequest(
            user_id=user_id,
            request_id=body.request_id,
            operation=operation,
            payload_hash=payload_hash,
            response=response.model_dump(mode="json", by_alias=True),
        )
    )


def username_conflict(error: IntegrityError) -> None:
    if getattr(getattr(error.orig, "diag", None), "constraint_name", None) == (
        "uq_users_username_normalized"
    ):
        raise ApiError(409, "username_unavailable", "Username is unavailable") from error
    raise error


def register_account(
    session: Session, settings: Settings, identity: Identity, body: RegisterAccount
) -> AccountDTO:
    operation = "register_account"
    payload_hash = request_hash(operation, body)
    try:
        with session.begin():
            # Serialise a subject even before its user row exists. Hash collisions only wait.
            identity_key = json.dumps([identity.issuer, identity.subject], separators=(",", ":"))
            session.execute(
                text("SELECT pg_advisory_xact_lock(hashtextextended(:key, 0))"),
                {"key": identity_key},
            )
            user = session.scalar(
                select(User)
                .where(User.auth_issuer == identity.issuer, User.auth_subject == identity.subject)
                .with_for_update()
            )
            if user is not None:
                if user.status != "active":
                    raise ApiError(403, "account_disabled", "Account is disabled")
                previous = replay(session, user.id, body.request_id, operation, payload_hash)
                if previous is not None:
                    return AccountDTO.model_validate(previous)
            else:
                user = User(
                    auth_issuer=identity.issuer,
                    auth_subject=identity.subject,
                    username=body.username,
                    display_name=body.display_name,
                    game_timezone=body.game_timezone,
                )
                session.add(user)
                session.flush()
                catalogue = get_catalogue_state(session, settings)
                session.add(
                    Garden(
                        owner_id=user.id, width=catalogue.board_width, depth=catalogue.board_depth
                    )
                )
                award_plant(
                    session,
                    user.id,
                    catalogue.starter_species_id,
                    catalogue.starter_variant_id,
                    "starter",
                    "initial-starter-v1",
                )
                session.flush()
            garden = session.scalar(select(Garden).where(Garden.owner_id == user.id))
            starter = session.scalar(
                select(OwnedPlant).where(
                    OwnedPlant.owner_id == user.id,
                    OwnedPlant.acquisition_source == "starter",
                    OwnedPlant.acquisition_reference == "initial-starter-v1",
                )
            )
            result = AccountDTO(
                profile=user_dto(user), garden_id=garden.id, starter_plant_id=starter.id
            )
            record_request(session, user.id, body, operation, payload_hash, result)
        return result
    except IntegrityError as exc:
        username_conflict(exc)


def update_profile(session: Session, identity: Identity, body: UpdateProfile) -> UserDTO:
    operation = "update_profile"
    payload_hash = request_hash(operation, body)
    try:
        with session.begin():
            user = get_user(session, identity, lock=True)
            previous = replay(session, user.id, body.request_id, operation, payload_hash)
            if previous is not None:
                return UserDTO.model_validate(previous)
            if body.username is not None:
                user.username = body.username
            if body.display_name is not None:
                user.display_name = body.display_name
            session.flush()
            result = user_dto(user)
            record_request(session, user.id, body, operation, payload_hash, result)
        return result
    except IntegrityError as exc:
        username_conflict(exc)


class PlantPresenter:
    def __init__(self, session: Session):
        self.session = session
        self.profiles = {}
        self.stages = {}

    def profile(self, kind: str, row_id: str, version: int):
        key = (kind, row_id, version)
        if key not in self.profiles:
            self.profiles[key] = self.session.get(PROFILE_MODELS[kind], (row_id, version))
        return self.profiles[key]

    def plant(self, plant: OwnedPlant, placement: GardenPlacement | None) -> PlantDTO:
        growth = self.profile("growth", plant.growth_profile_id, plant.growth_profile_version)
        definition = GrowthDefinition(
            thresholds=growth.thresholds,
            maximum_growth_micro_units=growth.maximum_growth_micro_units,
        )
        stage = stage_for(plant.growth_micro_units, definition.thresholds.model_dump())
        attraction = self.profile(
            "attraction", plant.attraction_profile_id, plant.attraction_profile_version
        )
        attraction_definition = AttractionDefinition(
            stage_attraction=attraction.stage_attraction, gameplay_tags=attraction.gameplay_tags
        )
        stage_key = (plant.species_id, plant.variant_id, stage)
        if stage_key not in self.stages:
            self.stages[stage_key] = self.session.get(PlantStage, stage_key)
        assets = self.stages[stage_key]
        # Resolve from the owned copy's immutable profile, including versions no
        # longer referenced by the currently enabled catalogue.
        stage_index = STAGES.index(stage)
        next_stage = STAGES[stage_index + 1] if stage_index + 1 < len(STAGES) else None
        return PlantDTO(
            plant_id=plant.id,
            species_id=plant.species_id,
            variant_id=plant.variant_id,
            pinned_profiles=profile_refs(plant),
            growth_micro_units=str(plant.growth_micro_units),
            growth_stage=stage,
            growth_progress=GrowthProgressDTO(
                stage_start_micro_units=str(getattr(definition.thresholds, stage)),
                next_stage_micro_units=(
                    str(getattr(definition.thresholds, next_stage)) if next_stage else None
                ),
                maximum_growth_micro_units=str(definition.maximum_growth_micro_units),
            ),
            base_attraction_micro_units=str(getattr(attraction_definition.stage_attraction, stage)),
            contributes_attraction=placement is not None,
            model_key=assets.model_key,
            thumbnail_key=assets.thumbnail_key,
            placement=PlacementDTO(
                garden_id=placement.garden_id,
                x=placement.x,
                y=placement.y,
                rotation_degrees=placement.rotation_degrees,
            )
            if placement
            else None,
        )


def read_inventory(
    session: Session, identity: Identity, limit: int, after: UUID | None
) -> InventoryDTO:
    with session.begin():
        user = get_user(session, identity)
        lock_garden(session, user.id)
        query = select(OwnedPlant).where(
            OwnedPlant.owner_id == user.id,
            ~select(GardenPlacement.plant_id)
            .where(GardenPlacement.plant_id == OwnedPlant.id)
            .exists(),
        )
        if after is not None:
            query = query.where(OwnedPlant.id > after)
        plants = session.scalars(query.order_by(OwnedPlant.id).limit(limit + 1)).all()
        presenter = PlantPresenter(session)
        return InventoryDTO(
            plants=[presenter.plant(plant, None) for plant in plants[:limit]],
            next_cursor=plants[limit - 1].id if len(plants) > limit else None,
        )


def present_garden(
    session: Session,
    garden: Garden,
    catalogue: GameCatalogue,
    presenter: PlantPresenter | None = None,
) -> GardenDTO:
    """Caller holds the garden lock for the entire snapshot/DTO assembly."""
    rows = session.execute(
        select(OwnedPlant, GardenPlacement)
        .join(GardenPlacement, GardenPlacement.plant_id == OwnedPlant.id)
        .where(GardenPlacement.garden_id == garden.id, OwnedPlant.owner_id == garden.owner_id)
        .order_by(OwnedPlant.id)
    ).all()
    presenter = presenter or PlantPresenter(session)
    presented = [presenter.plant(plant, placement) for plant, placement in rows]
    return GardenDTO(
        garden_id=garden.id,
        width=garden.width,
        depth=garden.depth,
        visibility=garden.visibility,
        garden_unit_metres=catalogue.unit_metres,
        catalog_version=catalogue.version,
        layout_version=garden.layout_version,
        state_version=garden.state_version,
        plants=presented,
        total_attraction_micro_units=str(
            sum(int(plant.base_attraction_micro_units) for plant in presented)
        ),
    )


def read_garden(session: Session, settings: Settings, identity: Identity) -> GardenDTO:
    with session.begin():
        user = get_user(session, identity)
        garden = lock_garden(session, user.id)
        catalogue = get_catalogue_state(session, settings, lock=True)
        return present_garden(session, garden, catalogue)


def read_plant(session: Session, identity: Identity, plant_id: UUID) -> PlantDTO:
    with session.begin():
        user = get_user(session, identity)
        lock_garden(session, user.id)
        plant = owned_plant(session, user.id, plant_id)
        placement = session.get(GardenPlacement, plant.id)
        return PlantPresenter(session).plant(plant, placement)


def read_catalogue(session: Session, settings: Settings) -> CatalogueDTO:
    with session.begin():
        catalogue = get_catalogue_state(session, settings)
        species_rows = session.scalars(select(Species).where(Species.enabled).order_by(Species.id))
        result = []
        referenced = {kind: set() for kind in PROFILE_MODELS}
        for species in species_rows:
            defaults = profile_refs(species)
            for kind in referenced:
                ref = getattr(defaults, kind)
                referenced[kind].add((ref.id, ref.version))
            variants = []
            for variant in session.scalars(
                select(Variant)
                .where(Variant.species_id == species.id, Variant.enabled)
                .order_by(Variant.variant_id)
            ):
                overrides = {}
                for kind in referenced:
                    profile_id = getattr(variant, f"{kind}_profile_id")
                    version = getattr(variant, f"{kind}_profile_version")
                    overrides[kind] = (
                        ProfileRef(id=profile_id, version=version) if profile_id else None
                    )
                    if profile_id:
                        referenced[kind].add((profile_id, version))
                variants.append(
                    VariantDTO(
                        variant_id=variant.variant_id,
                        display_name=variant.display_name,
                        description=variant.description,
                        rarity=variant.rarity,
                        asset_catalog_key=variant.asset_catalog_key,
                        asset_catalog_version=variant.asset_catalog_version,
                        profile_overrides=overrides,
                        stages={
                            row.stage: StageAssetDTO(
                                model_key=row.model_key, thumbnail_key=row.thumbnail_key
                            )
                            for row in session.scalars(
                                select(PlantStage).where(
                                    PlantStage.species_id == species.id,
                                    PlantStage.variant_id == variant.variant_id,
                                )
                            )
                        },
                    )
                )
            result.append(
                SpeciesDTO(
                    species_id=species.id,
                    display_name=species.display_name,
                    rarity=species.rarity,
                    description=species.description,
                    clearance_radius=species.clearance_radius,
                    is_fixture=species.is_fixture,
                    default_profiles=defaults,
                    variants=variants,
                )
            )
        profiles = {}
        for kind, keys in referenced.items():
            profiles[kind] = []
            for profile_id, version in sorted(keys):
                row = session.get(PROFILE_MODELS[kind], (profile_id, version))
                if kind == "growth":
                    definition = GrowthDefinition(
                        thresholds=row.thresholds,
                        maximum_growth_micro_units=row.maximum_growth_micro_units,
                    )
                    values = {
                        "thresholdsMicroUnits": {
                            stage: str(value)
                            for stage, value in definition.thresholds.model_dump().items()
                        },
                        "maximumGrowthMicroUnits": str(definition.maximum_growth_micro_units),
                    }
                elif kind == "behaviour":
                    values = BehaviourDefinition.model_validate(row.rules).model_dump(by_alias=True)
                else:
                    definition = AttractionDefinition(
                        stage_attraction=row.stage_attraction, gameplay_tags=row.gameplay_tags
                    )
                    values = {
                        "stageAttractionMicroUnits": {
                            stage: str(value)
                            for stage, value in definition.stage_attraction.model_dump().items()
                        },
                        "gameplayTags": definition.gameplay_tags,
                    }
                profiles[kind].append({"id": profile_id, "version": version, **values})
        return CatalogueDTO(
            catalog_version=catalogue.version,
            is_fixture=catalogue.is_fixture,
            garden_unit_metres=catalogue.unit_metres,
            species=result,
            profiles=profiles,
        )
