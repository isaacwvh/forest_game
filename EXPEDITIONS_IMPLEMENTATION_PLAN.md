# Expeditions implementation plan

Prepared: 19 November 2026 (Asia/Singapore).
Source baseline: working tree at `90f7d54`, including existing uncommitted planning and asset work.
Status: source implementation added in this chat; see [backend/EXPEDITIONS.md](backend/EXPEDITIONS.md) and [native acceptance](frontend/EXPEDITIONS_ACCEPTANCE.md). No personal database migration, live publication or push. Mac/iPhone acceptance remains a separate release gate.

**User clarification:** the expedition is server-wide. All monthly runs start/end at **00:00 UTC**, and expedition step days use UTC. Account-local time remains applicable to ordinary growth and daily item skills only. This supersedes the earlier account-timezone reset default.

## 1. Outcome and precedence

Build the Forgotten Forest Observatory expedition described in [expeditions_plan.md](expeditions_plan.md), with nine independently progressing quests, nine tappable puzzle pieces, separate completion and collection, the four-quest Basin reward and the nine-quest Orrery reward.

The user's latest requirements take precedence over older mockups and planning passages:

1. Renew automatically at the start of **every calendar month**, repeating this exact expedition until a replacement is scheduled. Each month has independent quest progress, puzzle restoration and reward claims.
2. Put **current / target inside every expedition progress bar**, including overall progress, quest popups and any milestone bar. Do not repeat the ratio above/below the bar.
3. Include complete support for the two new items, and the infrastructure for their skills. The Satchel has no skill; the Basin supplies Guiding Glow. Include the already-selected Orrery and its Alignment of Worlds skill as required by the expedition specification.
4. Follow the **current milestones page** for popup typography, parchment/sage materials, progress treatment and reward states. Visible rewards use **quantity followed by artwork**: `250 <token icon>`, `1 <gem icon>`, `1 <pack image>` or `1 <item thumbnail>`. Supply full names to accessibility and inspection.

The concept board remains authoritative for the continuous nine-piece illustration and centred popup interaction. Its outside-bar ratios, telescope prize, old single-day quest, icon-first reward text and illustrative countdown are superseded.

This is a plan for a native SwiftUI feature backed by the existing FastAPI/PostgreSQL game. A web implementation, new content CMS, remote artwork delivery and new artwork each month are unnecessary for the initial repeating release.

### Working defaults carried into implementation

| Decision | Concrete default |
| --- | --- |
| Reset timezone | **Server UTC**, day 1 at 00:00, simultaneously for all accounts. Neither saved account timezone nor phone timezone changes the event boundary. |
| Recurrence | Indefinite monthly recurrence of the published Observatory template until an explicit future-month assignment replaces it. |
| Rewards on a repeat | Earn the same full reward schedule again each month, including another copy of each item. Once per account/run/reward, not once per item type for the lifetime of the account. |
| Previous months | Preserve completion, claims, earned unclaimed rewards, owned items and receipts in an archive. Reset means fresh current-run state, not deletion of history or inventory. |
| Health grace | Seven days after each run's earning end; accepts only eligible activity from that run. |
| Claim expiry | No expiry for already-earned expedition rewards. Existing fixed milestone events retain their existing deadlines. |
| Content replacement | Takes effect on a selected future calendar month, for all accounts using that month, with no changes to an already-started run. |
| Item identities | Use the existing asset IDs `astronomers-satchel`, `comet-basin`, `worldseed-orrery`; retain the selected full reward display names. See section 8. |
| Sale values | Do not invent prices. Make resale policy explicit in publication. Existing source permits gifts without valuation, but the earlier expedition spec expects a published gift valuation policy; resolve this before production publication. Development fixtures may explicitly use sale-unavailable gifts. |

These defaults resolve implementation choices; the unselected launch month and resale policy remain release inputs. They do not block isolated development.

## 2. Inspection findings and what can be reused

| Area and inspected source | Existing behavior | Implementation consequence |
| --- | --- | --- |
| `backend/src/forest_api/milestone_models.py`, `milestone_tracks.py`, `milestone_definitions.py`, `backend/MILESTONES.md` | Permanent entitlements, concurrent progress and repeat-safe currency/pack claims; `event_definitions()` hardcodes four event quests. Events have global UTC intervals and expiring claims. | Reuse accounting and claim patterns, but introduce a separate expedition domain. Do not turn the four old event quests into nine or mutate old published events. |
| `activity.py`, `activity_schemas.py`, `activity_inputs.py`, `activity_models.py` | Seven-date normal sync, baseline-adjusted cumulative steps, stable workout UUIDs, pauses/segments and overlap accounting. Already-imported workouts short-circuit growth processing. | Add event evidence independent of economic credits. A simple 7-to-31 query change cannot implement this feature. |
| `HealthKitService.swift`, `HealthDataProvider.swift`, `ActivitySyncCoordinator.swift` | Recent reads and durable upload queue; native status validation also enforces a maximum seven-day reconciliation policy. | Add a separate range reader and historical evidence coordinator/queue. Keep ordinary growth reconciliation unchanged. |
| `visitors.py` | `kind` distinguishes active welcomes from offline claims, but the current milestone observer receives only a combined count. | Call a new expedition observer with the active welcome identity and confirmed garden. Keep old milestone behavior unchanged. |
| `placement.py`, `services.py`, `collection.py`, `daily_items.py` | Atomic mixed layouts, authoritative snapshots, durable pack openings, activity growth and lazy Morning Rain settlement. | Observe successful actions in their transactions. Observe whole logical growth batches, not transient intermediate layouts. |
| `items.py`, `item_models.py` | `grant()` already creates stable permanent acquisition identities, handles duplicate grants and capacity, and leaves copies stored. Optional valuations control sale availability. | Use this service for expedition item rewards; no new item ownership system is needed. |
| `item_catalogue.py` | Fifteen shop items, seven percentage profiles plus Morning Rain, immutable publication/bindings and weekly shop release rules. | Publish expedition items independently of shop rotations. Do not append reward-only items to the shop pools. |
| `item_skills.py`, `skills.py`, `GardenStrategy.swift` | Placed item emitters, frozen snapshots, strongest-per-group effects and native prediction. Flat-grant summaries/decoding currently assume Morning Rain. | Guiding Glow fits existing percentage effects. Orrery requires an explicit new trigger schema, state, grant accounting and native prediction/presentation. |
| `progression.py`, `history.py` | Bonus gems reconcile against `MilestoneBonusGrant`; token income reconciles through existing wallet entries. | Expedition gem rewards need a durable recognized bonus-grant source and reconciliation updates. Updating balances alone would break maintenance checks. |
| `recovery.py`, `storage_usage.py`, migration environment | Known-operation recovery allowlists, compact receipt rules, explicit table classification and registered model metadata. | Register expedition operations/models/tables throughout maintenance and recovery. |
| `MilestoneTracksScreen.swift`, `frontend/DESIGN.md`, `MILESTONES_ACCEPTANCE.md` | Current bars overlay current/target inside the fill. Compact reward boxes distinguish locked, ready, pending and claimed. Visible rewards currently put artwork before quantity. | Reuse visual primitives without forcing milestone row dimensions onto a popup. Quantity-first order is the latest expedition requirement; preserve existing milestone order unless separately requested. |
| `MovementForestApp.swift`, `CollectionScreen.swift` | Four bottom controls, with Edit acting as an editor entry; Milestones is a collection-menu destination. Garden renderer stays mounted across destinations. | Add Expedition as a fifth bottom control; preserve existing four and the mounted garden. Include a menu shortcut if helpful. |
| `BundledItemAssets.swift`, `item-asset-index.json`, `generate_project.py`, `tools/validate_items.py` | Item assets resolve by exact item ID/version; project resources derive from the index. Validator assumes every indexed item is one of the 15 shop items. | Extend the index with three reward items, regenerate the project and separate shop-pool validation from all-bundled-item validation. |

