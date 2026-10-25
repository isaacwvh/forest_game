"""Optional metrics and recorded duration. No currency and no historical garden replay."""

from collections import defaultdict
from datetime import datetime, timedelta
from decimal import Decimal
from fractions import Fraction
from zoneinfo import ZoneInfo

from forest_api.activity_models import MetricDay, WorkoutDay, WorkoutImport
from forest_api.calculations import capped_quantity, read_remainder, remainder_state
from forest_api.models import EconomyConfig

DAILY_METRICS = {
    "walking_running_distance_km": ("walking_running_distance_metres", 1000, 1_000_000),
    "active_energy_kcal": ("active_energy_kcal", 1000, 1000),
    "flights_climbed": ("flights_climbed", 1, 1),
}
# healthkit-types-v1: preserve original values; strength grouping is explicit.
WORKOUT_TYPES = {
    13: "cycling",
    20: "strength_training",
    24: "hiking",
    37: "running",
    46: "swimming",
    50: "strength_training",
    52: "walking",
    57: "yoga",
}


def step_ready(device):
    return device.metric_baselines.get("steps", {}).get("ready", device.baseline_date is not None)


def set_baseline(device, metric, value):
    device.metric_baselines = {**device.metric_baselines, metric: value}


def ensure_ready(device, user, boundary):
    if device.baseline_date is None:
        device.baseline_at = device.baseline_observed_at = boundary
        device.baseline_date = boundary.astimezone(ZoneInfo(user.game_timezone)).date()
        device.baseline_steps = 0
        set_baseline(device, "steps", {"ready": False})


def metric_row(session, settings, user, device, metric, day, observed, boundary):
    from forest_api.activity import configuration, day_bounds

    key = (user.id, day, metric)
    row = session.get(MetricDay, key)
    if row is None:
        start, _ = day_bounds(day, user.game_timezone)
        baseline = device.metric_baselines[metric]
        instant = max(start, device.enrolled_at, datetime.fromisoformat(baseline["at"]))
        config = configuration(session, settings, instant)
        row = MetricDay(
            owner_id=user.id,
            game_date=day,
            metric=metric,
            device_id=device.id,
            rule_version=config.version,
            baseline=0,
            baseline_credit=0,
            credited=0,
            observed=None,
            observed_at=observed,
        )
        session.add(row)
        session.flush()
    return row


def daily_credits(session, settings, user, device, entry, observed_at, boundary):
    """Returns exact canonical quantities, pinned rates, and observable per-metric receipts."""
    from forest_api.activity import rules_for

    today = boundary.astimezone(ZoneInfo(user.game_timezone)).date()
    quantities, rates, receipts = {}, {}, {}
    for metric, (attribute, scale, canonical_divisor) in DAILY_METRICS.items():
        raw = getattr(entry, attribute)
        value = int(Decimal(str(raw)) * scale) if raw is not None else None
        saved = device.metric_baselines.get(metric)
        established = False
        if saved is None and value is not None and entry.game_date == today:
            ensure_ready(device, user, boundary)
            saved = {"date": today.isoformat(), "at": boundary.isoformat()}
            set_baseline(device, metric, saved)
            established = True
        if saved is None or entry.game_date.isoformat() < saved["date"]:
            receipts[metric] = {
                "available": value is not None,
                "baselineEstablished": False,
                "newlyEligible": "0",
                "waterQuantity": "0",
            }
            continue
        row = metric_row(
            session, settings, user, device, metric, entry.game_date, observed_at, boundary
        )
        if established or row.device_id != device.id:
            # A new reporting installation starts above the old earned watermark.
            if value is None:
                continue
            row.device_id = device.id
            row.baseline, row.baseline_credit = value, row.credited
            established = True
        old = row.credited
        candidate = (
            old if value is None else max(old, row.baseline_credit + max(0, value - row.baseline))
        )
        if observed_at >= row.observed_at:
            row.observed, row.observed_at = value, observed_at
        rules = rules_for(session.get(EconomyConfig, row.rule_version), settings)
        rate = rules.metrics.get(metric)
        credited = Fraction(candidate - old, canonical_divisor)
        water = Fraction(0)
        if rate is not None:
            water = capped_quantity(Fraction(candidate, canonical_divisor), rate) - capped_quantity(
                Fraction(old, canonical_divisor), rate
            )
            rates[metric] = rate
            if water:
                quantities[metric] = water
        row.credited = candidate
        receipts[metric] = {
            "available": value is not None,
            "baselineEstablished": established,
            "observed": str(Fraction(value, canonical_divisor)) if value is not None else None,
            "newlyEligible": str(credited),
            "waterQuantity": str(water),
            "credited": str(Fraction(candidate, canonical_divisor)),
            "ruleVersion": row.rule_version,
        }
    return quantities, rates, receipts


def enrol_optional(session, settings, user, device, body, boundary):
    from forest_api.activity_schemas import ActivityDayInput

    day = boundary.astimezone(ZoneInfo(user.game_timezone)).date()
    if any(getattr(body, attribute) is not None for attribute, _, _ in DAILY_METRICS.values()):
        if body.observed_at.astimezone(ZoneInfo(user.game_timezone)).date() != day:
            from forest_api.errors import ApiError

            raise ApiError(422, "baseline_date_mismatch", "Take a fresh current-day observation")
    entry = ActivityDayInput(
        game_date=day,
        steps=None,
        **{attribute: getattr(body, attribute) for attribute, _, _ in DAILY_METRICS.values()},
    )
    daily_credits(session, settings, user, device, entry, body.observed_at, boundary)
    if body.workouts_available and "workouts" not in device.metric_baselines:
        ensure_ready(device, user, boundary)
        set_baseline(device, "workouts", {"at": boundary.isoformat()})


