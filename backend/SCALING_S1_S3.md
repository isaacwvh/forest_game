# Scaling S1–S3: local implementation and acceptance

**Completed — user functional acceptance, 30 October 2026:** the user confirmed
normal play and all requested interruption/reconnect/activity/edit/account flows
on the updated iPhone app. Source was pushed as `5153c59`. This acceptance does
not assert unreported Mac/XCTest/CI results. S4–S6 are tracked separately in
[SCALING_S4_S6.md](SCALING_S4_S6.md). The original handoff below is historical.

Implemented 30 October 2026. Local source only; no push, CI, live migration or
automatic cleanup. Full-history visitor/growth cleanup remains S4–S6.

## What changed

**S1 — Measurements.** `forest storage-report` reads physical table, index and
TOAST/auxiliary allocation, estimated rows and game-table classifications. Add
`--exact` for actual counts (more expensive). The report lists incoming foreign-key
dependencies and distinguishes platform/shared tables. An exhaustive test fails
if a new game table has no classification. `storage_usage.GROUPS` is the explicit
table inventory; it does not authorize deleting any category.

Set `FOREST_OPERATION_METRICS_ENABLED=true` to log payload-free operation samples:
route template, method/status, queries, rows inserted/updated/deleted, SQL time,
transaction time, request time and response bytes. No credentials, Health input,
request bodies or account/installation IDs are recorded. Metrics are off by
default; only the latest 128 samples are held in process memory. Retain exported
technical logs for seven days as an initial operational policy; hosting/log
retention configuration remains part of deployment.

**S2 — Compact recovery.** Migration `0010_compact_recovery` adds bounded
completion outcomes, response expiry and per-request recovery capability.
Full responses replay exactly inside their window. After explicit compaction,
large garden/activity/visitor snapshots become typed prior-completion responses.
iOS validates the UUID/operation and refreshes current state without executing
the old action, creating a replacement reward UUID or replaying effects.
Small account/profile/enrolment/ack/milestone results can replay from their compact
outcome; exchange/opening results resolve the original immutable collection receipt.

**S3 — Bounded visitor controls.** A single `visitor_controls` row per account
tracks a monotonic control sequence and latest command identity/hash. New
start/heartbeat/end requests include `controlProtocol: 1` and
`expectedControlSequence`. Current summaries advertise `controlProtocol` and
`controlSequence`; iOS journals these fields before sending. They are independent
of `arrivalProtocol: 2`, its scheduling cursor and all accepted timing/reward rules.

New control responses are cached for 24 hours. Maintenance can remove these
cache rows entirely because old sequences cannot execute again. Ordinary
mutations, rewards and legacy controls retain compact UUID/hash identities.
The ten-second heartbeat and 45-second lease remain unchanged.

## Wire/recovery contract

Updated clients send `X-Forest-Recovery: 1` on requests. Requests originally
accepted without it retain their full responses even after a later app upgrade.
Backfill adds compact facts but does not retrospectively opt a request into expiry.
This finite compatibility exception is reported/measured rather than silently
discarding older clients' recovery data.

An expired compact snapshot returns HTTP 200 with a separate envelope:

```json
{
  "recovery": {
    "version": 1,
    "status": "completed",
    "requestId": "original-request-uuid",
    "operation": "visitor_claim",
    "acceptedAt": "2026-10-30T12:00:00+00:00",
    "outcome": {"requestId": "original-request-uuid", "eventId": null, "visits": "0", "tokens": "0"},
    "refreshRequired": true
  }
}
```

This bypasses the normal success DTO; APIClient raises a typed recovery signal.
It is never a definitive rejection. Unsupported/malformed recovery, unknown
execution outcomes, failed fresh reads and account switches retain pending work.
A verified completed edit can clear its journal and independently retry refresh;
its historical layout is never reapplied. A verified completed visitor control
clears only itself; a queued welcome/claim remains intact and drains unchanged.
Visitor rewards recover quietly from current wallet state, with original event,
visit and token facts retained in the compact outcome.