### Asset facts established during this inspection

All three packages are present. A read-only check verified every manifest asset's SHA-256, size, USDZ archive CRC and 384 × 448 RGBA PNG header:

| Package | Model + thumbnail bytes | Radius | Authored motion |
| --- | ---: | ---: | --- |
| `assets/items/astronomers-satchel/v1` | 1,512,323 | 0.52 m proposed | Static |
| `assets/items/comet-basin/v1` | 1,700,749 | 0.69 m proposed | Six-second expanding water ripples; comet stationary |
| `assets/items/worldseed-orrery/v1` | 3,980,937 | 0.92 m approved in plan | 24/36/48-second ring periods; combined 144-second loop |
| **Total** | **7,194,009** | | |

This is asset integrity evidence, not native playback, installed-memory or frame-rate acceptance. The Satchel/Basin production source is [art/observatory-items-production/SOURCE.md](art/observatory-items-production/SOURCE.md). The latest authored stationary comet supersedes the earlier optional comet-bobbing suggestion. Preserve the ripple animation and reduced Basin dimensions.

No clean production observatory painting or nine-piece runtime mask package was identified. The selected image is a UI concept board under `output/concepts/expeditions-observatory-v1`; do not crop it into a production background. Old passages saying the two item packages still need production are stale.

## 3. Monthly renewal and future rotation

### 3.1 Template, series and monthly run

Separate these concepts:

- **Template**: immutable `forgotten-forest-observatory-v1` content, including the nine quest IDs, art, masks, rewards, item/profile versions and tag rules.
- **Series**: `monthly-expedition`, with a published starting calendar month and fallback template. The recurrence rule is calendar-monthly, interval 1, day 1, server UTC boundaries.
- **Month assignment**: optional immutable assignment of a new template to a future `YYYY-MM`. Resolve the latest effective assignment; otherwise repeat the existing fallback indefinitely. A replacement persists into subsequent months until another assignment.
- **Account run**: owner + series + calendar month. Resolve and pin the assigned template once; freeze UTC boundaries, evidence deadline and eligibility baselines. Every contribution, quest and claim references this run.

Use compact structured keys instead of concatenating long event/template/quest names into existing 32/64-character milestone identifiers. A deterministic run UUID plus stable short quest/reward keys is sufficient. Enforce one account run per series/month in the database.

Recurrence must not depend on an operator publishing the same content each month. Publication enables the recurring series once. On-demand resolution and all action observers derive the correct month from authoritative server time. A small look-ahead maintenance command may warm shared month assignments, but correctness does not depend on a job firing at midnight.

Freeze a month's effective assignment before 00:00 UTC on its first day. Publication and resolution share a transaction lock. An account/device timezone edit cannot create a second run or move its boundaries.

### 3.2 Boundary behavior

For every account, a December run earns during `[1 December 2026 00:00 UTC, 1 January 2027 00:00 UTC)` (08:00 in Singapore at both boundaries). These dates illustrate the rule, not a selected launch month.

Set `evidenceUntil` to 00:00 UTC on day 8 after the earning month. Server receipt must be strictly earlier. Use calendar months, including February/leap years, rather than a rolling 30-day timer.

At the boundary:

1. New earning actions route to the new run. The previous run enters Health-evidence grace.
2. New quest progress, completion times, contribution sets, claimed states, milestone entitlements and coloured-piece state begin empty.
3. Immediately evaluate provable current garden conditions for the new run. Four items or all four stages already placed can complete their snapshot quests immediately. A reset does not force players to remove and re-place existing items/plants.
4. Retain every earlier reward/item, prior run, receipt and earned entitlement. The same item type can be earned again using a different run-scoped acquisition reference.
5. Do not reset the wallet, garden, lifetime milestones, activity/device baselines or Orrery's independent daily accounting.

The visible page can therefore start a month above `0 / 9` if arrangement quests already qualify. Explain this in implementation and acceptance; an unconditional forced zero would conflict with the selected snapshot rules.

When the app remains open over midnight, use a server-time-anchored timer to invalidate the current run and fetch the new one. Until confirmed, label the old month as ended/cached, block new uncertain claims and do not locally fabricate a new run. Pending old-run claims retain their old run ID and exact request bytes and remain recoverable after renewal.

### 3.3 Lazy initialization, missed months and historical settlement

Opening the Expedition tab is never the eligibility start. Install action observers for all eligible accounts as soon as the published series starts, independently of client capability or visiting the page.

Run resolution must accept an **effective action boundary**, including a due Morning Rain grant's historical boundary. If lazy settlement crosses a month, route each complete historical growth batch to its own month before evaluating snapshots. A pre-boundary layout that is provably unchanged may establish snapshot eligibility at the boundary; a layout first seen after the boundary may establish eligibility only at the confirmed read/action time. Never reconstruct unproven historical arrangements or taps from today's garden.

Do not generate empty account rows for every absent month merely to render the archive. Materialize runs that have current/grace evidence, durable contributions, claims or provable settlement outcomes. Empty skipped months can remain implicit and unearned. Archive pagination must not scan all past months or all owners during ordinary sync.

## 4. Persistent model and service boundaries

Use new expedition tables rather than reusing incompatible fixed-event date/claim fields. Names below are recommended implementation names, not existing tables.

