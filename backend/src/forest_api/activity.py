"""B5 transaction-owned steps reconciliation; all mutations lock account before garden."""

from collections.abc import Callable
from datetime import UTC, date, datetime, time, timedelta
from uuid import UUID, uuid4
from zoneinfo import ZoneInfo

from sqlalchemy import select
from sqlalchemy.orm import Session

from forest_api import services
from forest_api.activity_schemas import (
    AcknowledgeRecap,
    ActivityStatus,
    DayResult,
    DeviceDTO,
    EnrolActivity,
    EnrolResult,
    RecapAcknowledgement,
    RecapDTO,
    RecapList,
    SyncActivity,
    SyncResult,
)
from forest_api.auth import Identity
from forest_api.calculations import (
    MAX_INTEGER,
    CalculationRules,
    calculate_growth,
    capped_quantity,
    stage_for,
)
from forest_api.config import Settings
from forest_api.errors import ApiError
from forest_api.models import (
    ActivityCredit,
    ActivityDay,
    ActivityDevice,
    EconomyConfig,
    GardenPlacement,
    OwnedPlant,
    PlantGrowthCredit,
    PlayerProgress,
    RewardEvent,
    RewardRecap,
)
from forest_api.placement import DISABLED_ACCOUNTING, PlacementAccounting, utc_now
from forest_api.schemas import BehaviourDefinition

RECONCILIATION_DAYS = 7
QUEUED_MAX_AGE_DAYS = 30
CLOCK_TOLERANCE = timedelta(minutes=5)


def day_bounds(day: date, timezone: str) -> tuple[datetime, datetime]:
    zone = ZoneInfo(timezone)
    return (
        datetime.combine(day, time.min, zone).astimezone(UTC),
        datetime.combine(day + timedelta(days=1), time.min, zone).astimezone(UTC),
    )


def device_dto(device: ActivityDevice) -> DeviceDTO:
    return DeviceDTO(
        device_id=device.id,
        installation_id=device.installation_id,
        enrolled_at=device.enrolled_at,
        baseline_date=device.baseline_date,
        baseline_observed_at=device.baseline_observed_at,
        baseline_steps=device.baseline_steps,
        ready=device.baseline_date is not None,
    )


def active_device(session: Session, owner: UUID) -> ActivityDevice | None:
    return session.scalar(
        select(ActivityDevice).where(
            ActivityDevice.owner_id == owner, ActivityDevice.revoked_at.is_(None)
        )
    )


def configuration(session: Session, settings: Settings, instant: datetime) -> EconomyConfig:
    row = session.scalar(
        select(EconomyConfig)
        .where(EconomyConfig.effective_at <= instant)
        .order_by(EconomyConfig.effective_at.desc())
        .limit(1)
    )
    if row is None:
        raise ApiError(503, "activity_rules_unavailable", "Activity rules are unavailable")
    rules_for(row, settings)
    return row


def rules_for(row: EconomyConfig, settings: Settings) -> CalculationRules:
    if row.is_fixture and settings.environment not in {"local", "test"}:
        raise ApiError(503, "fixture_rules_disabled", "Development rules are disabled")
    try:
        return CalculationRules.model_validate(row.rules)
    except ValueError as exc:
        raise ApiError(503, "invalid_activity_rules", "Activity rules require maintenance") from exc


def bucket(session: Session, settings: Settings, user, device, day, observed_at) -> ActivityDay:
    row = session.get(ActivityDay, (user.id, day))
    if row is None:
        start, end = day_bounds(day, user.game_timezone)
        # Initial partial day uses the configuration effective at enrolment.
        instant = max(start, device.enrolled_at)
        config = configuration(session, settings, instant)
        row = ActivityDay(
            owner_id=user.id,
            game_date=day,
            game_timezone=user.game_timezone,
            bucket_start=start,
            bucket_end=end,
            device_id=device.id,
            rule_version=config.version,
            baseline_steps=0,
            baseline_credit_steps=0,
            observed_steps=None,
            observed_at=observed_at,
            is_available=False,
            credited_steps=0,
        )
        session.add(row)
        session.flush()
    return row


def establish_baseline(session, settings, user, device, steps, observed_at, boundary):
    check_observation(observed_at, boundary, enrol=True)
    day = boundary.astimezone(ZoneInfo(user.game_timezone)).date()
    if observed_at.astimezone(ZoneInfo(user.game_timezone)).date() != day:
        raise ApiError(422, "baseline_date_mismatch", "Take a fresh current-day observation")
    row = bucket(session, settings, user, device, day, observed_at)
    row.device_id = device.id
    row.baseline_steps = steps
    row.baseline_credit_steps = row.credited_steps
    row.observed_steps, row.observed_at, row.is_available = steps, observed_at, True
    device.baseline_at, device.baseline_observed_at = boundary, observed_at
    device.baseline_date = day
    device.baseline_steps = steps


