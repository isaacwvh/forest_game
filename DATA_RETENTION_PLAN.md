# API response retention and database cleanup plan

**Current delivery:** S1–S3 are completed and user accepted. S4–S6 now implement
the separate visitor/growth history work described as future scope below. See
[SCALING_S4_S6.md](backend/SCALING_S4_S6.md) for the current contract, measured
scenarios and explicit maintenance rollout. This original proposal is historical;
it does not enable cleanup on the game database.

Prepared 29 October 2026. **Proposal only; no application code, schema, scheduled
job or existing database contents are changed by this plan.** This is a separate
backend/native hardening batch from catalog discovery.

**30 October implementation update:** the request-cache foundation and bounded
new visitor controls are source implemented in S1–S3. See
[SCALING_S1_S3.md](backend/SCALING_S1_S3.md) for the delivered opt-in/replay policy
and pending native acceptance. The original proposal below remains historical;
new sequenced control caches can be deleted rather than retaining lifetime keys.
No live migration or automatic cleanup has been enabled.

## 1. Recommendation

Expire large saved response bodies by operation, while retaining small durable
completion records. Do not delete every request row older than seven days: several
operations currently use that row as their only reliable replay check.

| Successful operation | Full response retention | After the window |
| --- | --- | --- |
| Visitor start, heartbeat, end | 24 hours after acceptance | Compact completion record; old retries reconcile current session without executing again |
| Visitor welcome and stored-visit claim | 7 days | Completion record plus durable reward identity, original amount and source; never award again |
| Garden edits, account provisioning, profile edits | 7 days | Completion record and operation outcome; refresh current authoritative state without repeating the edit/award |
| Activity sync and activity enrolment | 30 days | Completion record with accepted outcome and references; do not credit again or enrol another device on replay |
| Recap acknowledgement | 7 days | Compact acknowledgement result; do not change rewards or reopen presentation |
| Exchange and pack opening duplicate response cache | 7 days | Use existing permanent collection events, opening records and receipts; retain request conflict checks |
| Unrecognised/future operation | No automatic expiry | Require an explicit policy and tested recovery path before enabling cleanup |

Use server acceptance timestamps, with expiry at `accepted_at + retention` in
UTC. Processing/uncertain operations are not eligible. A rejected attempt that
never committed remains subject to the existing validation/retry rules.

There is no universal optimal window. These are proposed defaults for this app:

- Visitor leases last seconds; 24 hours already allows ample ordinary reconnect
  time without retaining a week of repeated Garden summaries.
- Seven days is a useful ordinary mutation replay/debugging window, provided older
  confirmed operations have a compact recovery path.
- The code currently accepts queued activity observations for **30 days** and
  reconciles seven game dates relative to the observation. Keeping activity
  responses for 30 days respects that workflow. A seven-day reconciliation window
  is not permission to erase all activity/retry state after seven days.
- More detailed retained responses help debugging, but do not improve duplicate
  prevention once a small durable completion record exists.

## 2. Findings that constrain cleanup

`services.replay` looks up `(user_id, request_id)` in `api_requests`, checks the
operation and payload hash, then returns the entire saved JSON response. There
is no current response-expiry behavior or separate compact completion outcome.

All visitor controls use this machinery. Removing an old visitor-start request
could let a delayed retry start a new session. More seriously, removing a stored-
visit claim record could let a delayed retry claim newly accumulated visits as
though it were a new request. Ordinary current-balance checks do not distinguish
that old request from a new action.

Some domain protection already exists: pack exchange/opening has durable
`CollectionEvent` fallback; a welcomed opportunity stores its result; milestone
claims have durable keys. These help but do not cover every operation and do not
justify a blanket deletion. A zero-visit claim still needs a completion record,
even though it created no wallet/reward event.

The native app persists unresolved requests without a fixed seven-day lifetime.
It currently expects normal success DTOs; many terminal 4xx responses clear pending
state as failures. Backend compaction therefore requires explicit native recovery
handling, rather than silently returning a new error and assuming it is safe.

## 3. Data model and replay behavior

Keep the existing request key, operation, payload hash and creation time. Extend
the logical request record with:

- Nullable `response` JSONB for the full response body.
- `response_expires_at`, nullable until an operation has a supported policy.
- A versioned, small `completion` record: confirmed outcome, accepted time,
  applicable event/target/result references, and minimal original result values
  needed to reconcile. No complete Garden/visitor snapshot or Health payload.
- An explicit full/compacted state or compaction timestamp, with constraints so
  a successful row always has a usable completion record.

Index expiry for full responses only. Validate maximum compact-record size so
the replacement cannot quietly become another full JSON snapshot. Existing
creation timestamps serve as legacy acceptance times where that is the only
recorded timestamp; do not substitute the cleanup run's time and extend retention.

At write time, save completion metadata and any domain reward changes in the same
transaction. On a retry:

1. Authenticate and acquire the existing account lock.
2. Check request identity, operation, target binding and payload hash first.
3. If a full response remains, replay it exactly as today.
4. If compacted, return a typed **already completed** recovery result containing
   the original request/result identity and minimal outcome. Never fall through
   into the normal mutation path because `response` is null.
