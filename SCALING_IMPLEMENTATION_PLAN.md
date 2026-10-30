# Efficient game state and database usage: implementation draft

Prepared 30 October 2026 from the V1 spec v0.28, implementation plan, new scaling
plan, retention proposal and current backend/iOS source. **S1–S3 completed and
functionally accepted by the user on iPhone on 30 October 2026. S4–S6 are source
implemented locally, with validation and server/device acceptance recorded separately.**
See [S4–S6 maintenance and acceptance](backend/SCALING_S4_S6.md).
See [the implementation and acceptance guide](backend/SCALING_S1_S3.md) for the
delivered protocol, explicit migration/maintenance commands, budgets and checklist.
No live database upgrade, automatic cleanup, push or CI run is performed.

## Recommendation

Keep the existing game architecture and reduce the history written around it.
The client already renders locally; the server already settles offline earnings
when needed. The missing work is compact storage, safe recovery after cleanup,
and measured request/query budgets.

The intended result is simple: **save current progress and proof of important
actions; keep detailed explanations and repeated snapshots only temporarily.**

Implement six batches in order. Give each batch its own review and validation.
Start before broader external alpha and before adding substantial reward systems.
A small catalog acceptance/polish batch can finish first. Expect several focused
batches over multiple weeks; estimate effort again after batch S1.

| Order | Batch | Practical result |
| --- | --- | --- |
| S1 | Measure and classify data | Know what consumes space and what must survive |
| S2 | Separate recovery from response snapshots | Delete old response bodies without repeating actions |
| S3 | Use sequenced visitor controls | Stop saving a permanent row for every heartbeat |
| S4 | Compact visitor history | Keep checkpoints, totals and reward proof instead of endless interval detail |
| S5 | Compact growth history and repeated work | Preserve exact plant growth with smaller records and fewer repeated lookups |
| S6 | Backfill, clean up and benchmark | Prove savings and recovery before wider rollout |

S2 and S3 need the most careful backend/iOS coordination. S4 and S5 depend on
those recovery guarantees. Most visible UI behavior stays the same.

## What the review found

| Area | Current behavior | Recommended change |
| --- | --- | --- |
| Request recovery | `api_requests` retains every successful response indefinitely | Keep a bounded response cache and compact completion outcomes |
| Visitor controls | Start, heartbeat and end each create permanent request records | Version the control protocol so old controls can be rejected using a durable sequence, without a lifetime row per heartbeat |
| Visitor accounting | `settle()` writes interval details; old contexts, sessions and opportunities accumulate | Update existing checkpoints and accounting totals; retain recent detail only |
| Visitor rewards | A welcome response is saved both in `api_requests` and `visitor_opportunities.result`, including the summary | Share a compact immutable reward outcome; expire duplicated snapshots safely |
| Activity growth | Each credited day writes detailed JSON for every planted copy; reward events and recaps repeat some information | Keep current per-copy growth and exact accounting state, with compact summaries and temporary calculation traces |
| Reads/calculation | Profile lookups are cached within a presenter, but code still resolves records while processing plants | Measure queries; bulk-load needed records and reuse immutable definitions where this reduces work |

The retention proposal reports a previous seven-day benchmark of **4.358 MB**
added allocation, including **2.023 MB** in `api_requests`. This is a documented
benchmark, not a new measurement of the live database. More than half remained
outside that table, so response expiry alone cannot meet the scaling objective.

Use the current scheduled visitor behavior in
[VISITOR_RESCALE.md](backend/VISITOR_RESCALE.md). It already batches upcoming
arrivals and supports multiple visible visitors. Some older spec/plan text still
describes the earlier single-visitor slot system. Storage work must preserve the
current protocol-2 behavior and compatibility with retained protocol-1 history.

## Rules every batch must preserve

- Each planted copy grows independently under its pinned profiles. Stored plants
  pause growth. Preserve exact fractions, cumulative input caps and credit-time
  membership; late activity does not require replaying historical garden layouts.
- Tokens, packs and progression remain server-authoritative. A timeout or an
  expired response must never create a second reward or purchase.
- Active and offline time cannot both earn. Keep lease boundaries, tutorial-used
  state, arrival timing, stored reward lots, rule changes and immediate confirmed
  welcome feedback. Keep the current heartbeat cadence during this work.
- Preserve seven-date activity reconciliation and the 30-day unresolved-upload
  policy, device replacement, account isolation and monotonic confirmed state.
