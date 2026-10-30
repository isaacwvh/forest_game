# Scaling S4–S6: compact history and bounded maintenance

Prepared 30 October 2026. S1–S3 are completed and functionally user accepted on
iPhone. S4–S6 are implemented in local source. No commit, push, CI run, live
migration or live cleanup is performed by this work. Existing iPhone recovery
support from S1–S3 is reused; no frontend source or game balance changes are needed.

## Delivered behavior

| Batch | Change | Preserved authority |
| --- | --- | --- |
| S4 | Visitor intervals older than seven days roll into exact UTC day/rule/mode summaries. Terminal opportunities, closed sessions and unused contexts can retire after dependency checks | Current settled-through timestamp, leases, arrival cursors/tutorial-used state, exact fractions, stored reward lots, wallet and hosted counters |
| S4 | New paid visitors store a compact immutable receipt rather than a second full summary in the opportunity. Target-based recovery works after opportunity deletion, including another request UUID | Original reward identity, visits/tokens and durable alias conflict checks; no second payment |
| S4 | Moves and growth that leave all visitor accounting inputs unchanged reuse the existing context and future schedule | Membership/stage/skill/rule changes still settle old time before publishing a new context |
| S5 | Recent growth credits share immutable profile/rate/skill provenance; profiles/assets are preloaded and frozen facts reused | Independent per-copy coefficients, maturity caps, fractions, stages and discovery |
| S5 | Credits older than 30 days roll into copy/game-date/rule/profile/skill summaries, then retire atomically with their rollup | Actual awarded growth, skill bonus, recipient identity and applied immutable provenance; durable input/request deduplication |
| S5 | Acknowledged recap detail compacts seven days after ack; old event detail compacts only if no pending recap depends on it | Recap/event IDs, acknowledgement time, original request identity; pending recaps stay intact |
| S6 | One opt-in maintenance entrypoint, bounded transactions per account, independent family flags, dry-run, reconciliation and optional shared worker | Normal account/garden lock order, skip-locked behavior, repeat safety and no per-player background timer |

Migration: **`0011_compact_history`**. It adds visitor/growth summary tables,
temporary shared growth provenance, visitor tutorial history and receipt metadata,
and time indexes. It does not backfill every account synchronously during deploy;
bounded maintenance derives/reconciles old summaries before removing their sources.

Reward amounts, ownership and rule/configuration versions remain immutable at the
database level. Narrow trigger changes permit one-time recovery metadata and
maintenance-only payload compaction; pending recap payloads cannot be compacted.
Ordinary API calls cannot edit old accounting facts. Existing immutability tests
remain applicable, including rejection of no-op writes to immutable reward facts.

## Exact retention and compatibility

- Visitor settlement/terminal detail: seven days, measured from interval end or
  opportunity expiry. Summaries split at UTC midnight and immutable rule boundaries;
  inactive capacity overflow is attributed chronologically with rational precision.
- Growth traces: 30 days from server acceptance. Rollup and source deletion share
  one transaction; retrying maintenance cannot add a credit twice.
- Acknowledged recaps: seven days from acknowledgement, not creation. Pending
  payloads remain readable indefinitely in this batch.
- API response retention and ordinary UUID/hash completion proof follow S1–S3.
  Legacy clients' full responses remain protected. Legacy paid opportunity
  snapshots remain where exact original recovery still needs them.
- New paid welcome aliases receive the existing typed `completed` recovery
  envelope. The alias UUID/hash is committed before returning it. Current state
  refresh stays quiet and never repeats payment or reward effects.
- Expired unpaid opportunities require durable coverage cursors and tutorial state
  before deletion. Scheduled, visible and unresolved opportunities stay live.
- A context/session is removed only after all live/retained foreign-key consumers
  have released it. Current visitor state and scheduling context are never cascaded.
- Activity day/metric watermarks, device baselines, workout UUIDs, provenance
  payloads in workout imports and overlap intervals are retained. The earliest
  mutable activity date accounts for a 30-day-old observation plus its six earlier
  game dates, account timezone/DST and a conservative clock-skew margin. These
  batches do not implement watermark/workout retirement.
- An individual visitor interval longer than 366 days remains as its existing
  compact interval record, rather than expanding into unbounded daily rows in one
  maintenance transaction. Its live accounting checkpoint is unchanged.