| Record | Key and essential fields | Retention/indexing |
| --- | --- | --- |
| `expedition_templates` | Template version; validated immutable content JSON/hash; asset versions; evaluator/client capabilities; publication time. | Shared immutable configuration. |
| `expedition_series` / assignments | Series key; starting month; effective-month template assignments; recurrence and timezone policy. | Shared configuration; unique series/effective month; no in-place assignment changes after freeze. |
| `account_expeditions` | Run UUID; owner/series/month unique; template version; frozen timezone, starts/ends/evidence-until; eligibility baseline refs; monotonic progress version. | Owner/month and owner/deadline indexes; permanent archive identity. |
| `expedition_quest_progress` | Owner/run/quest unique; current and target; completed-at nullable; completion provenance; collection state via entitlement/claim. | Nine rows/run; completion latches. Incomplete snapshot progress may decrease. |
| `expedition_day_evidence` | Owner/run/date/epoch provenance; validated observed and eligible step high-water facts; effective observation coverage. | At most earning dates per run plus necessary device-epoch facts; evidence domain only. |
| `expedition_workout_evidence` | Owner/workout canonical provenance; eligible intervals/type/distance; exclusion reason; qualification per run. | Stable identity and bounded time-range indexes; reused across recent and historical paths. |
| `expedition_coverage` | Owner/run/type/range; observed-through; successful query state; retry metadata. | Separate steps and workouts; acknowledge coverage only after all chunks commit. |
| `expedition_contributions` | Owner/run/kind/source identity unique; source/effective boundary; minimal needed qualification facts. | Active welcome IDs, opening IDs, advanced copy IDs; never rely on expiring request responses. |
| `expedition_entitlements` | Owner/run/reward key unique; earned-at; immutable reward bundle and pinned definitions; originating quest or 4/9 threshold. | Eleven possible reward entitlements/run: nine quests + Basin + Orrery. Permanent. |
| `expedition_claims` | Entitlement unique; request/alias recovery identity; compact permanent receipt and granted event/item/pack IDs. | One economic grant per entitlement, across concurrent UUID aliases. |
| `expedition_bonus_grants` | Owner/entitlement unique; positive bonus gems; awarded-at. | Reconciles the one-gem reward without impersonating step earnings. |
| Orrery state/grants | Owner/game date/family progress; owner/date/family/tier unique grant; per-recipient awarded water and immutable provenance. | Separate from monthly progress; permanent deduplication and growth reconciliation facts. |

Reuse existing wallet entries, pack ownership, item identities and API request recovery instead of duplicating them in these records. Add appropriate ownership FKs/checks, nonnegative/overflow guards, and migration/model parity tests. Do not copy raw HealthKit step samples or GPS tracks into this model.

### Service layout

- `expedition_definitions.py`: typed content/evaluator/reward schemas, exact Observatory fixture and validation.
- `expedition_models.py`: ORM records and indexes.
- `expeditions.py`: resolve/enroll, snapshots, progress transitions, summary/archive and entitlement creation.
- `expedition_evidence.py`: evidence validation/merge, coverage and bounded recovery.
- `expedition_rewards.py`: entitlement claims, existing grant-service integration and replay.
- `expedition_routes.py` / `expedition_schemas.py`: public contracts and capability gates.
- `item_step_grants.py` or equivalent: reusable placed-only daily step-triggered grant engine for Orrery.

Keep these modules small enough to avoid a second monolithic `milestone_tracks.py`. Extract narrowly shared pure evidence/reward helpers only where behavior really matches; preserve legacy call signatures and receipts.

All mutations retain **owner → garden → shared catalogue**, with deterministic copy lock order. Read the authoritative post-lock server clock. Persist the original action, its contribution, completion and newly crossed 4/9 entitlements in the **same transaction**. Preview endpoints stay read-only and must not enroll accounts, settle grants or award progress. Every action/snapshot observer enforces `startsAt <= effectiveBoundary < endsAt`; grace permits eligible historical Health evidence only, not new taps, openings or current garden snapshots for the ended run.

## 5. Nine evaluators and exact hooks

The exact descriptions and inclusive thresholds in expedition specification section 4 remain authoritative. Preserve these nine stable IDs and reward mapping:

| Piece / quest ID | Progress and authoritative source | Reward |
| --- | --- | --- |
| 1 `steps_days_3` | Distinct eligible game dates with at least 5,000 accepted event steps; target 3. | 1 Common Astronomer's Forgotten Satchel |
| 2 `run_walk_sessions_3` | Three distinct qualifying recorded workouts: run ≥2,000 m or walk ≥900 eligible active seconds, any combination. | 400 tokens |
| 3 `items_together_4` | Simultaneously placed owned item copies; target 4. Duplicate types allowed; plants excluded. | 200 tokens |
| 4 `active_butterflies_100` | Successful active welcomes only; target 100. | 250 tokens |
| 5 `packs_opened_3` | Distinct successful openings of any pack type during earning; target 3. | 1 gem |
| 6 `all_stages_together` | One confirmed complete garden containing distinct copies representing sprout, seedling, young and adult; target 4 stage categories. | 300 tokens |
| 7 `copies_advanced_4` | Four distinct plant copies with a real forward stage transition during earning. | 1 Standard Woodland pack (`woodland`, pinned published version) |
| 8 `tree_herb_butterflies_50` | Active welcomes with separate placed tree and herb copies at the tap transaction; any stage; target 50. | 300 tokens |
| 9 `monthly_steps_30000` | Accepted eligible event steps summed over dates, before water caps; target 30,000. | 400 tokens |

At any four completed quests create the Basin entitlement; at nine create the Orrery entitlement. Count completion, not claims. The intermediary budget remains **1,850 tokens + 1 gem + 1 Standard pack + 1 Satchel + 1 Basin**, plus the final Orrery. No added reward for renewing or switching months.

### Hook placement and ordering

| Hook | Required change |
| --- | --- |
| `activity.sync()` | Pass validated baseline-adjusted day evidence to the shared event evidence merger; include no-water-cap progress. Observe actual before/after stages and one complete post-growth garden. |
| `activity_inputs.workout_credits()` | Factor canonical validation/eligible intervals out from economic award bookkeeping. An already-imported workout may still be new expedition evidence. Never treat `already_processed` as automatic quest exclusion. |
| `visitors.mutate()` | After settlement/eligibility and only for a new successful `visitor_welcome`, pass opportunity identity, kind, boundary and confirmed tree/herb membership to the observer. Keep existing permanent combined butterfly milestones intact. |
| `collection.mutate()` opening branch | Observe `opening_id` after the opening/plant records are ready, before commit. No contribution on exchange, animation start, cancellation or failed capacity checks. |
| `placement.edit_garden()` | Evaluate the initial provable snapshot where needed for lazy enrollment, then the final flushed atomic layout once. No progress from `propose_layout()` or strategy previews; no intermediate per-action snapshots. |
| `services.read_garden()` and expedition enrollment | After due settlement, evaluate the current confirmed snapshot so existing arrangements qualify without editing. Preserve expected versions/locking. |
| `daily_items.settle_due()` | Capture before/after stages for each effective midnight grant; observe the complete day's batch and final snapshot. Do not call a full refresh recursively through visitor settlement. |
| Orrery tier settlement | Observe actual stage increases and complete post-tier batch snapshots using the same growth observer. |

Steps for quests 1 and 9 overlap; the same conditional butterfly contributes to quests 4 and 8. Contributions are never consumed by another quest. A copy crossing several stages contributes once to quest 7. Creating a sprout, replanting, changing profiles, selling or storing a copy never creates a stage advancement.

For quests 3 and 6, show the current capped snapshot count while incomplete; allow it to decrease. Once the requirement is satisfied, preserve completion and display the target forever. For quest 8, freeze the template's tree/herb interpretation; do not infer from names or current mutable catalogue tags.

### Workout canonicalization