- Preserve pending recaps, acknowledgement identity, permanent discoveries,
  milestones, original pack outcomes and immutable configuration versions.

## S1 — Measure usage and define the storage contract

Produce a small read-only usage report: rows and physical bytes by table,
including indexes and TOAST; new rows/bytes per operation; query count, response
bytes and transaction duration for a heartbeat, welcome, claim and activity sync.
Separate shared/authentication overhead from game state and retained history.

Classify every table into the following policy. Record dependencies before
allowing cleanup; a foreign key or recovery consumer can make an old row live.

| Category | Examples | Policy |
| --- | --- | --- |
| Current state | Owned plants, placement, wallet, discoveries, milestones, active lease, scheduling cursor, stored lots/fractions | Retain and update |
| Recovery/accounting | Request identities, purchase/opening outcomes, compact reward identities, device baselines, activity/workout deduplication | Retain the minimum necessary proof; define any later retirement separately |
| Recent detail | Full API responses, settlement explanations, per-copy calculation traces, completed recap detail | Expire only after a tested compact replacement exists |
| Diagnostics | Technical logs and cleanup execution history | Bounded retention outside authoritative gameplay records |

Set provisional budgets for rolling caches, core state per inventory size,
durable bytes per reward/purchase, queries per operation and cleanup overhead.
Treat 100–250 KB/account in the architecture proposal as an aspirational budget,
not an established total. Even a seven-day response cache may exceed it.

**Done when:** every table has an owner, retention rule and safe recovery path;
the largest measured contributors determine priorities and numeric targets.

## S2 — Separate completed actions from cached responses

Implement the replay foundation before deleting history:

1. Add a small, versioned completion outcome alongside each supported request's
   operation, UUID, payload hash, target and acceptance time. Make the full
   response expirable. Write the outcome atomically with the action.
2. Define a typed recovery response: original action completed, original result
   identity/amount, and an instruction to refresh current authoritative state.
   A missing response body must never mean “execute again.” Unknown/unfinished
   outcomes remain unresolved; the client retains their pending requests.
3. Update iOS journals/coordinators to understand that response. Recover controls,
   activity, edits and rewards independently. Never replace an uncertain reward
   UUID or replay a historical garden snapshot over newer state.
4. Keep exact replay while a cached response exists. Start with the retention
   proposal's 24-hour control, seven-day ordinary and 30-day activity windows,
   measured from acceptance. Unknown operations remain ineligible for cleanup.
5. Backfill supported old requests. Enable compaction only for compatible clients;
   retain legacy bodies until their recovery path is supported or builds retire.

Reuse immutable collection receipts. Keep small completion records for ordinary
mutations and rewards initially, including zero-visit claims and no-growth syncs.
Those actions may lack another durable event proving they already completed.

**Done when:** a lost response recovered after its cache window never repeats an
action; changed payloads still conflict; queued rewards survive control recovery;
recovered results do not repeat celebration or rewind current state.

## S3 — Stop permanent record growth from visitor controls

This is the next high-value structural change. Expiring a heartbeat's response
while retaining its UUID forever still grows with every minute of play.

Introduce an explicitly versioned **control** protocol for start/heartbeat/end:

- Keep a durable account-level control sequence independent of the existing
  arrival scheduling sequence. Each command includes its expected sequence,
  request identity, installation and session binding. Save the next sequence and
  resulting lease/session atomically under the existing account/garden locks.
- Retain the latest command hash/outcome and a short recent response cache. A
  matching retry resolves completion; a conflicting latest command fails. Older
  sequences return a typed stale-control recovery result and never execute,
  renew a lease, restart a session or close a newer session.
- On stale recovery, iOS clears only the obsolete control, reads current state,
  and checks current foreground eligibility before issuing a genuinely new
  command. Preserve any queued reward request unchanged.
- Serialize control recovery on each client; exercise two installations racing
  from the same sequence. Preserve the single live lease and installation rules.

Specify this wire contract before coding. It changes the old promise of exact,
permanent UUID replay for controls: older commands become safely stale after the
cache window. Keep legacy UUID records for legacy commands and keep the existing
UUID/conflict contract for rewards, edits, activity and purchases. Version control
recovery separately from arrival protocol 2; arrival timing need not change.

