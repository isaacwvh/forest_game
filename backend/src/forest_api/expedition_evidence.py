"""Bounded UTC Health facts. Never writes economic watermarks, plants or wallets."""

from datetime import UTC, datetime, timedelta
from fractions import Fraction

from sqlalchemy import select

from forest_api import expeditions, services
from forest_api.activity import CLOCK_TOLERANCE, active_device
from forest_api.activity_inputs import microseconds, subtract, union
from forest_api.errors import ApiError
from forest_api.expedition_models import ExpeditionDay, ExpeditionRun, ExpeditionWorkout
from forest_api.models import User


def eligibility(user, device, run):
    # The native wire uses millisecond ISO dates; round the lower boundary UP,
    # never back into pre-enrollment evidence or into a precision mismatch.
    instant = max(run.starts_at, user.created_at, device.baseline_at or device.enrolled_at)
    return instant + timedelta(microseconds=(-instant.microsecond) % 1000)


def coverage(session, run, now, *, retry_older=False):
    device = active_device(session, run.owner_id)
    if device is None or device.baseline_at is None or now >= run.evidence_until:
        return []
    user = session.get(User, run.owner_id)
    earliest = eligibility(user, device, run)
    health = ("steps_days_3", "run_walk_sessions_3", "monthly_steps_30000")
    if all(run.progress.get(key, {}).get("completedAt") for key in health):
        return []
    rows = {
        r.game_date: r
        for r in session.scalars(
            select(ExpeditionDay).where(
                ExpeditionDay.run_id == run.id, ExpeditionDay.device_id == device.id
            )
        )
    }
    day = (
        max(run.starts_at, earliest)
        .astimezone(UTC)
        .replace(hour=0, minute=0, second=0, microsecond=0)
    )
    result = []
    while day < min(now, run.ends_at):
        end = min(day + timedelta(days=1), run.ends_at, now)
        start = max(day, earliest)
        row = rows.get(day.date())
        recent = day >= now.astimezone(UTC).replace(
            hour=0, minute=0, second=0, microsecond=0
        ) - timedelta(days=6)
        steps = not all(
            run.progress.get(k, {}).get("completedAt")
            for k in ("steps_days_3", "monthly_steps_30000")
        ) and (
            retry_older
            or recent
            or row is None
            or row.steps_through is None
            or row.steps_through < end
        )
        workouts = not run.progress.get("run_walk_sessions_3", {}).get("completedAt") and (
            retry_older
            or recent
            or row is None
            or row.workouts_through is None
            or row.workouts_through < end
        )
        if start < end and (steps or workouts):
            result.append(
                {
                    "gameDate": day.date().isoformat(),
                    "startsAt": start.isoformat(),
                    "through": end.isoformat(),
                    "stepsNeeded": steps,
                    "workoutsNeeded": workouts,
                }
            )
        day += timedelta(days=1)
    return result


def observe_workouts(session, run, user, device, body, now):
    cutoff = max(
        eligibility(user, device, run),
        datetime.fromisoformat(
            device.metric_baselines.get("workouts", {}).get("at", device.enrolled_at.isoformat())
        ),
    )
    existing = list(
        session.scalars(select(ExpeditionWorkout).where(ExpeditionWorkout.run_id == run.id))
    )
    covered = union(
        [
            (datetime.fromisoformat(a), datetime.fromisoformat(b))
            for row in existing
            for a, b in row.intervals
        ]
    )
    for workout in sorted(
        body.workouts, key=lambda w: (w.start, w.source_bundle_identifier, str(w.workout_id))
    ):
        if session.get(ExpeditionWorkout, (run.id, workout.workout_id)) is not None:
            continue
        outcome, intervals, eligible = "ineligible", [], Fraction(0)
        segments = workout.segments if workout.has_segments else [workout]
        kind = workout.original_type
        supported = kind in (37, 52) and segments and all(s.original_type == kind for s in segments)
        contained = any(
            d.starts_at <= workout.start and workout.start < d.through for d in body.days
        )
        if workout.was_user_entered is True:
            outcome = "manual_excluded"
        elif not supported:
            outcome = "unsupported_type"
        elif (
            not contained
            or workout.start < cutoff
            or workout.end >= run.ends_at
            or workout.end > min(body.observed_at, now)
        ):
            outcome = "outside_eligible_interval"
        else:
            for segment in sorted(segments, key=lambda s: (s.start, s.end)):
                if segment.duration_milliseconds == 0:
                    continue
                fresh = list(subtract(segment.start, segment.end, covered))
                density = Fraction(
                    segment.duration_milliseconds * 1000, microseconds(segment.end - segment.start)
                )
                eligible += sum((microseconds(b - a) * density for a, b in fresh), Fraction(0))
                intervals.extend(fresh)
                covered = union([*covered, *fresh])
            complete_duration = sum(s.duration_milliseconds for s in segments) * 1000
            qualifies = (
                eligible >= 900_000_000
                if kind == 52
                else (
                    eligible > 0
                    and eligible >= complete_duration
                    and workout.distance_metres is not None
                    and Fraction(workout.distance_metres) >= 2000
                )
            )
            outcome = "qualified" if qualifies else "below_threshold_or_overlap"
            if qualifies:
                expeditions.contribution(
                    session, run, "run_walk_sessions_3", workout.workout_id, now
                )
        session.add(
            ExpeditionWorkout(
                run_id=run.id,
                workout_id=workout.workout_id,
                payload=workout.model_dump(mode="json", by_alias=True),
                intervals=[[a.isoformat(), b.isoformat()] for a, b in intervals],
                outcome=outcome,
            )
        )
        session.flush()


