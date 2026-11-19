# Recurring expeditions

Source implementation: 19–20 November 2026. Migrations: `0021_expeditions`
and `0022_expedition_launch`.
Migration creates infrastructure only; it does not schedule an expedition or grant rewards.

## Calendar and content

The server-wide earning interval is a UTC calendar month: `[00:00 UTC on day 1,
00:00 UTC on day 1 of the next month)`. The account's game timezone remains in
use for normal activity/growth and daily item skills; it does not move the event
reset. Expedition step-day objectives use UTC dates as well, avoiding ambiguous
partial local dates at a server reset.

One published month assignment repeats indefinitely. Resolution takes place in
the owner transaction, so renewal requires no cron job, phone uptime or monthly
manual publication. Each owner/month has a deterministic run ID and independent
progress, completion, collected pieces and reward identities. Earlier entitlements,
receipts and item copies remain permanent. Existing arrangements can immediately
complete a fresh run's simultaneous-placement quests.

There are nine piece rewards, an independent Basin entitlement at four completed
quests, and an Orrery entitlement at nine. Claims do not gate either milestone.
Claiming a piece reward reveals its colour; completion alone does not. Another
month can grant another copy, but skill duplicates do not stack/retrigger.

The exact first content/rewards are in `expedition_definitions.py`. Templates,
month assignments, entitlements, claims and tier grants are immutable in PostgreSQL.
Shared publication/resolution locks prevent an in-flight assignment from being
missed at renewal. Future replacements use the same supported nine-evaluator
vocabulary; new evaluator types still need a client/server release.

## Publication

Run the normal deployment backup/migration process, publish the version-20 Woodland
pack dependencies, and preview a future month before applying. For example only:

```powershell
forest publish-expedition 2026-12-01
forest publish-expedition 2026-12-01 --apply
```

For the first launch only, an explicit `--start-now` can select the current UTC
month. This creates an immutable server-clock earning cutoff, rounded up to
millisecond wire precision. Earlier actions and Health evidence cannot count;
the launch date accepts only its eligible partial interval. For the requested
November launch, preview and apply with:

```powershell
forest publish-expedition 2026-11-01 --start-now
forest publish-expedition 2026-11-01 --start-now --apply
```

The first run ends December 1 at 00:00 UTC. December and subsequent runs use full
UTC calendar months with fresh progress and the same template. No monthly command
is needed. Repeating the launch command preserves its original cutoff. An existing
full-month assignment cannot be converted, and later months cannot use this flag.

Preview rolls back all writes. Apply publishes the three reward-only item definitions,
pinned skills and a recurring assignment, not shop offers. All three are explicitly
sale-unavailable gifts: no token/resale value is invented. Existing shop pools and
their prices are unchanged. Review gift resale/capacity and newcomer herb access
before production activation; repeated monthly copies consume normal item capacity.

A replacement JSON file has `version` and `definition` fields. `definition` uses
the same schema as the published template: nine unique supported quest IDs,
one-to-one piece indices, positive targets, descriptions, pinned rewards,
independent four/nine milestones, UTC timezone and a versioned bundled artwork key.
The publisher freezes gameplay tags from the current catalogue. Example command:

```powershell
forest publish-expedition 2027-01-01 --template-file next-expedition.json
```

Add `--apply` after reviewing. Assignments must be finalized before the selected
month starts. A changed definition under the same template version or changed
assignment for an existing month is rejected. A new bundled painting/client
release is required for new art; remote asset delivery is not part of this release.

## Long absence / 30-day sync

Normal garden sync still reads/reconciles seven account-local dates. Its economic
watermarks, activity caps, XP, gems and workout credits retain their existing rules.
Expedition evidence has a separate endpoint and durable native journal.

1. After ordinary sync, the phone fetches expedition status. The server returns
   missing/incomplete UTC date intervals for steps and workouts independently,
   bounded by earning start/end, account creation and the enrolled device epoch.
2. The phone queries only requested dates, in batches of at most seven. Recently
   observed dates are reread for ongoing days/delayed Health updates; completed
   older coverage is skipped. A recovery action can explicitly reread older
   covered dates while Health quests remain incomplete.
3. Each query uses the exact server-supplied eligible interval. Lower boundaries
   round **up** to millisecond wire precision. Step queries use strict sample
   start/end filtering: boundary-crossing samples are conservatively excluded,
   rather than assigning an entire pre-baseline/cross-month sample to a run.
   Unknown/no-readable-sum step results remain null rather than fabricated zero.
4. Recorded runs/walks retain stable workout UUID/source provenance, pause/segment
   accounting, baseline/event bounds and shared interval subtraction. A run needs
   a completely eligible recorded 2 km session; a walk needs 900 eligible active
   seconds. Water-cap exhaustion does not block qualification. Existing growth
   imports do not consume expedition eligibility.
