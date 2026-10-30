# B4/B5 activity backend and F5 integration contract

**Scaling update, 30 October 2026:** activity rewards/watermarks and wire success
DTOs are unchanged. Recent per-copy diagnostics now reference shared immutable
`growth_provenance`; use `growth_history.trace(session, credit)` to inspect the
combined recent explanation. Optional maintenance can replace credits older than
30 days with reconciled `growth_day_summaries`, preserving actual awards and
profile/skill provenance. Pending recap payloads, workout identities and required
watermarks remain intact. See [SCALING_S4_S6.md](SCALING_S4_S6.md).

Current update: [typed activity and launch configuration](LAUNCH_ACTIVITY.md),
25 October 2026, migration `0007_activity_launch`. The historical steps-only
contract below remains compatible, with optional daily quantities and workouts
now supported. Activity sync has a 1 MiB limit; other mutations retain 64 KiB.

Original increment, 22 October 2026: steps only were enabled. The generic pure
calculator also tests other canonical metric dimensions; their import handlers,
workouts, boosts, skills and weather remain B8. Visitor production remains B6.
No activity operation creates visitor tokens or seed tickets.

## Update an existing local installation

Run the explicit Alembic migration to `0002_b4_b5`, then `forest seed-dev` for the
local/test calculation fixtures. The seed command is repeat-safe and also adds the
new calculation configuration to an existing development oak catalogue. It does
not reset accounts, placements or growth. Production requires approved catalogue
and calculation configuration; neither fixture is allowed in staging/production.

The API remains FastAPI/SQLAlchemy/PostgreSQL. No cloud resources are provisioned.

## Routes

| Route | Contract |
| --- | --- |
| `POST /v1/activity/enrolments` | Enrol an installation or explicitly replace the current device. Requires request UUID, installation UUID, observed timestamp, optional current-device UUID for replacement and steps or null. |
| `GET /v1/me/activity` | Server time, account game timezone, supported metrics, reconciliation/queue limits, active device/baseline, lifetime activity and first-maturity counters, last successful sync. |
| `POST /v1/activity/sync` | Atomic reconciliation of 1–7 unique game dates. Requires the active device epoch and installation UUID. Returns confirmed garden, accepted day differences, progress and optional recap ID. |
| `GET /v1/me/reward-recaps?limit=30&after=UUID` | Owner-only pending immutable recaps, UUID keyset pagination. Limit 1–100. Start again without a cursor when refreshing for newly created recaps. |
| `POST /v1/reward-recaps/{id}/ack` | Idempotent acknowledgement with a request UUID. Never recalculates or grants growth. |

All mutations share the existing account-wide request-ID namespace. Reusing an ID
for changed input, another operation or another recap produces 409
`idempotency_conflict`. Receipts commit atomically with changes and retain the
original successful response. Replays require verified account ownership but can
succeed after device replacement or after the observation becomes too old.

Mutation bodies are bounded to 64 KiB. Duplicate JSON fields, nonfinite numbers,
unsupported fields/metrics, duplicate dates and invalid numeric types fail.
Steps must be whole JSON integers from 0 to 1,000,000,000; booleans, strings,
fractions and explicit floating-point numeric tokens are rejected. This technical
input bound is separate from the versioned reward cap. HealthKit count quantities
are Doubles and a daily aggregate may have a fractional part. The iOS adapter
validates the raw daily total as finite, nonnegative and within that bound, then
explicitly floors the cumulative total once before integer JSON encoding. For
example, 3,000.75 uploads as 3,000; a later 3,001.9 uploads as 3,001. Never round
individual samples or upload deltas. Use the same rule for enrolment and sync;
null remains unavailable. Saved request bodies/UUIDs are never rewritten when
this client conversion policy changes. Server integer validation is unchanged.
Filter HealthKit report dates before the server's `baselineDate` out of new
uploads; they cannot be credited and would reject the complete batch.

## Enrolment and device replacement