def check_observation(observed: datetime, boundary: datetime, *, enrol: bool = False):
    if observed > boundary + CLOCK_TOLERANCE:
        raise ApiError(422, "future_observation", "Observation is in the future")
    maximum = CLOCK_TOLERANCE if enrol else timedelta(days=QUEUED_MAX_AGE_DAYS)
    if boundary - observed > maximum:
        raise ApiError(422, "observation_expired", "Take a fresh activity observation")


def enrol(
    session: Session,
    settings: Settings,
    identity: Identity,
    body: EnrolActivity,
    *,
    clock: Callable[[], datetime] = utc_now,
) -> EnrolResult:
    operation = "activity_enrolment"
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return EnrolResult.model_validate(previous)
        services.lock_garden(session, user.id, write=True)
        boundary = clock()
        check_observation(body.observed_at, boundary, enrol=True)
        current = active_device(session, user.id)
        if current and current.installation_id == body.installation_id:
            if body.expected_device_id not in {None, current.id}:
                raise ApiError(409, "stale_activity_device", "Refresh activity device status")
            # A new request cannot reset the baseline of an already enrolled installation.
            result = EnrolResult(request_id=body.request_id, device=device_dto(current))
        else:
            if (current.id if current else None) != body.expected_device_id:
                raise ApiError(409, "stale_activity_device", "Explicit device replacement required")
            configuration(session, settings, boundary)
            if current:
                current.revoked_at = boundary
                session.flush()  # Release partial-unique active owner before inserting replacement.
            device = ActivityDevice(
                id=uuid4(),
                owner_id=user.id,
                installation_id=body.installation_id,
                enrolled_at=boundary,
            )
            session.add(device)
            session.flush()
            if body.steps is not None:
                establish_baseline(
                    session, settings, user, device, body.steps, body.observed_at, boundary
                )
            result = EnrolResult(request_id=body.request_id, device=device_dto(device))
        services.record_request(session, user.id, body, operation, digest, result)
    return result


def checked_add(value: int, delta: int) -> int:
    if value > MAX_INTEGER - delta:
        raise ApiError(503, "counter_exhausted", "Accounting counter requires maintenance")
    return value + delta