For sequenced controls, a retry in the cache window returns its exact response.
After removal, a matching latest command returns `completed`; a changed latest
command UUID/hash returns `idempotency_conflict`. Older/future sequence values
return `stale_control` with the current sequence and no mutation or lease renewal.
`acceptedAt` is null for stale commands, which are not asserted to have executed.
Clients refresh current state and re-evaluate foreground eligibility before a new
control. Sequence races serialize under the account lock; they cannot create two
live sessions or let an old end close a newer session.

Identity is explicitly different for the new control protocol: after its bounded
cache expires, an old control's sequence prevents execution, rather than a permanent
global UUID record. Its historical UUID is not reserved forever across all future
operations. Ordinary operation UUIDs and legacy control UUIDs remain durable and
retain payload/target conflict checks. Never opt rewards/purchases into this
control identity policy.

## Retention and ownership contract

| Records | Authoritative owner / retained proof | S1–S3 policy |
| --- | --- | --- |
| Current state (`storage_usage.GROUPS.current_state`) | Domain services and immutable pinned versions | Keep; update atomically under existing locks |
| Shared configuration (`shared_configuration`) | Controlled version publication | Keep immutable versions and all live references |
| Ordinary requests | `services.replay`, UUID, operation, target-bound payload hash, compact outcome | Full response seven days; compact proof for account lifetime |
| Activity sync/enrolment | Activity service; current watermarks/device baselines plus request identity | Full response 30 days; compact proof for account lifetime |
| Legacy visitor controls | Original request identity/hash | Opted-in responses 24 hours, then compact key; non-opted-in bodies stay full |
| Sequenced visitor controls | Account sequence/latest hash and current lease | Full cache 24 hours, then delete cache row |
| Rewards/claims, including empty claims | Durable original request/event identity and original amounts | Seven-day response; retain compact proof, wallet ledger and domain receipts |
| Exchange/opening | Original collection event/opening/owned-pack records | Seven-day duplicate response; resolve original immutable receipt afterwards |
| Activity/workout recovery (`durable_recovery`) | Device, metric and workout accounting services | Keep watermarks, workout UUIDs, intervals, baselines and receipts; no S4/S5 deletion |
| Visitor/growth/recap detail (`history_requires_replacement`) | Existing settlement/growth/recap consumers and FK dependencies | Keep in S1–S3; later replacement must be reconciled first |
| Unknown operations | Future owning service | No automatic expiry/backfill policy |

Expiry is based on original server acceptance time, never the backfill run time.
Completion JSON has an 8 KiB database-enforced ceiling. No full garden, skill
trace or Health payload belongs in it. Expiry changes require recovery review.

Maintenance holds account locks before touching request rows, skips busy accounts,
and commits a bounded batch. A rollback restores both response and proof.
There is no scheduler yet. Legacy bodies, unsupported data and all accounting
tables stay intact. Do not run maintenance against an unmigrated server.

## Initial budgets and evidence

The reproducible synthetic PostgreSQL sample is
[benchmarks/scaling-s1-baseline.json](benchmarks/scaling-s1-baseline.json). It uses a
single planted launch plant, scheduled protocol 2, a ten-second lease-renewal
cadence and exact table counts. It measures heartbeat, welcome, empty stored claim
and an activity sync. It is a development baseline, not live account usage, a
15-plant load test, p95 latency or a capacity forecast.

Initial review budgets (provisional until the S6 mixed workload):

| Component | Budget / action |
| --- | --- |
| Single-plant query count | Heartbeat <=40; welcome <=40; empty claim <=35; activity sync <=100. Investigate growth beyond these ceilings |
| Compact visitor outcome | Target <=512 bytes JSON; hard completion ceiling 8 KiB for all operations |
| Reference rolling response cache | Target <=2 MiB/active account at 10 plants, four daily syncs, 15 Garden minutes and half of arrivals welcomed; measure before treating it as achieved |
| Core account state | Review target <=250 KiB at 100 owned plants, excluding shared configuration, rolling caches and lifetime receipts; not a total-account guarantee |
| New control cache growth | 90 heartbeats per 15 active minutes; zero lifetime cache rows after 24-hour expiry and explicit maintenance |
| Maintenance | Default 500 candidates/run, maximum 5,000; skip locked accounts; no continuous per-player job |