An example body (replace IDs and timestamps with fresh values):

```json
{
  "requestId": "ac142963-c791-414b-bf99-fa66d7708ce4",
  "installationId": "26a43404-5b69-44f6-84b0-3e98cb5475d2",
  "observedAt": "2026-10-22T04:00:00Z",
  "steps": 2000
}
```

The server returns a device UUID (the reporting epoch), installation UUID, baseline
game date, baseline observation timestamp/steps and `ready`. The current-day
cumulative observation is the baseline, not a growth award. Pre-enrolment dates
are ineligible. Initial baseline observations must be fresh within five minutes
and refer to the current account game date; retry a fresh query across midnight.

If steps are unavailable, send null. The device remains pending. The first
available current-day sync establishes its baseline and awards zero; subsequent
increases become eligible. Unavailable observations never establish zero baselines.

One active device per account is enforced both transactionally and by a partial
unique database index. To replace it, supply `expectedDeviceId` equal to its
current UUID, with the replacement installation and a fresh observation. An
outdated expected device returns 409. The old epoch is revoked atomically.
Re-enrolling the same active installation returns its existing baseline and
cannot reset it. A revoked installation can be enrolled again only through an
explicit replacement, producing a fresh epoch/baseline.

Existing daily watermarks are preserved. The new baseline records the already
credited amount as an offset, so only activity above the replacement snapshot is
new. Previous-epoch unsubmitted uploads are rejected; synchronise the old device
before switching where possible. A fresh baseline can leave unrecoverable
unsubmitted activity unrewarded. Completed old requests still replay.

This is an activity-enrolment baseline. Personal activity bonus baselines are not
implemented by B5.

## Cumulative sync and observation windows

```json
{
  "requestId": "72943434-d217-4828-a7bf-9a69a738405f",
  "installationId": "26a43404-5b69-44f6-84b0-3e98cb5475d2",
  "deviceId": "929f73bd-bad6-45a0-8c93-e030355ba471",
  "observedAt": "2026-10-22T05:00:00Z",
  "days": [{ "gameDate": "2026-10-22", "steps": 3000 }]
}
```

With the 2,000 baseline above, this accepts 1,000 eligible steps. With the local
fixture rate that awards 10 water independently to each eligible placed oak.
`steps: null` means unavailable, not zero. Preserve each queued request's exact
payload and UUID for retries. Do not regenerate timestamps under an existing ID.

Server calendar boundaries use the account's IANA game timezone; UTC intervals
are persisted and can be 23 or 25 hours across DST. Client/device timezone changes
do not change the account timezone. Date inputs cannot be future dates.

Normal reconciliation covers the observation's game date and previous six dates.
Unresolved offline observations have a bounded 30-day queue grace measured from
`observedAt`; their included dates must still have been within that seven-day
window when observed. Five minutes of future clock skew is tolerated, without
allowing future game dates. Captures before the active baseline are rejected.
For a pending device, first establish today's baseline before uploading other days.

This queue policy trusts client-reported observation metadata, like the activity
totals themselves. It is not proof of authentic capture time or genuine steps.
Expired new submissions fail explicitly; committed receipts remain replayable.
Any invalid day rejects the complete new request without partial credits. To
revise a rejected batch, use a new request UUID.

The most recent observation timestamp controls diagnostic observed values and
availability. Older queued observations cannot overwrite newer diagnostics.
Credited watermarks never decrease: an uncredited higher older observation can
still advance the watermark under the forgiving correction policy.

## Calculation and persistent state

- Daily step watermarks track accepted eligible quantity, not converted water.
  Daily input caps apply cumulatively before deriving new reward quantity.
- Each placed copy receives the complete new eligible input using its pinned
  growth/behaviour/attraction profiles. Stored copies are never evaluated.
- Only new quantities use current membership. No old credit is redistributed to
  newly placed plants. Empty/adult-only gardens still consume accepted input.
- Activity lifetime counters count accepted eligible steps before the water cap
  and plant-maturity clamp. This definition is deliberate and independent of growth.