5. A mismatch still returns `idempotency_conflict`. An absent request remains a new
   request only under the existing operation validation rules.

Expose the compact result through a documented recovery response and, if useful,
an owner-only request-status read. Specify and fixture that contract before coding;
the client must distinguish confirmed prior completion from unknown outcome.
For collection operations, reuse the original immutable receipt rather than
inventing a different pack result or adding a duplicate financial ledger.

Compact request keys remain for the life of the account in this first batch.
They preserve the global request-ID conflict contract, including aliases for
retries against already opened packs or welcomed visitors. Account deletion
removes them with other account state. Their smaller size still grows with use;
this proposal bounds full-response retention, not total database lifetime size.

## 4. Native recovery

- Persist the original request UUID/body until a confirmed result or verified
  compact completion is received. A timeout is never proof of non-execution.
- For a completed visitor control, clear only that control request, retain any
  separately queued welcome/claim, fetch current state, then decide whether a
  genuinely new active session is needed. Do not replay an old control as a fresh
  action merely because its snapshot expired.
- For completed welcomes/claims/exchanges/openings, retain the original confirmed
  reward/purchase outcome and reconcile current wallet/inventory state. Never
  mint a new request to recover an uncertain reward or repeat its celebration.
- For completed garden edits, fetch current layout; do not apply the historical
  edit again or overwrite later moves with an obsolete snapshot.
- For completed activity sync, clear only the confirmed upload and reconcile
  current progress/recaps. Do not manufacture another growth credit. Device
  enrolment recovery must not replace the current device or reset the baseline.
- Keep account/server isolation, stale-response guards, original request hashes,
  failed-acknowledgement journals and current quiet cosmetic recovery behavior.

Deploy compatible native recovery before enabling compaction for affected users.
If older native builds remain supported, leave their response bodies intact until
they upgrade or use a tested backward-compatible operation-specific reconstruction.
Measure the storage cost of that compatibility exception; it is not a free window.

## 5. Cleanup job and deployment

1. Add the nullable/cache/completion fields through an explicit Alembic migration.
   Keep compaction disabled. Implement new writes and full/compact replay paths.
2. Backfill completion records from existing response bodies and durable receipts,
   preserving original hashes and logical targets. Retain unsupported or ambiguous
   rows and report them; do not guess a reward outcome.
3. Add native recovery and fixtures. Prove all expiry/retry cases before permitting
   response removal. This changes the long-term replay contract, not game rewards.
4. Provide an operator dry-run showing eligible rows/bytes by operation, missing
   completion metadata and compatibility exclusions.
5. Run one hourly cleanup in small committed batches, initially up to 500 rows per
   transaction and a bounded run duration. Follow user-first locking, skip busy
   accounts, recheck eligibility under lock and avoid overlapping cleanup runs.
   Clear only full response JSON; preserve completion metadata and uniqueness keys.
6. For hosted Supabase, use a protected scheduled job, such as Supabase Cron,
   invoking the same vetted database cleanup function. Provide an explicit local
   maintenance command. Never depend on app startup or an API process staying warm.
7. Keep only seven days of the cleanup job's own execution history. Record counts,
   byte estimates, errors and lag; never log response/Health/authentication bodies.
   Keep monitoring bounded instead of introducing another indefinite log table.
8. Observe live bytes, indexes, TOAST, dead tuples and cleanup lag. Keep normal
   autovacuum effective. Compaction frees space for reuse; it may not immediately
   reduce the reported allocated database size. Do not schedule routine
   `VACUUM FULL`: it rewrites/locks tables and needs separate operational planning.

Unknown operations, missing completion metadata and incompatible clients remain
excluded until explicitly supported. A failed cleanup transaction is safe to retry.
Rollback disables further compaction; already removed snapshots cannot be restored
from completion records. Do not downgrade to a backend/client that requires full
snapshots after enabling compaction without an explicit compatibility plan.

## 6. Capacity estimate for this batch

These are analytical projections from the preceding isolated seven-day benchmark,
not measurements of a new retention implementation or the live Supabase project.
The scenario was 10 planted plants, four daily steps syncs, 15 daily Garden minutes,
approximately half of visible visitors welcomed, with no pack activity/Supabase Auth
in the sample. Heavier use and additional Health inputs can cost more.

Measured added allocation, including indexes:

| Seven-day component | Added space |
| --- | ---: |
| All benchmark tables | 4.358 MB |
| `api_requests` | 2.023 MB |
| Other tables left unchanged by response cleanup | 2.335 MB |

Even eliminating the whole API-request table would leave about **0.334 MB per
active user/day**, roughly **10 MB/month**, in those other tables. Actual response
compaction retains keys/indexes and recent response bodies. Mature gardens and
heavier inputs can also create more visitor records than this initial-week sample.

Use this working budget for the proposed policy:

**Database MB ≈ 60 + U × (2 + 0.45 × D)**