Old summaries no longer promise reconstruction of every individual per-sync
calculation. They preserve exact awards and applied profile/skill provenance at
the declared summary granularity. This is now explicit in spec v0.30.

## Reconciliation and failure handling

Before history removal, an account must reconcile wallet balance to positive
wallet entries plus signed collection spending, active/offline hosted counters to
their immutable reward events, and whole stored visits to rule-pinned lots. Growth
rollups verify each source's recorded award against its before/after growth and
require durable request recovery. Visitor lots and original receipts must match.

An inconsistency aborts that account's transaction. A failed or interrupted batch
cannot leave a summary added while its original source remains eligible to add
again. Transactions already completed for earlier accounts remain committed.
Advisory locking prevents competing maintenance batches, and busy game accounts
are skipped rather than waiting while holding other accounts' locks.

Shared provenance uses ordered insert/lock operations. Cleanup locks and rechecks
unreferenced provenance before deletion so concurrent activity cannot lose its
referenced trace. Source/provenance/configuration facts stay immutable until their
declared retirement; no catalog versions are deleted.

The command reports compacted source counts, protected legacy/skipped counts and
oldest retained visitor/growth timestamps. Worker logs include status and elapsed
time. Docker rotates its logs (three 10 MB files). Oldest detail may be intentional
legacy/pending/long-absence retention; investigate persistent lag or failures before
increasing batch size.

Default limit is 500, maximum 5,000. Each family/phase reads bounded candidates;
global source budgeting bounds an invocation, with a few independently bounded
recap/event/provenance phases. A single account transaction can touch up to several
phase limits. Run repeated small batches rather than a massive one-off purge.
Stopping cleanup prevents future removal; it cannot restore erased trace detail.
Downgrades refuse when summaries would strand retired evidence. Use a forward fix
or a verified backup restore.

## Measured scenarios

Reproducible PostgreSQL artifacts:

- [35 days, 5 Garden minutes, 10 planted copies](benchmarks/history-35d.json)
- [90 days, 15 Garden minutes, 15 planted copies](benchmarks/history-90d.json)
- [365 days, 60 Garden minutes, 15 planted copies](benchmarks/history-365d.json)

These materialize synthetic, rotating cohorts with one active day in eight,
four syncs per active day and one captured legacy-rate visit per Garden minute.
The population model is **1,000 MAU / 125 DAU**, with an additional 500 dormant
accounts considered separately. It is not a 1,000-account or concurrent-client
load test. Input history shapes include multiple metrics/workout quantities;
actual input/overlap correctness is covered by the full activity suites.

Each scenario measures exact row counts, physical heap/index/TOAST allocation,
logical retained row bytes, dead-tuple estimates, WAL positions, maintenance time
and read latency. Each performs a real custom-format PostgreSQL backup and restore
to a separate random disposable database, checking restored row counts, balances
and storage. This tests restoration without resetting or rewriting a game DB.

Final local measured table allocation (decimal MB):

| Horizon | Before cleanup | Working files after cleanup | Restored retained data |
| --- | ---: | ---: | ---: |
| 35 days | 3.13 | 3.24 | 2.77 |
| 90 days | 6.92 | 7.54 | 3.64 |
| 365 days | 52.36 | 56.57 | 6.91 |

The 365-day cohort retires about 36.25 MB of logical row data and restores to
roughly 87% less allocation. Five/12/20 packs were purchased and two/six/ten opened
across the respective scenarios, growing stored inventory. Restored checksums
match critical plant/layout/wallet/state/lot/opening/collection data. Read latency
and query/response-size samples are recorded before and after; these small samples
are not a throughput guarantee or proof of uniform latency improvement.

Normal cleanup makes pages reusable and can temporarily increase allocated size
through updates and new summaries. Restored allocation measures the retained
working set separately from those existing/dead pages. `VACUUM FULL` is not part
of the gameplay job. Preserve space for autovacuum, indexes and WAL during rollout.

The current scheduled curve can reach 960 arrivals/hour. At 50% capture, 60 active
minutes imply up to roughly 480 welcome receipts versus 60 in the conservative
legacy-rate cohort. Durable reward/ledger/request rows still grow at that higher
volume. Shared platform/auth overhead, 500 dormant accounts, inventory growth and
index sharing must be budgeted separately. The measured savings do **not** prove
that 1,000 MAU fit in 500 MB. Retained financial identities and summaries still grow
with account age; no fixed enrollment limit is asserted here.

## Upgrade and gradual enablement