Keep heartbeats at ten seconds and leases at 45 seconds under the current rules.
Fifteen active minutes imply roughly **90 heartbeat requests/day** before other
operations. This batch reduces retained rows, not that network request rate.

**Done when:** expired control caches leave no lifetime row per new heartbeat,
and very old starts/ends cannot affect current sessions after restarts or races.

## S4 — Compact visitor accounting and remove obsolete detail

Make current visitor state/checkpoints the authority for settled time. Add compact
account/day/rule accounting summaries for covered active/inactive durations,
generated/discarded visits and earned/claimed totals. Make each summary update
atomic with checkpoint advancement; retries must not add the same interval twice.

- Keep recent settlement explanations for a proposed seven-day diagnostic window.
  After reconciliation, retire older details and stop making every heartbeat a
  permanent settlement record. Split accounting at real rule/context boundaries.
- Preserve live sessions, current contexts, scheduled/visible opportunities,
  fractions, unclaimed rule-pinned lots and tutorial/scheduling cursors. Clean
  closed sessions and unreferenced contexts only after dependent rows retire.
- Delete expired unpaid opportunities only when durable scheduling state proves
  their range cannot be issued again. Compact welcomed opportunities only after
  their original reward can be recovered from a compact durable outcome.
- Store one compact original reward outcome rather than duplicate full summaries
  in the opportunity and request cache. Preserve target-based welcome deduplication
  even when a retry supplies another UUID. Retain zero-claim request outcomes.
- Retain narrow financial events/ledger entries initially. Daily earning summaries
  explain totals; they do not by themselves replace individual reward uniqueness.
- Investigate reusing an unchanged visitor context after moves or growth below a
  stage boundary. Reuse only if all accounting inputs and required provenance
  match; settle old time before any actual input change.

**Done when:** old technical visitor rows plateau at the configured retention
window; wallet/hosted totals and rule-pinned stored amounts reconcile exactly;
no cleanup can reissue or repay a visitor.

## S5 — Compact growth history and reduce repeated calculation work

Keep current plant growth, profile versions, fractions, activity baselines,
per-metric watermarks and workout deduplication. Growth must still be calculated
independently for each planted copy.

- Replace indefinite per-copy verbose JSON with compact accepted-credit facts and
  plant/day/rule summaries. Record recipient identity, actual growth awarded and
  applicable immutable profile/context references. Keep full calculation traces
  temporarily, initially 30 days from acceptance, for diagnostics.
- Do not copy the whole resolved skill/profile explanation into every recipient
  record. Share immutable calculation context where useful; retain compact source
  provenance and actual awards so summaries remain explainable across versions.
- Preserve exact request recovery from S2 before retiring per-credit detail.
  Rollups need an atomic processed-through marker or equivalent uniqueness, so
  rerunning cleanup cannot add growth to summaries twice.
- Compact acknowledged recap payloads after seven days from acknowledgement;
  retain recap/event IDs and acknowledgement state. Leave pending recap payloads
  intact in this batch. Keep lightweight event links when their traces retire.
- Derive the safe activity-day cutoff from the full observation acceptance
  predicate. An observation can be 30 days old and include six earlier game
  dates; seven-day or 30-day watermark deletion alone is unsafe. Include account
  timezone, DST, permitted clock skew and device replacement in boundary tests.
- Retain workout UUID/outcome deduplication and covered intervals initially.
  Bulky workout payload compaction needs a separate provenance/dependency check;
  never erase a UUID simply because its acceptance time is old.
- Profile and bulk-load relevant profiles/assets before plant loops. Cache
  validated immutable definitions by exact version; reuse frozen garden facts and
  resolved factors. Keep per-copy coefficients, caps and fractions independent.
  Avoid new persistent caches until their measured benefit and invalidation are clear.

The spec currently asks for per-plant credit records and detailed modifier
provenance. Update sections 6.2, 6.6, 8 and related validation wording with the
approved compact-history contract before retiring that evidence. This draft does
not silently override those requirements or promise permanent full reconstruction.

**Done when:** identical activity yields identical growth, stages, discoveries and
recaps before/after compaction; temporary traces plateau and query/CPU work falls
where profiling found repetition. Required watermarks/deduplication survive.

## S6 — Migrate, maintain and prove the savings