Only recorded running (37) and walking (52) qualify. Exclude manually entered, unsupported or mixed-type sessions. Preserve pause accounting, device/enrollment baselines, stable workout/source identity and overlap subtraction. Both start and end must lie within the earning interval; use the specification's explicit rule that end must be strictly before `endsAt`. Cross-midnight sessions wholly within the event remain eligible.

Count a walk from eligible active time after pauses/overlap. A run needs positive eligible duration, ≥2,000 m recorded distance and a completely eligible session; do not prorate its whole distance after clipping. Water allowance exhaustion does not remove otherwise valid evidence.

Persist the selected interval ownership/qualification facts so recent and recovery uploads use the same result. When records arrive in different batches, accepted interval ownership remains stable; the chronological/source/UUID order resolves candidates within a batch. Later overlapping aliases may contribute only uncovered time, never an additional qualifying run on reused whole distance. This prioritizes replay stability and avoids revoking earned completion. Add explicit cross-batch/source-copy tests and diagnostics rather than claiming UUID deduplication alone solves overlap.

## 6. Health evidence and bounded recovery

### 6.1 Preserve normal sync

Keep the seven-day growth reconciliation window, economic watermarks, XP/gem awards, daily caps and existing queued-observation rules. Observe accepted recent evidence for expeditions in the normal transaction, but share evidence identity/high-water merging with recovery.

Introduce an **evidence-only** route for old dates. It may update expedition evidence, coverage, quest completion and earned entitlements. It must not update `ActivityDay.credited_steps`, workout economic coverage, `PlayerProgress`, wallets, plant growth, visitors, daily skill triggers or normal device baselines. Entitlement creation is allowed; claiming it remains explicit.

Economic imports and evidence imports therefore share validated facts without sharing consumption flags. In particular, do not insert a catch-up-only workout into `WorkoutImport` in a way that causes later eligible normal sync to skip water. An old growth-window rejection is also not proof the workout is ineligible for a monthly quest.

### 6.2 Step evidence and device epochs

Define one merger for baseline-adjusted event quantities, not `old total + uploaded total`:

1. Validate owner, run/template, game date, observation/query coverage, active device authorization and server receipt deadline.
2. Reuse existing accepted pre-cap step facts where present. Record their provenance as already accepted; do not subtract enrollment baselines a second time.
3. For a missing date, apply the original applicable enrollment/device epoch baseline once. Preserve durable prior-epoch accepted quantities and union them with newly eligible facts; never take the max of unrelated raw device totals or sum duplicate daily aggregates.
4. Merge eligible cumulative observations monotonically. A lower/out-of-order read cannot remove accepted steps, add duplicate steps or reopen a completed quest.
5. If original baseline provenance is insufficient to validate a missing historical quantity, mark it unavailable/retryable as appropriate; do not assume zero baseline or fabricate history. Persist any additional epoch checkpoint needed when normal device replacement occurs.

A replacement device may retain server-accepted prior-epoch evidence but cannot freshly claim unvalidated pre-replacement history. Event eligibility starts no earlier than event start, account creation and applicable activity enrollment/metric baselines. Neither installation of the updated app nor the first puzzle visit resets eligibility.

### 6.3 Coverage and query planning

Status returns separate missing/unfinished ranges for steps and workouts, clipped to the eligible earning interval. Store successful observation-through coverage, not a Boolean "row exists" flag. A noon read does not cover the afternoon. A query that reads no available data, a failed read and a readable zero must remain distinguishable; HealthKit does not expose reliable read-denial authorization, so do not claim certainty about why a result is empty.

The phone:

1. Drains ordinary saved activity requests and performs recent sync first.
2. Fetches active and grace-run coverage/capabilities.
3. Queries only missing older earning ranges for steps and running/walking workouts. Reuse current recent-window data; do not re-read the entire month every refresh.
4. Queries complete recorded sessions crossing requested date boundaries, validates them against run bounds and deduplicates by UUID. Chunking must not drop a cross-midnight session or mark its coverage complete before the final page.
5. Uploads bounded batches, initially at most seven dates, 500 workouts and 2,000 segments, within the existing payload size limit. Define bounded pagination for unexpectedly large day results. A successful partial batch does not acknowledge an entire multi-batch query.
6. Persists each exact encoded body/UUID before transmission; retries the same bytes after interruption. Only confirmed server acknowledgements advance coverage.
7. Refreshes confirmed progress without reopening dismissed popups or colouring unclaimed pieces.

A 31-day month plus seven-day grace can require evidence almost **38 days old**. Do not use an unconditional last-30-days cutoff. Queue validity for this route is bounded by its original run/evidence deadline and observation checks; do not copy normal sync's 30-day request rule blindly or alter observation timestamps to pass it.

Once all three Health quests are complete and pending uploads are resolved, stop expedition-only historical reads. Continue ordinary growth sync. Provide a bounded older-data retry while the deadline remains open to catch delayed Health corrections, even for a previously successful query. Background delivery is opportunistic; foreground recovery is the reliable fallback.

### 6.4 Capability and errors

Negotiate `X-Forest-Expeditions: 1` and advertise evidence schema/version, supported evaluators and maximum batch bounds. Use server-derived run boundaries. Unsupported clients receive no unsupported expedition payloads and cannot issue new expedition claims, while existing game routes continue to function.

Distinguish wrong owner/not found, unsupported capability/update required, immutable version mismatch, evidence expired, invalid/before-baseline data and retryable failures. Replays of already accepted evidence/claims recover their original result even after the deadline; a new request after the deadline must not introduce new evidence. Invalid batches fail atomically without advancing coverage.

## 7. Claims, wallet integrity and archive

### Grant flow

Create one immutable entitlement for each completed quest and each crossed milestone. Use `quest:<id>`, `milestone:4` and `milestone:9` as reward keys within a run. Claims target an entitlement; do not let the client supply reward amounts, item definitions or target milestone counts.

Under the established locks:

1. Check replay/alias receipt first, authenticate ownership and load the pinned entitlement.
2. Verify claimability and validate all referenced item/pack definitions and capacities before granting any component.
3. Grant tokens through the existing visitor wallet entry ledger; grant the bonus gem through a recognized durable expedition bonus record and update lifetime/bonus totals. Keep `step_gems_earned` unchanged.
4. Grant unopened packs through the established `CollectionEvent`/`OwnedPack` relationship, with zero purchase spending for a reward.
5. Call `items.grant()` for items with a stable source such as `expedition_reward` and reference `<run UUID>/<reward key>`. Store resulting copy IDs in the permanent receipt.
6. Save claim/receipt and increment relevant garden/economy/progress versions atomically. A capacity or publication failure rolls everything back and leaves the entitlement earned.

Extract only the needed shared bundle-grant primitives from current milestone claim code; retain existing legacy/public response behavior. Add `expedition_bonus_grants` to `progression.reconcile()`. Existing account summaries can keep deriving `bonusGemsEarned` as lifetime minus step gems, but validate the new source and token ledger in history maintenance.

Selling a reward item later cannot recreate the entitlement or its copy. A new month's entitlement uses a new source reference and legitimately grants another copy. Duplicate copies do not stack Guiding Glow or reset/retrigger Orrery tiers.