Physical allocation grows in pages and can be unchanged for an inserted row;
updates/deletes also create dead tuples. Table deltas are allocation observations,
not row-size estimates or reclaimed disk guarantees. S4/S5 remain necessary:
per-welcome financial rows, activity traces and settlement rows still accumulate.

## Local upgrade and validation commands

From the repository root, run portable checks:

```powershell
backend/.venv/Scripts/python.exe -m ruff check backend
backend/.venv/Scripts/python.exe -m ruff format --check backend
backend/.venv/Scripts/python.exe -m pip check
backend/.venv/Scripts/python.exe backend/scripts/validate_visitors_local.py --smoke
backend/.venv/Scripts/python.exe frontend/scripts/validate_frontend.py
backend/.venv/Scripts/python.exe frontend/scripts/check_swift_syntax.py
```

The Windows helper uses only its dedicated test cluster and random disposable
databases; it does not read or upgrade the game database. Its log lives outside
the PostgreSQL data directory so crash recovery cannot fight an open log file.
To regenerate the synthetic measurement artifact, set `FOREST_SCALING_REPORT` to
an output JSON path before running `test_scaling.py` through that helper.

On the game server, after backup and compatible app preparation, use the existing
explicit upgrade flow from `backend/` (these commands were not run on live data):

```powershell
docker compose build api migrate
docker compose run --rm migrate
docker compose up -d --wait --wait-timeout 90 api
docker compose run --rm api forest storage-report --exact
docker compose run --rm api forest compact-requests --limit 500
# Inspect the dry-run counts and finish native acceptance before enabling removal:
docker compose run --rm api forest compact-requests --limit 500 --apply
```

Do not downgrade after sequenced controls or compacted responses have been used:
the migration refuses to remove required recovery proof. Roll back with a
compatible forward fix or a tested backup restore. Stopping maintenance prevents
further removal but does not regenerate deleted response snapshots.

## Acceptance before S4–S6

Run `bash frontend/scripts/test-mac.sh` on a Mac for Apple SDK typechecking,
Debug XCTest/UI and Release checks. Windows syntax/resource checks do not prove
these pass. Use a rebuilt backend at `0010_compact_recovery` and the new native
build for the following real-account/device checks:

- [ ] Existing login, garden, stored plants, discoveries, wallet, packs and pending
  requests survive upgrade. No starter, reward or growth reset occurs.
- [ ] Leave Garden open for 15 minutes. Multiple butterflies arrive and welcome
  once with the same timing/feedback; heartbeat/control sequences increase.
- [ ] Background, open Edit/a modal, disconnect/reconnect and relaunch. No stale
  control restarts visitors while ineligible or renews/closes a newer session.
- [ ] Interrupt a heartbeat with a welcome/claim queued behind it. Relaunch and
  recover the same reward UUID once; no lost reward or repeated celebration.
- [ ] Interrupt welcome, stored claim, exchange and pack opening after submission.
  Retry/relaunch returns the original amount/plant and never pays/spends twice.
- [ ] Interrupt an activity sync and a garden edit. Recover the original requests;
  current growth/layout wins and old results do not rewind either state.
- [ ] Verify activity enrolment/replacement, recap acknowledgement and an old queued
  Health upload. No duplicate growth, baseline reset or redisplayed dismissed recap.
- [ ] Switch accounts while requests are in flight; switch back to recover them.
  No account sees another's state, completion or queued action.
- [ ] With two installations, race entry/controls. One lease wins; stale commands
  cannot affect it. Confirm the losing device can resume after normal lease expiry.
- [ ] On a disposable test account/database, expire caches through the automated
  tests: controls after 25 hours, ordinary requests after eight days and activity
  after 31 days. Include an originally empty claim after new visits accumulate.
  Confirm stale starts/ends are harmless and original outcomes remain recoverable.
- [ ] Run storage report and maintenance dry-run; legacy responses remain full.
  After explicit test cleanup, new expired control-cache rows disappear while
  their single account sequence survives. Ordinary completion keys remain.

Advance to S4–S6 once local regressions and native/device recovery acceptance are
recorded. Passing this batch does not establish the 1,000-MAU storage target.