def subtract(start, end, covered):
    """Subtract a union of previously covered half-open intervals."""
    cursor = start
    for left, right in covered:
        if right <= cursor:
            continue
        if left >= end:
            break
        if left > cursor:
            yield cursor, min(left, end)
        cursor = max(cursor, right)
        if cursor >= end:
            return
    if cursor < end:
        yield cursor, end


def union(intervals):
    result = []
    for start, end in sorted(intervals):
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(end, result[-1][1]))
        else:
            result.append((start, end))
    return result


def microseconds(duration):
    return duration // timedelta(microseconds=1)


def workout_credits(session, settings, user, device, body, boundary):
    from forest_api.activity import configuration, day_bounds, rules_for

    quantities, rates = defaultdict(dict), defaultdict(dict)
    receipts = []
    if not body.workouts_available:
        return quantities, rates, receipts
    if "workouts" not in device.metric_baselines:
        ensure_ready(device, user, boundary)
        set_baseline(device, "workouts", {"at": boundary.isoformat()})
    cutoff = max(
        device.enrolled_at, datetime.fromisoformat(device.metric_baselines["workouts"]["at"])
    )
    observed_day = body.observed_at.astimezone(ZoneInfo(user.game_timezone)).date()
    window_start, _ = day_bounds(observed_day - timedelta(days=6), user.game_timezone)
    earliest = max(cutoff, window_start)
    # Freeze the first accepted identity and chronological/type winner. Later imports
    # cannot reclassify already covered time and award it again under another type.
    for workout in sorted(
        body.workouts, key=lambda w: (w.start, w.source_bundle_identifier, str(w.workout_id))
    ):
        if session.get(WorkoutImport, (user.id, workout.workout_id)) is not None:
            receipts.append({"workoutId": str(workout.workout_id), "status": "already_processed"})
            continue
        outcome = "accepted"
        awarded = Fraction(0)
        if workout.was_user_entered is True:
            outcome = "manual_excluded"
        elif workout.end > body.observed_at or workout.end > boundary:
            outcome = "future_excluded"
        elif workout.end <= earliest:
            outcome = "before_baseline_or_window"
        else:
            segments = workout.segments if workout.has_segments else [workout]
            for segment in sorted(segments, key=lambda s: (s.start, s.end, s.original_type)):
                category = WORKOUT_TYPES.get(segment.original_type)
                if category is None or segment.duration_milliseconds == 0:
                    continue
                metric = "workout_minutes." + category
                start, end = max(segment.start, earliest), min(segment.end, body.observed_at)
                while start < end:
                    day = start.astimezone(ZoneInfo(user.game_timezone)).date()
                    day_start, day_end = day_bounds(day, user.game_timezone)
                    stop = min(day_end, end)
                    row = session.get(WorkoutDay, (user.id, day))
                    if row is None:
                        config = configuration(session, settings, max(day_start, cutoff))
                        row = WorkoutDay(
                            owner_id=user.id,
                            game_date=day,
                            rule_version=config.version,
                            covered_intervals=[],
                            credited_microseconds=0,
                            remainder={},
                        )
                        session.add(row)
                        session.flush()
                    rules = rules_for(session.get(EconomyConfig, row.rule_version), settings)
                    rate = rules.metrics.get(metric)
                    if rate is not None:
                        covered = [
                            (datetime.fromisoformat(a), datetime.fromisoformat(b))
                            for a, b in row.covered_intervals
                        ]
                        fresh = list(subtract(start, stop, covered))
                        # Pauses with no timestamped events use proportional duration
                        # across the parent interval; dated active segments are exact.
                        density = Fraction(
                            segment.duration_milliseconds * 1000,
                            microseconds(segment.end - segment.start),
                        )
                        eligible = sum(
                            (microseconds(b - a) * density for a, b in fresh), Fraction(0)
                        )
                        before = row.credited_microseconds + read_remainder(row.remainder)
                        after = min(
                            Fraction(rules.workout_daily_cap_seconds * 1_000_000), before + eligible
                        )
                        delta = max(Fraction(0), after - before)
                        row.credited_microseconds = after.numerator // after.denominator
                        row.remainder = remainder_state(after - row.credited_microseconds)
                        # Even duration beyond the cap is covered; it cannot become a backlog.
                        row.covered_intervals = [
                            [a.isoformat(), b.isoformat()] for a, b in union([*covered, *fresh])
                        ]
                        if delta:
                            quantities[day][metric] = (
                                quantities[day].get(metric, Fraction(0)) + delta / 60_000_000
                            )
                            rates[day][metric] = rate
                            awarded += delta / 60_000_000
                    start = stop
            if not awarded:
                outcome = "no_new_eligible_minutes"
        session.add(
            WorkoutImport(
                owner_id=user.id,
                workout_id=workout.workout_id,
                accepted_at=boundary,
                payload=workout.model_dump(mode="json", by_alias=True),
                outcome=outcome,
            )
        )
        session.flush()
        receipts.append(
            {
                "workoutId": str(workout.workout_id),
                "status": outcome,
                "newlyEligibleMinutes": str(awarded),
            }
        )
    return quantities, rates, receipts