### Native recovery

Use the existing durable collection mutation journal for expedition claims by adding a validated `.expeditionClaim` operation with explicit run and entitlement IDs. Persist response and queue removal together, as current collection operations do. Evidence uploads use their own bounded queue so historical sync does not occupy the sole collection reward slot or hold the editor gate for the entire month-long recovery.

Extend recovery allowlists, operation naming, retention and compact outcomes. Permanent claim records must recover complete small receipts independently of expired request response bodies. Validate receipt request/alias ID, run, entitlement, item/pack IDs and exact amounts before marking anything collected. A connection failure or failed refresh cannot erase a confirmed receipt.

Publish current run plus archive summaries with pagination. Previous-month Health grace remains visible, separate from current-month progress. Textual quest/reward access must survive missing archived art. Restoring assets or changing devices never awards a second item.

## 8. New items and skill infrastructure

### 8.1 Stable identity and publication

The planning IDs were explicitly proposed; asset manifests now provide concrete shorter IDs. Use this mapping consistently, without copying or renaming the authored packages:

| Selected display name | Canonical runtime item ID / asset folder | Earlier proposed ID | Skill |
| --- | --- | --- | --- |
| Astronomer's Forgotten Satchel | `astronomers-satchel` | `astronomers-forgotten-satchel` | None |
| Comet-Catcher's Basin | `comet-basin` | `comet-catchers-basin` | `guiding_glow` v1 |
| Worldseed Orrery | `worldseed-orrery` | Same | `alignment_of_worlds` v1 |

Use the full selected names in published gameplay definitions and reward inspection. Manifest short display names can remain asset metadata. No published runtime identity was found for the two proposed long IDs; if implementation discovers deployed records, add an explicit migration/alias policy before release rather than creating duplicate catalogue entries.

Create a reward-item publication package separate from `garden-items-v1.json` and `ShopRelease`. Pin immutable item definitions, exact asset keys, clearances, skills and explicit sale policy. Do not require a Monday shop release merely to register a monthly reward. Keep all three out of ordinary and featured shop pools.

Register all three in `item-asset-index.json`, regenerate Xcode resources and extend native item/reward previews. Refactor validators to assert **15 shop items remain unchanged** while checking **18 total bundled item packages**. Keep ZIPs, Blender masters, source atlases and review renders outside runtime resources. Accept unavailable artwork honestly without changing ownership or skill effects.

The Satchel is static, has no skill, no attraction and no plant growth fields. Its inventory, placement, collision, rotation and storage use existing item paths. Use the measured envelope/radius proposals with native placement verification. Do not normalize item dimensions or rescale the Basin again.

### 8.2 Guiding Glow

Publish a fixed percentage component using existing validated effect vocabulary:

```json
{
  "id": "guiding_glow",
  "name": "Guiding Glow",
  "system": "growth",
  "scope": "activity",
  "metric": "steps",
  "target": "all_planted_plants",
  "magnitude": { "type": "fixed", "value": "0.03" },
  "stackingGroup": "item_guiding_glow"
}
```

Add required component version and description using the existing profile schema. Emit only while a Basin is placed; strongest once per group across duplicates. Respect current activity and combined-water caps, species step coefficients, frozen activity snapshots and maturity clamps. A zero step coefficient remains zero. No extra XP, gems, visitor income, other-metric bonuses or flat-grant amplification.

The normal pre-membership-change sync/settlement remains authoritative for storing/placing. No backfill for steps already credited or evidence-only catch-up. Show the profile in item details, shared Garden skills and draft/next-action previews; backend/native results must agree on duplicate and cap behavior.

### 8.3 Generalize triggered grants before adding Orrery

Do not overload `dailyGrant` with an Orrery-shaped object. Today `item_skills.descriptions()`, `SkillSnapshot.summary()`, native `DailyGrant` decoding, available skill collection and prediction all assume Morning Rain / 2.5 water.

Introduce a versioned discriminated triggered-grant contract, for example:

- `local_midnight_flat_water`: existing Morning Rain behavior, unchanged.
- `daily_placed_steps_flat_water`: daily shared placed-eligible step counter and tier list for Alignment of Worlds.

Keep the old `dailyGrant` field readable for existing profiles/clients while adding an explicit `triggeredGrants` or equivalent field for the new shape. No immutable published profile edits. Switch on family/type everywhere; unknown types become unavailable, never interpreted as Morning Rain. Only include the two required trigger types; a general scripting engine is unnecessary.

Update backend item facts/description/strategy serialization, summary scopes/units and native decoding/evaluation/copy together. Present triggered water separately from percentage growth factors. Include relevant daily progress/version in preview context/fingerprint when it affects predicted eligibility; previews explain future effect but never award water.

### 8.4 Alignment of Worlds accounting

| Daily placed-eligible steps | Incremental flat water per eligible placed plant | Cumulative |
| ---: | ---: | ---: |
| 2,000 | 3 | 3 |
| 4,000 | 4 | 7 |
| 6,000 | 5 | 12 |

Implement a shared owner/date/family counter independent of the particular Orrery copy and independent of expedition runs. Count validated **newly eligible normal-sync steps**, before water caps, only when at least one Orrery is in that upload's authoritative placed snapshot. Follow the game's existing credit-time membership semantics; daily aggregates cannot prove each physical step's historical placement. Preserve the pre-membership-change reconciliation barrier. Do not promise timestamp-level attribution without a separately designed placement-history/Health interval feature.

Detailed ordering:

1. Settle due Morning Rain and existing membership accounting before taking the normal activity snapshot.
2. Validate normal activity and apply ordinary percentage water using the existing frozen pre-credit snapshot.
3. For each credited game date in deterministic order, add only its new eligible step delta to that date's shared Orrery counter when the source was placed. Steps received while stored are consumed by ordinary accounting but add nothing to Orrery progress. Placing later cannot recover them.
4. Determine newly crossed tiers; write a unique owner/date/family/tier grant identity even if no plant can receive water. Replays, storing/replacing and extra copies cannot repeat it.
5. Apply each tier as one complete recipient batch, in threshold order, to plants in the qualifying transaction's placed membership. Record source copies, pinned profile/tier, counter before/after, recipient IDs, requested/awarded micro-units and effective server growth boundary. Use exact integer micro-units and maturity clamps; do not multiply flat water by any percentage skill or activate zero step coefficients as a percentage effect. Flat water itself follows the selected all-eligible-plants targeting, independently of step coefficient.
6. Update real maturity/discovery, expedition stage/snapshot observers, garden versions, visitor accounting and recaps for actual growth. Attribute this water to its own grant family; no second activity credit, XP, gem or step reward.

Reset means a fresh counter for the next saved game date; retain old date grant identities. Late **normal-window** eligible credits may settle that date's remaining tiers under the same credit-time membership rule. Evidence-only old-date uploads never count. Storing pauses progress for each date; re-placing preserves it. A batch crossing all tiers gives 3 + 4 + 5 once, not 3 + 7 + 12. A later-added plant gets no retroactive tier grant.