def sync(
    session: Session,
    settings: Settings,
    identity: Identity,
    body: SyncActivity,
    *,
    accounting: PlacementAccounting = DISABLED_ACCOUNTING,
    clock: Callable[[], datetime] = utc_now,
) -> SyncResult:
    operation = "activity_sync"
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return SyncResult.model_validate(previous)
        garden = services.lock_garden(session, user.id, write=True)
        catalogue = services.get_catalogue_state(session, settings, lock=True)
        device = active_device(session, user.id)
        if (
            device is None
            or device.id != body.device_id
            or (device.installation_id != body.installation_id)
        ):
            raise ApiError(409, "inactive_activity_device", "Enrol the active reporting device")
        # Account/garden locks serialize bucket creation and mutation with B3 and replacements.
        plants = list(
            session.scalars(
                select(OwnedPlant)
                .join(GardenPlacement, GardenPlacement.plant_id == OwnedPlant.id)
                .where(OwnedPlant.owner_id == user.id, GardenPlacement.garden_id == garden.id)
                .order_by(OwnedPlant.id)
                .with_for_update(of=OwnedPlant)
            )
        )
        boundary = clock()
        check_observation(body.observed_at, boundary)
        today = boundary.astimezone(ZoneInfo(user.game_timezone)).date()
        observed_day = body.observed_at.astimezone(ZoneInfo(user.game_timezone)).date()
        if device.baseline_observed_at and body.observed_at < device.baseline_observed_at:
            raise ApiError(422, "before_activity_baseline", "Observation predates device baseline")
        # All days validate before any accepted changes; queued data must have been a recent
        # bucket when observed, and its observation must be no older than the bounded grace.
        for entry in body.days:
            if entry.game_date > min(today, observed_day):
                raise ApiError(422, "future_game_date", "Game date is in the future")
            if (observed_day - entry.game_date).days >= RECONCILIATION_DAYS:
                raise ApiError(422, "activity_day_expired", "Game date is outside reconciliation")
            minimum = device.baseline_date or today
            if entry.game_date < minimum:
                raise ApiError(422, "before_activity_baseline", "Game date predates baseline")
            if device.baseline_date is None and entry.game_date != today:
                raise ApiError(409, "activity_baseline_required", "Observe today's steps first")

        progress = session.get(PlayerProgress, user.id)
        if progress is None:
            progress = PlayerProgress(owner_id=user.id, activity_steps=0, first_maturity_count=0)
            session.add(progress)
        presenter = services.PlantPresenter(session)
        before = {
            plant.id: (
                plant.growth_micro_units,
                dict(plant.fractional_state),
                presenter.plant(plant, None).growth_stage,
            )
            for plant in plants
        }
        # One pre-credit stage/profile snapshot for the whole upload. B8 effects stay disabled.
        day_results, credits = [], []
        accounting_started = False
        for entry in sorted(body.days, key=lambda item: item.game_date):
            established = False
            if device.baseline_date is None and entry.steps is not None:
                establish_baseline(
                    session, settings, user, device, entry.steps, body.observed_at, boundary
                )
                established = True
            row = bucket(session, settings, user, device, entry.game_date, body.observed_at)
            if row.device_id != device.id and device.baseline_date is not None:
                # Only possible for existing dates on a replaced device; baseline day's row
                # is rebound during enrolment. Earlier replacement dates were rejected above.
                raise ApiError(409, "activity_device_mismatch", "Reconcile device baseline first")
            config = session.get(EconomyConfig, row.rule_version)
            rules = rules_for(config, settings)
            if body.observed_at >= row.observed_at:
                row.observed_at, row.is_available = body.observed_at, entry.steps is not None
                if entry.steps is not None:
                    row.observed_steps = entry.steps
            old = row.credited_steps
            candidate = (
                old
                if entry.steps is None
                else max(
                    old,
                    checked_add(
                        row.baseline_credit_steps, max(0, entry.steps - row.baseline_steps)
                    ),
                )
            )
            water_steps = capped_quantity(candidate, rules.metrics["steps"]) - capped_quantity(
                old, rules.metrics["steps"]
            )
            credit = None
            if candidate > old:
                if not accounting_started:
                    accounting.before_change(session, garden, boundary)
                    accounting_started = True
                credit = ActivityCredit(
                    id=uuid4(),
                    owner_id=user.id,
                    game_date=entry.game_date,
                    device_id=device.id,
                    request_id=body.request_id,
                    rule_version=config.version,
                    start_steps=old,
                    end_steps=candidate,
                    water_steps=water_steps,
                    accepted_at=boundary,
                )
                session.add(credit)
                session.flush()
                credits.append(str(credit.id))
                for plant in plants:
                    growth = presenter.profile(
                        "growth", plant.growth_profile_id, plant.growth_profile_version
                    )
                    if growth.maximum_growth_micro_units != growth.thresholds["adult"]:
                        raise ApiError(
                            503,
                            "unsupported_maturity_profile",
                            "Terminal maturity must match the adult threshold",
                        )
                    behaviour = presenter.profile(
                        "behaviour", plant.behaviour_profile_id, plant.behaviour_profile_version
                    )
                    # Validate supported schema and reject effects until B8, even for direct SQL.
                    prior = plant.growth_micro_units
                    prior_fraction = dict(plant.fractional_state)
                    try:
                        definition = BehaviourDefinition.model_validate(behaviour.rules)
                        result = calculate_growth(
                            {"steps": water_steps},
                            rules.metrics,
                            definition.metric_multipliers,
                            prior,
                            growth.maximum_growth_micro_units,
                            plant.fractional_state,
                        )
                    except ValueError as exc:
                        raise ApiError(
                            503,
                            "invalid_growth_configuration",
                            "Growth configuration requires maintenance",
                        ) from exc
                    plant.growth_micro_units, plant.fractional_state = (
                        result.growth,
                        result.fractional_state,
                    )
                    stage = stage_for(result.growth, growth.thresholds)
                    if prior < growth.thresholds["adult"] <= result.growth and (
                        plant.first_matured_at is None
                    ):
                        plant.first_matured_at = boundary
                        progress.first_maturity_count = checked_add(
                            progress.first_maturity_count, 1
                        )
                    session.add(
                        PlantGrowthCredit(
                            plant_id=plant.id,
                            activity_credit_id=credit.id,
                            before_growth=prior,
                            after_growth=result.growth,
                            context={
                                "profiles": services.profile_refs(plant).model_dump(
                                    mode="json", by_alias=True
                                ),
                                "ruleVersion": config.version,
                                "steps": water_steps,
                                "coefficient": str(definition.metric_multipliers.get("steps", 0)),
                                "normalisation": rules.metrics["steps"].normalisation,
                                "baseWaterMicroUnits": str(
                                    rules.metrics["steps"].water_micro_units
                                ),
                                "snapshotStage": before[plant.id][2],
                                "activityFactor": "1",
                                "waterFactor": "1",
                                "postActivityWaterMicroUnits": str(result.calculated),
                                "calculatedMicroUnits": str(result.calculated),
                                "beforeFraction": prior_fraction,
                                "afterFraction": result.fractional_state,
                                "beforeStage": stage_for(prior, growth.thresholds),
                                "afterStage": stage,
                                "maturityClamped": result.maturity_clamped,
                                "awardedMicroUnits": str(result.awarded),
                            },
                        )
                    )
                row.credited_steps = candidate
                progress.activity_steps = checked_add(progress.activity_steps, candidate - old)
            day_results.append(
                DayResult(
                    game_date=entry.game_date,
                    available=entry.steps is not None,
                    baseline_established=established,
                    newly_eligible_steps=candidate - old,
                    water_steps=water_steps,
                    credited_steps=candidate,
                    rule_version=config.version,
                    activity_credit_id=credit.id if credit else None,
                )
            )

        changed = any(
            (plant.growth_micro_units, plant.fractional_state) != before[plant.id][:2]
            for plant in plants
        )
        if changed:
            garden.state_version = checked_add(garden.state_version, 1)
        session.flush()
        if accounting_started:
            accounting.after_change(session, garden, boundary)
        progress.last_sync_at = boundary
        summary = [
            {
                "plantId": str(plant.id),
                "beforeGrowthMicroUnits": str(before[plant.id][0]),
                "afterGrowthMicroUnits": str(plant.growth_micro_units),
                "awardedGrowthMicroUnits": str(plant.growth_micro_units - before[plant.id][0]),
                "beforeStage": before[plant.id][2],
                "afterStage": presenter.plant(plant, None).growth_stage,
            }
            for plant in plants
            if plant.growth_micro_units > before[plant.id][0]
        ]
        recap_id = None
        if credits:
            event = RewardEvent(
                id=uuid4(),
                owner_id=user.id,
                request_id=body.request_id,
                accepted_at=boundary,
                payload={
                    "kind": "activity_growth",
                    "creditIds": credits,
                    "plants": summary,
                    "activityDays": [
                        day.model_dump(mode="json", by_alias=True)
                        for day in day_results
                        if day.newly_eligible_steps > 0
                    ],
                    "resourceDeltas": {},
                },
            )
            session.add(event)
            session.flush()
            if summary:
                recap_id = uuid4()
                session.add(
                    RewardRecap(
                        id=recap_id,
                        owner_id=user.id,
                        event_id=event.id,
                        created_at=boundary,
                        payload=event.payload,
                    )
                )
        session.flush()
        response = SyncResult(
            request_id=body.request_id,
            accepted_at=boundary,
            device=device_dto(device),
            days=day_results,
            garden=services.present_garden(session, garden, catalogue, presenter),
            activity_steps=str(progress.activity_steps),
            first_maturity_count=progress.first_maturity_count,
            recap_id=recap_id,
        )
        services.record_request(session, user.id, body, operation, digest, response)
    return response