5. Uploads contain at most seven dates, 500 workouts and 2,000 segments. Large
   queries split into durable chunks; only the last confirmed chunk acknowledges
   complete workout coverage. Exact encoded bodies/UUIDs are saved before sending.
   Interrupted requests resume unchanged; only confirmed receipts advance the
   server coverage/local queue. Known expired/prior-device rejections are terminal
   only after replay checks confirm the operation did not commit.
6. The server merges cumulative per-date/per-device-epoch high-water totals and
   stable workout identities. Lower/out-of-order observations, overlapping
   sessions, retries and alternate request IDs cannot multiply progress. Accepted
   earlier epoch facts remain; a replacement cannot freshly claim unvalidated
   pre-replacement history.
7. Evidence may arrive until seven days after earning ends, strictly before its
   deadline. A **31-day month plus grace can require almost 38-day-old evidence**;
   there is no last-30-days cutoff. Grace allows earlier earning-month activity,
   not extra earning days. Previous/current runs coexist during grace.
8. Historical evidence changes evidence, coverage, progress and earned entitlements
   only. It gives **no historical plant water, XP, gems, visitor income, permanent
   activity milestones, or Orrery tiers**, and cannot consume growth credit still
   eligible for ordinary sync. Rewards require a separate explicit claim.

Once all three Health quests are complete, expedition-only historical reads stop.
Foreground recovery is the fallback; background Health delivery is opportunistic.
HealthKit read-denial cannot reliably be distinguished from missing data; an empty
successful workout query records attempted coverage, not proof of authorization.
Older-data retry remains available for delayed/previously unavailable records.

## Items and accounting

- `astronomers-satchel`: Common Astronomer's Forgotten Satchel, radius 0.52,
  no skill, attraction or growth stages.
- `comet-basin`: Rare Comet-Catcher's Basin, radius 0.69. Guiding Glow supplies
  fixed +3% in the steps activity layer, placed-only/strongest-once. Other metrics,
  zero step coefficients, XP and flat grants are unchanged.
- `worldseed-orrery`: Legendary, radius 0.92. Alignment of Worlds uses a separate
  typed `triggeredGrants` profile, never the Morning Rain `dailyGrant` shape.
  Newly eligible normal-sync steps while placed cross 2,000/4,000/6,000 daily tiers
  for incremental flat 3/4/5 water per placed plant. Account/date/family/tier
  identities prevent duplicate-copy, replant and replay grants. Storing pauses
  the shared daily counter. Late normal-window credits use their credited game
  date and current authoritative membership, following existing credit-time
  membership rules; daily aggregates do not prove individual historical placement.

Flat grants respect maturity, update real discovery/maturity/visitor state and
observe expedition stage changes at their actual server growth boundary. Percentage
skills cannot amplify them. A batch crosses tiers as 3+4+5, not 3+7+12. Plants added
later get no retroactive grant. Recent tier water is displayed separately from Rain.

Claims serialize owner → garden → catalogue; grant all components atomically;
retain earned rewards at full item/pack capacity; grant items stored and packs
unopened. Bonus gems have their own durable grant source recognized by wallet/history
reconciliation. Sale/restart/archive/reinstall cannot recreate an item acquisition.
Request compaction preserves small permanent claim/evidence receipts. All new tables
have explicit storage classifications and required replay facts are not expired.

## API and native behavior

Use `X-Forest-Expeditions: 1`. Routes:

- `GET /v1/me/expeditions/current` (`retryOlder=true` reopens older query coverage).
- `GET /v1/me/expeditions?before=<run UUID>&limit=12` for the owner archive.
- `GET /v1/me/expeditions/{runId}` for a pinned run.
- `POST /v1/me/expeditions/{runId}/evidence` for bounded evidence.
- `POST /v1/me/expeditions/{runId}/rewards/{entitlementId}/claim` with a request UUID.

Older clients keep old event contracts and receive an explicit update-required
response when trying to inspect/place newly owned expedition item content. The new
client uses account/server-scoped caches and queues. A fifth bottom destination
keeps the Garden mounted. All progress ratios are inside bars; popup rewards use
quantity then artwork. Painting, masks/hit testing, rewards and UI remain separate.
Missing artwork exposes textual quest/claim access. Cached/uncertain claims never
reveal a piece; confirmed receipts remain authoritative after a failed refresh.

## Validation

Use an isolated `FOREST_TEST_DATABASE_URL`; tests create/drop only random
`forest_test_*` databases. Run from `backend`:

```powershell
python -m pytest tests -q
```

To regenerate the HTTP-derived native expedition fixture, set
`FOREST_EXPORT_EXPEDITIONS=1` and run `tests/test_expeditions.py` (or just its
`test_http_native_expedition_contract`). The fixture explicitly labels synthetic
earned progress; real claim/wallet/item/pack paths produce its receipts.

Run resource/project/Swift syntax and Ruff checks. The portable Swift toolchain
executes 92 shared resolver cases and the real expedition models/coordinator with
platform interfaces. These checks do not execute SwiftUI, HealthKit or RealityKit.
See [native acceptance](../frontend/EXPEDITIONS_ACCEPTANCE.md) for Mac/iPhone gates.