For activity-driven Orrery growth use the server transaction boundary when attributing stage advancement to an expedition. Do not backdate plant growth into an ended month because the step date was earlier. Keep the frozen ordinary percentage snapshot unchanged by plants maturing during subsequent flat grants. Feed the combined real growth into recap/history without inflating ordinary activity-water totals or presenting Orrery water as Morning Rain.

## 9. Native page and popup

### Navigation and lifecycle

Add `ForestDestination.expedition` as a fifth bottom destination and an Expedition host within the existing app shell. Keep Garden mounted and preserve Edit's existing behavior. Audit fixed-count layout tests and narrow-screen labels; use a suitable map/puzzle symbol and the same green selection underline. Wire the host to an account/server-scoped `ExpeditionCoordinator` installed/deactivated with `GardenConnection`.

The coordinator owns current/archive snapshots, confirmation timestamps, run/progress versions, selection and evidence recovery status. Claims delegate to the shared durable collection mutation service. A dedicated evidence coordinator shares Health query/auth infrastructure but does not block page rendering or routine editing for the whole historical recovery.

Refresh after confirmed activity, garden saves/growth, active welcomes, pack openings and reward claims; coalesce invalidations instead of polling the entire month. Drop stale asynchronous results using account/server generation and run/version checks. The old run can still accept its correctly identified claim/evidence response without replacing the current screen.

### Screen hierarchy

1. Expedition title and real calendar-month label; server-anchored remaining time.
2. Overall bar with **`x / 9` inside**; nearby Orrery preview and compact four-quest Basin marker. Supplemental text can say `Quests completed` and `2 rewards ready` without duplicating the fraction.
3. One continuous 3×3 jigsaw, greyscale base with full-colour clipped overlays for **claimed piece rewards**. Subtle seams, selection and reward-ready indicators.
4. Contextual final `Claim reward` / claimed state and compact archive access. No `Grand reward` label and no `View all 9 quests` button.

A completed-but-unclaimed quest advances the overall bar but remains greyscale with a ready marker. At 9/9 with outstanding piece rewards, do not falsely show the fully restored illustration. Claiming Basin/Orrery reveals no puzzle piece. The four-quest marker uses a threshold label/action; add no redundant progress bar unless it helps, and any such bar must contain its own ratio.

### Popup composition

Use a centred overlay above the puzzle, with subtle dimming and a close control with a 44-point hit area. Reuse journal typography, rounded parchment surfaces, vine border, sage progress track and green action/state treatment from current milestones. Preserve orange light in the painting/reveal; the old mockup's orange controls do not override the current milestones styling.

Order:

1. Exact quest requirement, naturally wrapped, **without a separate quest title**.
2. Progress immediately beneath, **ratio overlaid inside the bar** (`2 / 3`, `28 / 50`, `12,450 / 30,000`). Unknown progress is unavailable, not zero. Keep readable ink across both fill and empty portions.
3. Compact requirement/status text only where useful, such as missing tree/herb or stage categories.
4. Milestone-style reward box with **quantity first**, then real artwork; use multiple compact rows for a future bundle. Example: `250 <token artwork>`. Item rewards use their exact pinned thumbnail. Full reward names remain in VoiceOver and an inspection affordance.
5. `Collect reward`, disabled until server-confirmed complete and permitted; pending/retry/capacity/claimed states remain explicit. Four/nine completion popups use the same materials and quantity-first rewards, with the selected claim wording.

Extract a value-driven `JournalProgressBar` primitive from the existing bar if useful, keeping `MilestoneQuestProgress` as an adapter so milestone behavior and tests remain stable. Extract shared reward artwork/state framing, but let Expedition choose quantity-first order. Do not make the existing private milestone row types depend on expedition models or expand all existing rows to support item rewards unnecessarily.

### Puzzle geometry and accessibility

One square image and nine normalized reusable vector shapes form a complete partition. Derive clipping and hit testing from the **same geometry**, with no gaps/overlap ambiguity at seams; stable piece IDs map exactly once to stable quest IDs. Greyscale derives from the same image. Validate seams and hit positions at real device sizes.

Each piece is an accessible button labelled with requirement, progress and state. Selection is available without seeing colour. Restore focus after popup dismissal; prevent VoiceOver from interacting with the dimmed background. Support Dynamic Type, Reduce Motion and Reduce Transparency. At large sizes, permit bounded popup content scrolling while keeping Close/claim reachable; grow bar height or wrap its in-bar label rather than clipping it or moving the ratio outside.

At ordinary text sizes the board should fit comfortably without mandatory pan/zoom. Allow page scrolling at accessibility sizes. Reveal only after a verified claim and respect Reduce Motion. Reopening/reloading or catching up completion never replays earlier celebrations.

Required states include initial loading, no published series, cached/offline, unsupported update, evidence syncing/unavailable, wrong/changed account, missing artwork with textual quest fallback, incomplete, ready, pending/uncertain claim, full pack/item storage, claimed, ended/grace and archived. A popup open across renewal remains tied to its old run or closes with an honest ended state; never silently retarget it.

## 10. API and content tooling

Recommended new routes:

| Route | Contract |
| --- | --- |
| `GET /v1/me/expeditions/current` | Server time, series/month/run/template IDs, frozen bounds/timezone, nine quest states, 4/9 entitlements, progress version, asset manifest and evidence capabilities/coverage. Honest empty state before publication/start. |
| `GET /v1/me/expeditions` | Owner archive summaries and cursor; include earned unclaimed counts and grace state. |
| `GET /v1/me/expeditions/{runId}` | Full current/archived state and pinned rewards; same authorization as current. |
| `POST /v1/me/expeditions/{runId}/evidence` | Versioned bounded historical facts plus query coverage, request/device IDs and observation time; returns acknowledged chunk/coverage and progress version. No economic side effects. |
| `POST /v1/me/expeditions/{runId}/rewards/{entitlementId}/claim` | Durable request UUID; server-pinned reward claim and complete receipt. |

Use strict native validation for IDs, exact integer strings, current/target bounds, completion/claim consistency, asset identity and version. Enumerate known unavailable reasons/capability behavior. Return monotonic versions for wallet/garden/expedition updates so an older refresh cannot undo a receipt. Server time anchors countdowns; use uptime between confirmations rather than trusting device clock edits.

Add preview-first CLI commands for:

- Validate/publish reward-item definitions and skill profiles independently of shop releases.
- Validate/publish an immutable expedition template.
- Enable the recurring series with an explicit first month and template.
- Preview/assign a replacement template effective in a future month.
- Resolve/inspect a month and optionally warm upcoming definitions without account reward grants.

Names are proposed commands, not available executables yet. Default preview rolls back writes. Applying an identical publication is repeat-safe; a changed definition under the same version is rejected. Validate all nine supported evaluators, one-to-one geometry, thresholds, reward totals, referenced published pack/item/profile versions, asset hashes/paths, supported capabilities, boundaries and newbie acquisition constraints. Reject retroactive starts that would require inventing unobserved action evidence.