def status(session: Session, identity: Identity, *, clock=utc_now) -> ActivityStatus:
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        device = active_device(session, user.id)
        progress = session.get(PlayerProgress, user.id)
        return ActivityStatus(
            server_time=clock(),
            game_timezone=user.game_timezone,
            supported_metrics=["steps"],
            reconciliation_days=RECONCILIATION_DAYS,
            queued_upload_max_age_days=QUEUED_MAX_AGE_DAYS,
            device=device_dto(device) if device else None,
            activity_steps=str(progress.activity_steps if progress else 0),
            first_maturity_count=progress.first_maturity_count if progress else 0,
            last_sync_at=progress.last_sync_at if progress else None,
        )


def recaps(session: Session, identity: Identity, limit: int, after: UUID | None) -> RecapList:
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        query = select(RewardRecap).where(
            RewardRecap.owner_id == user.id, RewardRecap.acknowledged_at.is_(None)
        )
        if after:
            query = query.where(RewardRecap.id > after)
        rows = list(session.scalars(query.order_by(RewardRecap.id).limit(limit + 1)))
        return RecapList(
            recaps=[
                RecapDTO(recap_id=row.id, created_at=row.created_at, payload=row.payload)
                for row in rows[:limit]
            ],
            next_cursor=rows[limit - 1].id if len(rows) > limit else None,
        )


def acknowledge(
    session: Session, identity: Identity, recap_id: UUID, body: AcknowledgeRecap, *, clock=utc_now
) -> RecapAcknowledgement:
    operation = f"recap_ack:{recap_id}"
    # Operation remains within the existing 100-character durable receipt contract.
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        previous = services.replay(session, user.id, body.request_id, operation, digest)
        if previous is not None:
            return RecapAcknowledgement.model_validate(previous)
        row = session.scalar(
            select(RewardRecap).where(RewardRecap.id == recap_id, RewardRecap.owner_id == user.id)
        )
        if row is None:
            raise ApiError(404, "recap_not_found", "Recap not found")
        if row.acknowledged_at is None:
            row.acknowledged_at = clock()
        result = RecapAcknowledgement(
            request_id=body.request_id, recap_id=recap_id, acknowledged_at=row.acknowledged_at
        )
        services.record_request(session, user.id, body, operation, digest, result)
    return result