def submit(session, settings, identity, run_id, body, clock):
    operation = "expedition_evidence:" + str(run_id)
    digest = services.request_hash(operation, body)
    with session.begin():
        user = services.get_user(session, identity, lock=True)
        replay = services.replay(session, user.id, body.request_id, operation, digest)
        if replay is not None:
            return replay
        run = session.get(ExpeditionRun, run_id)
        if run is None or run.owner_id != user.id:
            raise ApiError(404, "expedition_not_found", "Expedition not found")
        now = clock()
        if now >= run.evidence_until:
            raise ApiError(
                409, "expedition_evidence_expired", "This expedition's evidence deadline has passed"
            )
        if (
            body.observed_at > now + CLOCK_TOLERANCE
            or body.observed_at < run.starts_at
            or now - body.observed_at > timedelta(days=39)
        ):
            raise ApiError(422, "invalid_observation", "Take a fresh expedition observation")
        device = active_device(session, user.id)
        if (
            device is None
            or device.id != body.device_id
            or device.installation_id != body.installation_id
            or device.baseline_at is None
        ):
            raise ApiError(409, "inactive_activity_device", "Refresh the enrolled activity device")
        earliest = eligibility(user, device, run)
        for day in body.days:
            start = datetime.combine(day.game_date, datetime.min.time(), UTC)
            if (
                not (start < run.ends_at and start + timedelta(days=1) > run.starts_at)
                or day.starts_at != max(start, earliest)
                or not day.starts_at
                < day.through
                <= min(start + timedelta(days=1), run.ends_at, body.observed_at, now)
            ):
                raise ApiError(
                    422,
                    "invalid_expedition_interval",
                    "Evidence must use the eligible UTC date interval",
                )
        observe_workouts(session, run, user, device, body, now)
        for day in body.days:
            key = run.id, device.id, day.game_date
            row = session.get(ExpeditionDay, key)
            if row is None:
                row = ExpeditionDay(
                    run_id=run.id,
                    device_id=device.id,
                    game_date=day.game_date,
                    starts_at=day.starts_at,
                    steps=0,
                )
                session.add(row)
            if day.steps is not None:
                row.steps = max(row.steps, day.steps)
                row.steps_through = max(row.steps_through or day.through, day.through)
            if day.workouts_complete:
                row.workouts_through = max(row.workouts_through or day.through, day.through)
        session.flush()
        totals = {}
        for row in session.scalars(select(ExpeditionDay).where(ExpeditionDay.run_id == run.id)):
            totals[row.game_date] = totals.get(row.game_date, 0) + row.steps
        expeditions.set_progress(
            session, run, "steps_days_3", sum(v >= 5000 for v in totals.values()), now
        )
        expeditions.set_progress(session, run, "monthly_steps_30000", sum(totals.values()), now)
        result = {
            "requestId": str(body.request_id),
            "runId": str(run.id),
            "progressVersion": run.progress_version,
            "acceptedAt": now.isoformat(),
        }
        services.record_request(session, user.id, body, operation, digest, result)
        return result