Bundle the first clean painting/masks and all three item packages. Repeating months reuse those same assets. Downloadable content is deferred until a later expedition actually needs new art without an app update; preserve versioned asset references now so that delivery can be added without changing earned rewards.

## 11. Implementation sequence and reviewable increments

Do not start with an isolated polished screen whose progress is disconnected from the backend. Implement vertical slices with real contracts and explicitly marked development content.

| Stage | Work and principal files | Exit evidence |
| --- | --- | --- |
| **0. Lock content and fixtures** | Add validated Observatory content and reward-item fixture package; record canonical IDs/full display names, trigger schema, asset status and release inputs. Reconcile stale passages in the product spec. | Exact nine quest/reward mapping and deterministic fixture; no publication or changed game data. |
| **1. Persistence and recurrence** | New models/migration(s), template/series/month resolution and CLI preview. Register metadata in `main.py` / Alembic environment; classify storage. Latest migration is currently `0020`; choose the next free revision at implementation time. | January/February/leap year/DST/year rollover, lazy enrollment, future replacements, uniqueness/concurrency, no destructive reset. |
| **2. Reward/item foundation** | Publish reward-only item definitions; extend shared bundle claim helpers, expedition entitlements/claims, bonus-gem reconciliation, capacity/replay/recovery. Add three assets to native index and update validators/project generator. | Stored item claims and unopened pack/currency rewards replay once, full capacity retains entitlement, old milestone/shop behavior unchanged. |
| **3. Non-Health quest vertical slice** | Garden snapshots, active visitor hooks, pack openings and common growth observer in `placement.py`, `services.py`, `visitors.py`, `collection.py`, `activity.py`, `daily_items.py`. | Actual transactions complete quests 3–8 correctly; 4/9 entitlements derive from completion; previews and stored visitors add nothing. |
| **4. Shared Health evidence** | Extract canonical workout facts without changing economic results; implement date/epoch high-water merge and recent-sync observers for quests 1/2/9. | Exact boundaries, mixed sessions, cap independence, stable deduplication and existing activity regression pass. |
| **5. Bounded recovery** | Evidence route/coverage/queue; range Health reader, server capability/status, native evidence coordinator and lifecycle integration. | Three-week gap and 31-day month + grace recover without changing economic state; chunk interruption and replay work. |
| **6. Skill integration** | Guiding Glow profile; typed triggered grants; Orrery state/ledger/settlement; backend/native summaries, shared skills, preview fingerprints, growth observers/recaps/history. | 3% step-only resolver parity; exact 3/4/5 tier grants once; old Morning Rain unchanged; no catch-up water. |
| **7. Native Expedition flow** | `ExpeditionModels.swift`, API service, account-scoped coordinator/journal state, `ExpeditionScreen.swift`, puzzle shapes, centred popup/shared primitives; app fifth destination. | Real fixtures/current API, quantity-first rewards, all ratios inside bars, correct completion/reveal/claim state, archive and renewal. |
| **8. Art and native acceptance** | Clean painting, geometry/resources, real item previews, bounded reveal; project regeneration, native tests and device Health verification. | Desktop/source checks plus actual Apple SDK builds, hosted tests, narrow/large-type layouts and iPhone playback/sync evidence. |
| **9. Release preparation** | Isolated migration/recovery/maintenance/full regression; content/economy preview, docs, operational metrics and reviewed activation commands. | Reviewable launch package and explicit remaining release inputs. Source completion and live publication reported separately. |

Backend fixture contracts should be generated from real isolated HTTP flows and consumed by native tests, as current milestones/strategy contracts are. Include a `validate_expeditions_local.py` walkthrough with explicit fixture output mode; do not hand-maintain divergent backend/native reward schedules.

### Dependency order

Stages 1–2 establish identity and grants. Stage 3 establishes action/growth observers used by skills. Stage 4 precedes stage 5 and Orrery step accounting. Stage 6 must use the common observer rather than introducing a third growth implementation. Stage 7 can begin against stable fixtures after stages 1–2, with a functional end-to-end slice before visual polish. Native release waits for every evaluator, recovery, skill and claim path, even if artwork is ready earlier.

## 12. Validation matrix

Tests below should verify externally meaningful state, accounting, recovery or layout behavior. Avoid tests that only restate helper implementation.

| Area | Required scenarios |
| --- | --- |
| Monthly recurrence | First-of-month exact instant; 28/29/30/31-day months; leap/year transition; DST zones; phone timezone change; no scheduler; app closed/open at the shared UTC boundary; same content repeats after multiple months; future template replacement leaves prior runs pinned. |
| Reset scope | New counters/distinct sets/piece claims/milestones are independent; existing placed arrangement may immediately qualify; old items, wallet, lifetime milestones, pending claims and archive remain intact. Re-earn all three items in a new month without stacking skills. |
| Initialization | First action before tab visit counts; account created mid-month; published start before lazy enrollment; observed current layout versus proven historical layout; no retroactive taps/arrangements; due Morning Rain crossing month routes correctly. |
| Step evidence | 4,999/5,000; three distinct dates; 29,999/30,000; no daily minimum for total; baseline day subtraction once; daily water exhausted/all plants adult; lower/out-of-order totals; recent then catch-up and reverse; partial day/noon, delayed corrections, unavailable versus zero. |
| Device epochs | Replacement within a day/month; accepted prior epoch retained; unread pre-enrollment history rejected; parallel requests/second device; missing old provenance never assumed zero; evidence path cannot reset baseline or consume water eligibility. |
| Workouts | 1,999/2,000 m, 899/900 seconds, positive run duration; three runs/walks/mixed/same-day; long workout counts once; manual/mixed/hiking excluded; pauses/segments; overlap/source copies across chunks; repeated UUID; already imported for growth; no distance inference; boundary clipping and cross-midnight sessions. |
| Snapshot quests | Four simultaneous owned items, including duplicates; one copy placed repeatedly fails; all four stages in one complete snapshot; changing arrangements cannot union progress; qualifying initial garden; unsaved/invalid/stale/cancelled preview adds nothing; completion survives removal/sale. |
| Stage advancement | Four unique copies; one sprout→adult counts once; ordinary water, Morning Rain and Orrery all observed; real stage threshold equality; no pack-created sprout/replant/profile refresh credit; logical batches do not create false transient stage coverage. |
| Butterflies | Stored claims always zero for these quests; active welcome retry/alias counts once; simultaneous tree/herb of any stage and distinct copies; condition evaluated after settlement; 50 conditional contributes 50 general; later placement never reclassifies a tap. |
| Packs | Three distinct committed openings across all kinds, including pre-owned/reward packs; failures and capacity blocks add nothing; interrupted/skipped animation after commit still counts; no progress for acquisition alone. |
| Reward integrity | Every exact bundle and intermediary total; jump from 3→9 creates Basin/Orrery independently; any claim order; full pack/item capacity; mixed bundle rollback; original UUID and aliases/concurrency; sold item cannot regrant; permanent replay after response compaction and month rollover. |
| Recovery/deadlines | 31-day earning + seven-day grace; almost-38-day-old first date; receipt strictly before deadline; data within earning bounds only; both grace/current runs; interrupted read/page/chunk/upload; repeated failed retries; completed Health goals stop historical reads; prior accepted requests replay after deadline. |
| No economic leakage | Historical evidence changes only evidence/progress/entitlements: unchanged water, plants, XP, wallets, normal credit watermarks, visitor income, permanent activity milestones and Orrery state. Later normal-window sync still grants legitimate economic credit once. |
| Guiding Glow | Placed/stored/duplicate; +3% step layer; other metrics and zero coefficient unchanged; shared caps; mixed plant/item groups; exact rounding; frozen snapshots; native preview parity; no flat-grant amplification. |
| Orrery | Threshold minus/equal/plus one; multi-tier batch; 3+4+5 amounts; once/day across copy replacement and repeats; store/pause/resume; pre-placement steps; no plants/all adults/late-added plants; late normal eligible dates; no evidence-only trigger; midnight/month reset independence; exact provenance, maturity/discovery/visitor/expedition/history effects. |
| Trigger compatibility | Morning Rain remains midnight 2.5 and duplicate-once; unknown trigger unavailable; Orrery never decoded/summarized as Morning Rain; unchanged percentage snapshot within a batch; unsupported old clients receive an honest update state. |
| Maintenance | Migration parity/upgrade, safe downgrade policy after publication/grants, model registration, table classification; token/gem/growth reconciliation; request compaction; history maintenance with pending/claimed/archived runs; all required identities/receipts survive. |
| Native state | Cache/restart, account/server switching, stale async response, simultaneous wallet changes, uncertain claim and failed refresh, old pending claim after renewal, active popup over boundary, unreadable Health and cancellation; no accidental reveal replay. |
| Native layout | 320/375/393/430-point widths, largest supported Dynamic Type, long actual descriptions/numbers, quantity-first artwork, in-bar ratios including inaccessible progress, popup reachable Close/claim, 44-point targets, VoiceOver focus/order, Reduce Motion/Transparency, five navigation controls, all nine seam hit areas. |
| Art/runtime | Hashes and bundle membership, missing/corrupt art fallback with reward access, exact scale and collision, stationary Basin comet/ripples, 144-second Orrery playback, Reduce Motion stills, dense-garden frame/memory measurements on iPhone. |