`U` is the number of users active every day throughout the period. `D` is elapsed
days. The 60 MB is an approximate platform/shared starting allowance, not a reading
of the actual project. The 2 MB is a provisional rolling cache allowance per user;
0.45 MB/day budgets unchanged gameplay histories plus compact request metadata
and some workload variation. Start-up cache fills gradually, so the simple formula
overestimates its early days. It does not forecast indefinite plant acquisition,
all auth/session churn, every possible workout workload or maintenance headroom.

| Daily active users | After 30 days | After 90 days | After 365 days |
| ---: | ---: | ---: | ---: |
| 1 | 76 MB | 103 MB | 226 MB |
| 5 | 138 MB | 273 MB | 891 MB |
| 10 | 215 MB | 485 MB | 1.72 GB |
| 20 | 370 MB | 910 MB | 3.39 GB |
| 25 | 448 MB | 1.12 GB | 4.22 GB |
| 50 | 835 MB | 2.19 GB | 8.37 GB |
| 100 | 1.61 GB | 4.31 GB | 16.69 GB |

At a 500 MB limit, this model reaches the ceiling at about **28 users after a
month, 10 after three months, and 2 after a year**. These are mathematical limits,
not safe operating targets. Use a **400 MB planning ceiling** to leave 100 MB for
variation/maintenance: approximately **20 users for a month, 8 for three months,
and 2 for a year**. Compare with the actual project baseline before enrolling users.
Dormant accounts add little new gameplay history but keep what was already saved.

Do not promise hundreds of long-term active users from response expiry alone.
There is no permanent fixed user capacity while the other histories keep growing.

## 7. Separate follow-up for materially larger capacity

If the goal is hundreds of active users on 500 MB, scope a second history
retention/aggregation batch and benchmark it before promising a capacity:

- Daily growth summaries instead of permanent detailed JSON per plant per sync;
  first review current auditing, pinned profiles and recap requirements.
- Preserve current plant/garden progress, discovery and all activity watermarks.
  Delayed observations can refer to days before the 30-day queue horizon: the
  seven-date reconciliation plus 30-day observation age means seven-day watermark
  deletion would be unsafe. Workout deduplication/overlap state needs its own audit.
- Aggregate old visitor settlement details behind an immutable settled-through
  checkpoint. Preserve live contexts, sessions, schedule sequence/slot cursors,
  stored fractions/reward lots and every referenced accounting record.
- Prune expired unpaid opportunities only after confirming they cannot be reissued;
  compact paid opportunity snapshots into recoverable durable reward outcomes.
- Consolidate acknowledged recap payloads while retaining their IDs/ack state.
  Unacknowledged recaps need an explicit presentation-preserving policy.
- Retain authoritative financial ledger, pack/opening receipts, milestones and
  request uniqueness. They also accumulate; a rolling technical-log window does
  not make those records disappear.
- Consider a bounded visitor-control sequence/cursor protocol to eliminate most
  old heartbeat completion keys. A time-based delete without a stale-control
  rejection mechanism is insufficient, particularly for session-start recovery.

These are candidate follow-ups, not changes included in the response-cache batch.
No capacity number for that broader redesign is established by this plan.

## 8. Verification and acceptance

On isolated PostgreSQL, verify exact expiry boundaries for all three windows,
clock/UTC handling, unknown operations, migrations and backfill preservation.
Exercise retries after 25 hours, eight days and 31 days for every operation:
same UUID/input resolves prior completion; changed input/target conflicts; claims
with zero original visits still cannot consume newly earned visits on replay.

Race cleanup with growth, edits, welcomes, claims, pack opening and retry reads.
Force rollback and cleanup interruption. Verify wallet/ledger totals, plant IDs,
growth, placement, daily watermarks, enrolment and recap acknowledgements remain
unchanged by compaction. Confirm no independent commit or changed lock order.

Native tests cover confirmed compact completion versus unknown request, queued
reward behind an expired control, relaunch/account switches, old activity uploads,
stale snapshots and recovery without duplicate animations or new mutation UUIDs.
Keep existing replay fixtures passing inside retention windows. Run relevant
backend growth/collection/visitor/migration suites and native recovery tests.

Benchmark at least 35 simulated days with mixed operations, multiple users and
cleanup running, so the 30-day activity response window reaches steady state.
Measure physical heap/index/TOAST allocation, compact-key growth, dead tuples and
cleanup/WAL overhead, not JSON length alone. Include 5/15/60 Garden minutes,
10/15 plants, full Health inputs, packs, inactive accounts and higher attraction.
Replace the provisional capacity table with measured results before treating it
as an operational user limit. No implementation tests are claimed by this plan.

## Sources

- [Supabase database size](https://supabase.com/docs/guides/platform/database-size):
  approximate fresh-project overhead and database-size accounting.
- [Supabase Cron](https://supabase.com/docs/guides/cron) and
  [Cron quickstart](https://supabase.com/docs/guides/cron/quickstart): scheduled
  maintenance and cleanup of job execution history.
- [PostgreSQL 17 routine vacuuming](https://www.postgresql.org/docs/17/routine-vacuuming.html):
  reusable free space, normal vacuum and the tradeoffs of full table rewrites.