No service or flag was enabled on the live installation. From `backend/`, first
take a backup with the existing PostgreSQL tooling, then rebuild/migrate:

```powershell
docker compose build api migrate maintenance
docker compose run --rm migrate
docker compose up -d --wait --wait-timeout 90 api
docker compose run --rm api forest storage-report --exact
```

Run dry runs on the upgraded test server first:

```powershell
docker compose run --rm api forest maintain-history --responses --limit 500
docker compose run --rm api forest maintain-history --visitors --limit 500
docker compose run --rm api forest maintain-history --growth --limit 500
```

Once original/compacted recovery is accepted on a test account, apply each family
separately using the same commands with `--apply`. Repeat until eligible work
settles; inspect failures/legacy protection rather than bypassing reconciliation.

The optional `maintenance` Docker profile contains one shared periodic worker.
It is absent from ordinary startup and all family flags default to false. To use
it after acceptance, set the desired `FOREST_MAINTENANCE_*_ENABLED=true` values,
then start it explicitly:

```powershell
docker compose --profile maintenance up -d maintenance
docker compose logs --tail 30 maintenance
```

Independent flags are `RESPONSES`, `VISITORS`, and `GROWTH`. Interval defaults to
60 seconds between batches and batch limit to 500. Configure these with
`FOREST_MAINTENANCE_INTERVAL_SECONDS` / `FOREST_MAINTENANCE_BATCH_LIMIT`.
Run `docker compose stop maintenance` to stop the worker. Cloud deployment uses
the same trusted command and flags with the managed connection/secret settings;
the Compose profile is the local deployment path, not cloud provisioning.

Cleanup throughput must exceed the eligible records produced. At 125 daily users
playing 60 Garden minutes, heartbeats alone create about 45,000 cache rows/day;
high attraction and half capture can add around 60,000 welcome outcomes/day before
other history. An hourly 500-row pass would fall behind that workload. The
one-minute default provides margin, but monitor actual batch duration/lag and
database impact before setting population limits. Keep the worker disabled until
the test rollout is accepted.

## Validation and device checklist

Executed results are recorded in backend/frontend VALIDATION.md. The matrix is
opt-in: set `FOREST_HISTORY_BENCHMARK=1`, then run
`test_history_benchmark.py` through the isolated PostgreSQL validation helper.
Normal regression runs skip only those separately executed matrix cases.

Before enabling cleanup broadly:

- [ ] Upgrade a test backend to `0011_compact_history`; verify readiness and normal
  play with the already updated iPhone app. No new frontend build is required.
- [ ] Confirm wallet, hosted counters, stored whole/fractional visits, planted and
  stored copies, growth/stages, discoveries and unopened packs are unchanged.
- [ ] Run each dry-run family. Confirm no authoritative balances/progress change.
  Apply small batches on test data and repeat; a second run must not repeat totals.
- [ ] Recover an old paid welcome whose opportunity has been retired. Same UUID
  and another alias must resolve the original amount without a second payment.
- [ ] Repeat interrupted welcome/claim/exchange/opening after response compaction;
  current wallet/inventory wins and confirmed rewards do not celebrate again.
- [ ] Sync movement, acknowledge a recap, and verify growth remains after old
  traces compact. An unacknowledged recap must remain available unchanged; an
  acknowledged one must stay dismissed. Discovery and stored-copy identity survive.
- [ ] Reconnect/background/Edit while maintenance runs; arrivals retain their
  current timing, lease policy and future identities. A simple move must not
  cancel future visitors when attraction/skills are unchanged.
- [ ] Test old queued activity, device replacement and account switching with
  cleanup enabled on test data. No duplicate growth, cap reset or data mixing.
- [ ] Interrupt/restart the worker; rerun maintenance. Check for reconciliation
  failures, unexpected retention lag, growing dead tuples or unacceptable latency.
- [ ] Verify a backup restore to a separate database before enabling live removal.
  Automated matrix restoration was tested only with synthetic isolated databases.

Expiry/time-travel, concurrency, exact fractions, rollback, legacy compatibility
and repeat safety are automated checks; do not change the live server clock or
manually age personal receipts to reproduce them. Live removal and device
acceptance remain separate from passing backend/portable tests.
There is no need to wait seven or 30 days to finish phone acceptance tonight:
the synthetic tests exercise those boundaries. A personal installation with no
eligible old data may correctly report zero work in its first maintenance runs.