### Execution and evidence reporting

Use the repository's disposable PostgreSQL workflow: `FOREST_TEST_DATABASE_URL` points to a separate test admin connection; tests create/drop randomized `forest_test_*` databases. Do not migrate or run reward tests against the personal database.

During implementation, run focused new suites plus relevant activity/milestone/item/visitor/collection/skills/strategy/history/migration regressions, then one full backend regression after integration. Run Ruff, whitespace checks, generated contract freshness, resource/project validation and Swift syntax parsing. After adding sources/resources run `frontend/scripts/generate_project.py` and its check mode. Extend `tools/validate_items.py` before relying on frontend resource validation for the extra three packages.

On macOS run `bash frontend/scripts/test-mac.sh` for Apple SDK builds/hosted tests as documented; use a physical iPhone for HealthKit, background behavior, RealityKit animation and performance. Portable parsing or manifest checks cannot establish those results. Perform one batched visual/accessibility pass across supported widths/text sizes, fix its findings together and confirm once.

This planning pass ran the read-only three-item integrity checks in section 2. It did not run application tests, build Apple targets, migrate databases or publish content.

## 13. Scale, operations and release inputs

Ordinary action processing should resolve at most the current run plus relevant grace/historical-settlement runs, and evaluate only affected quests. Avoid a query per butterfly per quest or a full archive scan on every heartbeat. Bulk-load garden membership/tags and placed skills within the transaction. Bound evidence bytes, workouts, segments, query ranges, archive pages and recovery concurrency.

Add measured diagnostics for active run/template, reset/deadline, missing coverage by type, accepted/excluded workout reasons, evidence retries, capacity-blocked claims and publication gaps. Do not log raw Health payloads or authentication data. Record row/index/TOAST footprint and ordinary-versus-catch-up request timings using realistic fixtures; no measured per-user storage or sync latency budget exists yet.

Keep compact permanent completion, entitlements, claims, grant identities and sufficient evidence merge/replay facts. Any later evidence compaction needs an explicit safe cutoff after grace and pending recovery, preserving nonduplication for archive claims and device epochs. Do not delete monthly progress because a request expires or a growth trace reaches 30 days.

Before production activation supply:

- Explicit first earning month, with the series/template finalized before that month begins in any supported game timezone.
- Bundled clean observatory painting and nine-piece geometry/manifest (now supplied in source); complete native geometry/appearance acceptance.
- Published reward-only item/skill/pack versions and an explicit gift resale policy. If non-resellable gifts are selected, consider inventory capacity over repeated months and provide honest sale-unavailable UX; do not silently invent a disposal or token conversion mechanic.
- Economy/acquisition review of monthly repeat grants. The known herb-access risk, three pack openings and four placed items remain real; do not quietly change odds, quest thresholds or grant a guaranteed herb without a new content decision.
- Completed isolated backend/recovery/accounting validation and Mac/iPhone acceptance.

A source implementation can be developed and reviewed without these live activation inputs. Prepare exact preview reports and commands as the final release artifact; publication is a separate deliberate operation.

### Effort and scope

The old 20–35-day estimate predates several final requirements and should not be treated as a commitment. A working planning range for one developer familiar with this codebase is **approximately 30–45 engineering days**, including recurrence, recovery, reward claims, the trigger engine, native UI and integration validation, with uncertainty concentrated in device-epoch evidence, Orrery accounting and physical-device Health behavior. Asset integration reuses all three existing item packages; clean painting/mask production and review remain additional work. Re-estimate after the real evidence/trigger vertical slices; a recurrence-only prototype is not the full feature.

## 14. Completion checklist for the implementing chat

- [ ] Recurring monthly series works indefinitely without manual monthly republishing.
- [ ] Reset is first-of-month/server-UTC and preserves previous rewards/archive.
- [ ] All nine exact evaluators, overlapping evidence and confirmed snapshot rules work.
- [ ] Recent sync and bounded historical evidence share validation without sharing economic consumption.
- [ ] Nine piece rewards and independent 4/9 item entitlements claim safely in any order.
- [ ] Satchel, Basin and Orrery are registered, bundled, stored/placed and kept out of shop pools.
- [ ] Guiding Glow and Alignment of Worlds work, with Morning Rain compatibility and native prediction parity.
- [ ] All expedition bar ratios are inside their bars; popup rewards are quantity then artwork.
- [ ] Puzzle restores only confirmed claimed pieces; centred popup and accessibility match the journal/milestone language.
- [ ] Fifth navigation destination, account-scoped cache/queues, renewal, archive and stale-response handling work.
- [ ] Recovery, maintenance, wallet/growth reconciliation, generated fixtures and migration parity pass.
- [ ] Actual Mac/iPhone acceptance is recorded separately from portable checks.
- [ ] Remaining launch inputs and publication preview are explicit; no unsupported live-activation claim is made.