Ship additive schema and compatible readers first. Backfill compact outcomes and
summaries, reconcile them, then enable cleanup in small restartable batches.
Separate flags for response expiry, visitor detail and growth detail allow a
gradual rollout. Disabling cleanup stops future deletion; it cannot restore
already removed traces, so test backup/restore before enabling removal.

Use one scheduled maintenance mechanism with bounded transactions and the normal
lock order. It must skip unresolved/live/referenced records, tolerate retries and
interruption, and report lag, rows/bytes compacted, failures and unreconciled data.
It must not scan every account or rebuild all summaries on every run.

Validate on isolated PostgreSQL and native iOS recovery paths:

- Lost responses, retries after 25 hours/eight days/31 days, very old control
  sequences, duplicate rewards, empty claims, changed payloads and server restarts.
- Concurrent devices, account switches, sync-versus-store, lease expiry, rule
  publication and cleanup racing a retry/reward. Test exact time boundaries.
- Ledger reconciliation including welcome/claim income, milestone rewards,
  exchange spending and economy conversions; original pack results stay fixed.
- Delayed multi-metric/workout uploads, caps/fractions, pending and acknowledged
  recaps, catalog discovery, and source-of-growth provenance.

Benchmark at least 35 simulated days to fill the 30-day response window, then
90/365-day retained-state scenarios. Model 1,000 MAU with an explicitly stated
DAU/session mix plus inactive stored accounts; include 5/15/60 Garden minutes,
10/15 planted plants, increasing owned inventories, mature high-attraction gardens,
full activity/workouts and packs. Report p50/p95 latency, queries, response bytes,
heap/index/TOAST allocation, dead tuples and maintenance/WAL overhead.

Compare the same workload before and after. Require a measured reduction against
S1's targets, bounded temporary-table growth, no lifetime heartbeat rows under the
new protocol, and preserved gameplay/recovery invariants before broader rollout.
Record executed evidence separately from this proposed acceptance checklist.

## What this can and cannot promise

Temporary response/history storage should settle to a rolling window. Current
state scales with stored accounts and inventory. Compact reward/purchase keys,
workout identities and retained summaries can still grow over account lifetime.
The database will therefore become much smaller, but not strictly constant-size.

High attraction deserves special attention: the configured upper target is 960
arrivals/hour. Fifteen active minutes can therefore produce roughly 240 arrival
identities/day and up to that many welcome outcomes if all are captured, apart
from jitter, lease boundaries and presentation constraints. Heartbeat cleanup alone
will not remove that reward volume.

If narrow reward rows still dominate the measured budget, design a separate
bounded reward-consumption protocol and archival/accounting policy. Do not erase
per-reward keys under a daily total and assume duplicates remain impossible.
Similarly, permanent daily summaries grow by account age; tiering them into older
monthly totals requires an explicit support/history decision.

Do not promise 1,000 users fit a 500 MB database from this draft. Set enrollment
limits only after measuring shared overhead, rolling caches, inventory and
lifetime record growth with operating headroom. Prioritize compact history before
changing database engines, adding Redis/workers or changing visitor timing.

## References for implementation

- Local sources: [architecture proposal](new%20scaling%20plan.md),
  [retention proposal](DATA_RETENTION_PLAN.md),
  [working spec](forest_game_v1_spec.md), [delivery plan](IMPLEMENTATION_PLAN.md).
- Main backend files: `services.py`, `visitors.py`, `visitor_schedule.py`,
  `activity.py`, `activity_inputs.py`, and their model/schema modules under
  `backend/src/forest_api/`.
- Main native files: `VisitorCoordinator.swift`, `ActivitySyncCoordinator.swift`,
  `CollectionCoordinator.swift`, `GardenEditorStore.swift` and `APIClient.swift`
  under `frontend/MovementForest/Services/`, plus contract fixtures/tests.
- Use PostgreSQL's [size functions](https://www.postgresql.org/docs/17/functions-admin.html#FUNCTIONS-ADMIN-DBSIZE)
  to measure tables/indexes rather than JSON length alone. Monitor database versus
  disk/WAL separately, as described in [Supabase's size guide](https://supabase.com/docs/guides/platform/database-size).
- Deletion/updates leave old row versions until vacuum makes their space reusable;
  normal vacuum usually does not shrink the allocated file. Plan maintenance
  around [PostgreSQL's vacuum guidance](https://www.postgresql.org/docs/17/routine-vacuuming.html),
  and avoid routine `VACUUM FULL` in the gameplay maintenance job.