- Coefficients and rate quantities use exact decimal semantics, with at most six
  decimal places and bounded coefficient tokens. Rational micro-unit remainders
  persist as numerator/denominator strings. Unrecognised fractional formats fail
  closed, rather than resetting earned fractions.
- Initial B5 rules require maturity maximum to equal the adult threshold. Stage
  is derived from cumulative growth; reaching the maximum clears excess fractions.
- Each day pins a conversion rule version. Late updates retain it. Configuration
  and credit records reject updates in PostgreSQL. New rule versions do not
  recalculate old awards. Do not insert backdated configurations in production.
- Per-copy credits record input/rule/profile references, exact calculated amount,
  neutral factors, fractional state, stage changes and actual maturity-clamped award.
- Garden attraction is the sum of placed-copy pinned stage attraction. Adults
  remain contributors; stored copies contribute zero. The new garden field is
  `totalAttractionMicroUnits` (decimal string).
- A plant-accounting change, including fractional carry, increments `stateVersion`
  once per request. Growth does not increment `layoutVersion` or alter transforms.
- First maturity is recorded once per owned copy. Accepted activity creates growth
  events with empty resource deltas; wallets and currency ledgers are absent.

Account → garden → shared catalogue → UUID-ordered plants is the mutation lock
order shared with B3. Account/garden serialization also protects activity-day and
progress rows, enrolment/replacement and receipt creation. All day changes, credits,
growth, counters, events, recaps and the original receipt commit together.

B3 and B5 use the same injectable accounting interface/server clock. B5 invokes
old-context settlement before growth and future-context refresh afterward, at one
server boundary. The default remains disabled until B6: no visitor time, storage
or currency is created by these callbacks now.

## F5 response handling

F5 development-token integration is now implemented in the native client; see
`frontend/F5_ACCEPTANCE.md` for the Xcode/Tailscale/iPhone/backend walkthrough.
Managed login remains deferred by user decision.

Owned-plant responses now include `growthProgress` resolved from that copy's
pinned immutable growth profile: `stageStartMicroUnits`, nullable
`nextStageMicroUnits` (null for adult), and `maximumGrowthMicroUnits`, all exact
decimal strings. This remains correct when the profile version is no longer
referenced by the enabled catalogue. It is presentation data, not a new reward
calculation or migration. Older synthetic B3 fixtures may omit it.

Sync responses include `acceptedAt`, the device, day results (`newlyEligibleSteps`,
`waterSteps`, watermark, rule and credit IDs), a complete canonical `garden`,
`activitySteps`, `firstMaturityCount` and `recapId` or null. Authoritative growth,
attraction and lifetime step amounts are decimal strings; retain integer precision.

Persist upload payload/UUID before sending. After a timeout, retry exactly. Apply
garden snapshots by versions: an original-response replay can contain an older
garden than a more recent edit. Refresh the garden after recovering old requests.

Pending recaps contain newly accepted day summaries and before/after per-plant
growth/stages. Recover them after reopening even if the original response was
lost. Acknowledge after presentation or skip. Repeated totals produce no new
recap; pure sub-micro-unit carry changes do not create a visible celebration.

Activity status and reads require authentication and are owner-only. No health
observations are returned in another player's garden. Request validation excludes
raw payloads from errors and logs. Production rate limiting, hosted-provider
verification, retention and deletion remain release-readiness work.

## Validation commands

Use an explicit local/CI PostgreSQL admin URL with CREATEDB in
`FOREST_TEST_DATABASE_URL`. Tests and the HTTP walkthrough create/drop only their
own randomly named `forest_test_*` databases, not the admin database.

```powershell
backend/.venv/Scripts/python.exe -m pytest backend/tests -q
backend/.venv/Scripts/ruff.exe check backend
backend/.venv/Scripts/ruff.exe format --check backend
backend/.venv/Scripts/python.exe backend/scripts/smoke_activity.py
```
