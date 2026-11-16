# Stage 6 — Saved weekly shop plans and daily rotations

**Source update, 17 November 2026:** this design is now implemented with the
selected fifteen-item catalogue (6 Common / 5 Rare / 4 Epic), workbook prices,
UTC resets, one-copy featured allowances and automatic preparation/fallback.
All eight item skills are implemented in the same release. See
[current runtime and activation](backend/ITEM_ROTATIONS.md). Remaining placeholder
and ten-item statements below preserve the earlier planning record.

Date: 16 November 2026.

Status: implementation plan only. No rotations, new content, prices, database changes or live activation are implemented by this document. The user approved **three distinct Commons sampled daily without replacement, three randomly selected Rare days and two independently selected Epic days per week**, with overlap allowed. There are no fixed permanent items or always-available Rare. The recommended initial catalogue is ten items: five Common, three Rare and two Epic; actual identities and prices remain undecided. Item IDs below are placeholders. This supersedes the fixed permanent collection and earlier everyday Rare / 70–30 / Epic Saturday proposals. Timing, allowances and fallback defaults below remain recommendations for implementation.

## 1. Schedule and feasibility

Packs stay above decorations. Decorations have these slots:

| Section / slot | Rule |
| --- | --- |
| Daily Common 1–3 | Three distinct items sampled from the Common pool without replacement each day |
| Rare feature | One guaranteed Rare offer on each of three randomly selected distinct days per week |
| Epic feature | One guaranteed Epic offer on each of two independently selected distinct days per week |

Generate all seven days together and save the outcomes. Sample three of the seven shop dates uniformly without replacement for Rare features. Independently sample two of the seven dates uniformly without replacement for Epic features. Do not exclude Rare days from the Epic draw or enforce a particular overlap. There is no guaranteed weekday, Epic Saturday override or daily 70/30 rarity roll.

On a selected day, the corresponding rarity is guaranteed provided an eligible candidate exists; randomness decides the dates and item identities, not whether a scheduled feature appears. With sufficient candidates, an ordinary day has three Commons, a single-feature day four offers, and an overlap day five offers (three Commons, one Rare and one Epic). Buying is deterministic: the customer sees and receives the selected item. Legendary items and event-exclusive items are excluded.

Only the number of daily Common slots is permanent; their item identities rotate. Sample all three from the eligible Common pool without replacement, so the same item cannot occupy two slots on one day, even through different definition versions. A Common may appear again on later days. Keep Common, Rare and Epic pools separate by pinned item rarity, and enforce item-identity uniqueness across the whole day's offers.

### Initial catalogue and expansion

Recommend **ten launch items: five Common, three Rare and two Epic**. Five Commons offer daily combinations while three Rares and two Epics allow every featured appearance within a week to use a different item. At least one Common must repeat between adjacent days when choosing three from five; individual repeats are expected. Prefer a different complete Common trio from yesterday when feasible.

The technical minimum is five items (three Common, one Rare and one Epic), permitting all slots to fill with repeats across days, but the Common selection would look identical daily. Three eligible Commons are required to promise three distinct daily Common offers. Names, art, exact pool sizes and prices can be decided later; the ten-item split is the recommended content target, not a finalized catalogue.

As the catalogue expands, publish eligible additions into the corresponding Common, Rare or Epic pool. No schedule redesign or additional slots are needed. Start with equal item weights within each rarity; later policy versions may configure unequal weights. New entries, removals, weights, prices and definition defaults affect only future, ungenerated weeks through versioned releases. They never change or reroll any already saved week, even its future days. If next week has already been generated, the expanded pool first applies to the next ungenerated week. Runtime pool membership never depends on a mutable catalogue query.

### Weekly rarity allocation

The weekly allocation is exactly **twenty-one Common slots (three daily), three Rare appearances and two Epic appearances**, assuming eligible candidates exist. Allocate the five feature slots before selecting item identities. Sampling dates without replacement prevents two appearances of the same featured rarity on one day; independent rarity draws allow both rarities to coincide.

- Zero, one or two days can have both a Rare and an Epic feature.
- Three to five days have at least one additional offer.
- Two to four days have only that day's three sampled Commons.

For any particular weekday the Rare selection probability is 3/7 and the Epic selection probability is 2/7. These are consequences of weekly sampling, not independent daily rolls. Persist both selected date sets, every selected item and any unfillable scheduled-slot reason. A date with no scheduled feature is normal, not a generation failure. Never move an unfillable feature to another day or roll extra dates to compensate.

### Illustrative seven-day preview

`C1`–`C5`, `R1`–`R3` and `E1`–`E2` illustrate the recommended ten-item launch pool, not a decided catalogue. Every Common trio contains three distinct item identities; no item is permanently pinned to a slot.

| Shop date (UTC) | Daily Commons | Rare feature | Epic feature | Total decoration offers |
| --- | --- | --- | --- | --- |
| Mon 16 Nov 2026 | C1, C2, C3 | R1 | — | 4 |
| Tue 17 Nov 2026 | C2, C4, C5 | — | — | 3 |
| Wed 18 Nov 2026 | C1, C3, C5 | R2 | E1 | 5 |
| Thu 19 Nov 2026 | C1, C2, C4 | — | — | 3 |
| Fri 20 Nov 2026 | C2, C3, C5 | — | — | 3 |
| Sat 21 Nov 2026 | C1, C4, C5 | R3 | — | 4 |
| Sun 22 Nov 2026 | C2, C3, C4 | — | E2 | 4 |

This example satisfies the twenty-one-Common/three-Rare/two-Epic allocation with one overlap day. Other weeks choose different dates and candidates; Saturday has no special status. The implemented preview must list actual saved IDs, versions, prices, allowances, start/end instants and any fallback reason for all seven days, including Common-only days. Distinguish unscheduled features from scheduled slots omitted for missing candidates. Label unsaved simulations separately from published plans.

## 2. Two independent definitions of a day

**Shop day:** one global interval, recommended `[00:00 UTC, next 00:00 UTC)`. Shop week begins Monday at 00:00 UTC. The three Rare dates and two Epic dates refer to this global shop calendar. Every account receives the same global selections, offer identities, prices and intervals; remaining purchase allowance can differ by account.

**Activity day:** midnight to the following midnight in the account's saved IANA `game_timezone`, such as `Asia/Singapore`. Continue using that timezone for HealthKit query buckets, step credit, activity caps and activity-date bookkeeping. Compute consecutive local midnights, not fixed 24-hour durations, so daylight-saving days remain correct.

For a Singapore account, shop reset occurs at 08:00 local time, while the step day still starts at 00:00 local time. At 08:00, new shop stock becomes active and the current step bucket remains the same. At local midnight, the activity date changes and the current shop interval remains active.

An authoritative server clock supplies an instant; a timezone determines the calendar date containing it. UTC storage does not force UTC activity days. Do not reuse the shop date for activity, overwrite `game_timezone`, alter step baselines, or route shop countdown offsets into HealthKit timestamps or activity uploads.

The inspected account API sets `game_timezone` at registration and does not expose it in profile updates. The native activity coordinator already passes that saved timezone to HealthKit. A device timezone change therefore must not change the shop or automatically rebucket activity. If activity days should follow travel rather than the saved home timezone, design an explicit account-timezone migration with effective boundaries and duplicate-credit protection separately.

Changing the device wall clock must not change shop availability. Existing HealthKit reads use device `Date()` and the activity service validates observations against server time; Stage 6 must not claim to solve all activity behavior under arbitrary device-clock tampering. Its regression requirement is unchanged activity bucketing/credit rules, plus clock-independent shop availability.

## 3. Versioned policy and publication

Persist an immutable policy version containing:

- Shop identity, UTC daily/weekly boundary and effective week.
- Three daily Common slots sampled without replacement from a pinned Common pool; no fixed permanent item references.
- Three Rare dates and two Epic dates sampled independently without replacement, with overlap allowed.
- Explicit candidate release snapshot, positive integer selection weights, channel eligibility, sale eligibility and supported client compatibility floor.
- Repeat preferences, hard exclusions, fallback order and allowance rules.
- Versioned prices/currency and resale/valuation references; keep token-only commerce initially.
- Generator algorithm version and a durable seed/key version for reproducibility and preview.

Policy changes become effective at an ungenerated future week boundary. Refuse replacement of an already saved week, including future days. Schedule later changes for the next ungenerated week. Publishing new defaults must not mutate existing item definitions, prices, valuations, policies or saved offers.

Pool expansion is a versioned content release, not an instruction to regenerate stock. Pin Common, Rare and Epic memberships with their definition versions, weights and prices together; apply additions only when generating an eligible unsaved future week.

Resolve policy and candidate releases by their historical effective week, not the current process defaults or whatever catalogue is active when the first request arrives. Retain these immutable releases so a missed job can recover the intended week even after catalogue defaults change. Missing historical configuration returns a clear unavailable result; it must not invent a new policy.

Filter candidates using the release snapshot and compatibility floor, not the requesting account, inventory or individual client capabilities. A client that cannot display the published global stock receives update-required behavior, not a personalized reroll. Include only candidates eligible throughout the relevant offer interval. Persist the full resolved eligible set for audit; ordinary catalogue edits do not retrospectively invalidate saved offers.

Exceptional retirement of unsafe/broken content, if needed, is an explicit withdrawal mechanism with an audit reason and unavailable slot. It must not replace the item with a random selection or change a pending purchase's price.

## 4. Weighted selection, repeats and small-pool fallbacks

Allocate the three Rare dates and two Epic dates first. Process all seven days chronologically: sample the three Commons, then a Rare and an Epic only where each feature is scheduled. Use equal positive weights initially, with versioned positive integer weights supported later. Sort candidates by stable item identity before drawing, and compare duplicates by item ID across definition versions. A release must resolve each identity to one pinned definition/rarity; reject duplicate or cross-rarity identity entries and nonpositive weights. Item weights do not alter the three-Common daily count or the featured date allocation. Do not generate extra Rare/Epic offers on unscheduled days.

### Commons: without replacement within each day

Draw from the remaining eligible Common identities and remove each selected identity before the next draw. Reset this selection pool for the next day; this is not sampling without replacement across the whole week. **All three daily Common identities must be distinct**, regardless of definition versions.

Prefer a different complete trio from yesterday, including across a week boundary, while allowing individual repeats. A bounded rule is: sample the provisional trio without replacement; if it exactly matches yesterday's three-item set and another eligible Common exists, replace one randomly selected member with an eligible Common outside the trio using the configured weights. Save this adjustment for audit. If no alternative exists, keep the trio. This is a soft preference and never reduces the number of filled slots. Do not exclude all yesterday's Commons: three slots from a five-item pool cannot satisfy that restriction.

If fewer than three eligible Common identities remain, fill each distinct candidate at most once and persist omissions for the remaining slots (`no_eligible_common` or `same_day_pool_exhausted`). Never duplicate a Common, borrow a higher rarity, or pull a new item from mutable catalogue defaults to fill a hole.

### Rare/Epic features: repeat preferences and fallbacks

Prefer items not yet featured earlier in the same saved week, and prefer not to repeat yesterday's item. These are soft preferences; same-day uniqueness, rarity and release/channel/asset eligibility remain hard constraints. For each scheduled feature:

1. Try the required rarity, excluding today's selections, earlier same-week featured identities and yesterday's items.
2. If empty, allow yesterday's items while preserving same-week uniqueness and all hard constraints.
3. If still empty, allow earlier same-week repeats, preferring candidates not shown yesterday if any remain; otherwise allow yesterday too.
4. If no eligible distinct identity exists, persist an omitted slot with a machine-readable reason such as `no_eligible_rare`, `no_eligible_epic` or `same_day_pool_exhausted`. Show only available stock; no purchasable placeholder.

Record preference relaxations. Three eligible Rares and two eligible Epics can provide five different featured items in a week; smaller pools repeat as needed. Never reroll the scheduled rarity/date, downgrade Epics, promote Rares or Commons, or include event-only rewards. A guaranteed feature can still be unavailable when its rarity pool is empty: surface this explicitly in preview/validation rather than promise impossible stock.

| Eligible pools | Declared outcome |
| --- | --- |
| At least 3 Commons + 1 Rare + 1 Epic | All twenty-six scheduled slots filled; featured repeats across days allowed |
| Recommended 5 Commons + 3 Rares + 2 Epics | Three distinct Commons daily with varied combinations; all five featured appearances can use different items |
| Exactly 3 Commons | Same three Common identities daily; allow the repeated trio |
| Only 1 or 2 Commons | Show each once per day; explicitly omit unfillable Common slots |
| No Commons | Omit three Common slots daily; retain any eligible scheduled Rare/Epic offers |
| No Rares or no Epics | Keep Common stock and other rarity features; omit only scheduled slots of the missing rarity |
| Empty | Omit all twenty-six scheduled slots; show clear unavailable/no-stock state |

Publication validation reports inability to fill every scheduled slot. Normal launch requires at least three eligible Commons, one Rare and one Epic, each available throughout its selected intervals; ten items is the recommended variety target. A deliberately incomplete release can explicitly acknowledge omissions. Request-time recovery always follows the saved policy rather than stalling or improvising another tier. Placeholder candidates suffice for implementation review; real content publication waits for the actual catalogue and prices.

Repeat history must not depend on account traffic. Generate sequential weeks in order from a persisted rotation launch week; retain compact prior selections for cooldowns. Recover missing predecessor weeks in bounded transactions before the target week. If a long outage exceeds the request budget, return retryable unavailability and let preparation catch up; never silently skip repeat history or publish a partial week.

## 5. Saved records and idempotent preparation

Proposed additional records (names to settle during implementation):

| Record | Durable content / uniqueness |
| --- | --- |
| Policy + catalogue release | Immutable versions, effective weeks, resolved candidates, prices and weights |
| Weekly plan | Unique `(shop_id, week_start)`; pinned releases/algorithm/seed; twenty-one Common slots, three Rare dates, two Epic dates and saved candidate snapshot |
| Daily rotation | Unique `(shop_id, shop_date)`; parent week; UTC start/end |
| Scheduled slot / offer | Unique `(rotation_id, slot_key)` for `common_1`, `common_2`, `common_3`, `rare` or `epic`; twenty-one Common plus five scheduled feature slots per week, each with selected item/version or omission; frozen price, valuation, display/asset references and limit |
| Allowance usage | Unique `(account_id, allowance_key)`; durable purchased quantity |

Save all seven daily rotations, including Common-only days; unscheduled Rare/Epic slots need no offer records. Every selected offer, including a Common, has its own saved identity, pinned price and immutable interval. Do not simulate expiry by toggling a shared `active` flag at midnight or recompute Commons per request. Distinguish global stock from account-specific remaining allowances in the response. At rollout, replace legacy always-available item offers with the saved-rotation read path; do not accidentally keep the old bench offer as an extra permanent slot. Preserve all previously completed receipts and owned-copy valuations.

Create one `ensure_week` service used by the preparation command and request fallback. Acquire a shop-scoped PostgreSQL transaction/advisory lock, recheck existing plans, resolve the pinned releases, generate chronologically, then commit the whole week and all seven daily rows atomically. All API instances use the same database lock namespace. Database uniqueness is an additional safeguard; losing contenders return the existing saved result. Avoid process-only locks and partial-day publication.

Prepare the upcoming Monday week on Sunday at 00:00 UTC, retrying periodically; also ensure the current week during startup/recovery of the dedicated preparation runner. The existing retention maintenance service is not a shop scheduler. Add a separate command/runner or explicit scheduling integration. Preparation spends no currency and grants nothing.

**Routine weekly operation must be fully automatic after initial implementation, deployment and catalogue/policy configuration.** Deploy and enable the preparation runner as part of the feature, with automatic restart/retry behavior. It selects dates, selects items and saves upcoming weeks without the owner running a weekly command, injecting code, providing a seed or approving each roll. A preview/preparation CLI is optional tooling for inspection and troubleshooting, not a required weekly step. Once published, interval activation is automatic even with every client closed. The fallback below recovers a missed job automatically when the shop is requested. Completing or intentionally changing the catalogue is a separate content-authoring action, not weekly maintenance.

Shop requests run `ensure_week` when the required week is absent, through the same publication path. Always use saved rows if present. Requests across midnight must recheck the interval with fresh authoritative time before returning; ensure the newly required week if the request crossed a week boundary while waiting. Only active offers appear in the current response.

Run generation in its own completed transaction before acquiring account/garden commerce locks. The current collection summary acquires the account lock; integrate fallback before that transaction or through a separate shop read service. Establish one documented lock order and ensure the preparation path never waits for account locks. Do not acquire a shop-generation lock from inside an account purchase transaction.

## 6. Purchases and per-account allowances

Recommended defaults: daily Common offers have no purchase quota beyond existing capacity/funds/request-quantity rules, but expire with their saved daily interval. Each Rare/Epic featured offer allows **one copy per account for that rotation**. An overlap day permits two featured copies, a single-feature day one, and a Common-only day none; a fully filled week provides five featured purchase opportunities. A later appearance is a new offer/allowance. Different request IDs, devices, selling the copy, or switching accounts cannot reset the original account's usage. Preserve usage even when response caches are compacted.

Continue the established account-then-garden lock order and durable request hashing/replay. For a purchase:

1. Authenticate, acquire the account lock and check durable completed-request replay first. Return the original matching receipt even after rotation expiry, sale of the copy, catalogue changes or restart. Reused IDs with different payloads remain conflicts.
2. Acquire the remaining established locks. Load the exact saved offer/version; never accept a client price or look up a mutable default price.
3. Read fresh authoritative time after lock waits and validate `starts_at <= now < ends_at`, active publication, eligibility and remaining allowance. Use this sampled instant as the purchase acceptance boundary; persist it. A request beginning before reset but reaching validation at reset is expired.
4. Validate the whole quantity, capacity and funds. Atomically deduct, grant pinned owned copies/valuations, increment allowance, update wallet version, and save the durable receipt.

Failure changes no wallet, owned items, allowance or receipt state. A stale, uncompleted request at exactly `ends_at` returns `stale_offer` and prompts refresh. Never silently substitute today's offer or attach the old UUID to a new purchase. A genuine completed-request retry remains eligible for replay while fresh purchases are disabled in the stale/offline UI.

## 7. Client refresh without restarting

Include `serverNow`, `shopTimezone`, `rotationId`, `startsAt`, `endsAt`, exact offers and remaining allowances in the shop response. Use the existing injectable `request_clock` path for reads and purchases; runtime uses fresh PostgreSQL time.

Anchor a countdown to the response's server instant and monotonic elapsed time, using the existing `LifecycleClock` / `ContinuousClock` pattern. Do not subtract device `Date()` from `endsAt`. Account for response latency conservatively and refresh when the estimate reaches the boundary; the server always decides purchases. Discard old responses from another account or an older fetch/rotation.

Refresh on entering Shop, foreground return, and boundary crossing while Shop is visible. Coalesce these triggers with existing pending-purchase recovery; a refresh skipped because the coordinator is busy must be retried. Invalidate an expired purchase sheet/confirmation too, rather than leave a stale offer actionable. If the app stays in the foreground outside Shop, fetch current stock on its next entry.

At countdown zero, disable new purchases from expired cached offers and fetch the active rotation. If offline, show an expired/offline state, retry on connectivity/foreground and never advertise the old offer as valid. Completed-operation recovery must still retain its original UUID and body.

**“App closed between visits” means the test closes the client before reset and opens it afterward to prove that activation does not depend on a running app.** It does not require closing/reopening to update. No timer or background wake is required while the app is closed: saved intervals become active by server-time comparison, and launch fetches the current one. An open, connected Shop refreshes automatically at the boundary.

Show local reset time as helpful display text and identify the global shop calendar for dated features. Changing display timezone changes that text only, never intervals, seeds or allowances. On Common-only days, omit the featured section or show concise no-feature-today copy; do not backfill it with extra Common or random higher-rarity offers. Refresh and invalidate expired Common purchase confirmations as well as featured ones.

## 8. Implementation sequence and code touchpoints

1. Add immutable policy/release, weekly/daily/slot and allowance models plus the migration following `0019_item_commerce`. Validate populated upgrades without altering existing benches, wallets, placements or receipts.
2. Add the pure date allocation and item-selection generator, daily Common sampling without replacement, repeat preferences and ordered fallback rules. Add the transactional `ensure_week` service, publication validator and preview/preparation CLI in `backend/src/forest_api/cli.py`. Pin all three candidate pools and release inputs before enabling rotations.
3. Integrate shop reads with `collection.py` / `collection_routes.py`, clock injection from `server_clock.py`, and expiry/allowances in `item_commerce.py`. Keep receipt compaction/reconciliation behavior compatible.
4. Add and enable scheduled preparation separately from retention maintenance in `backend/compose.yaml` or the deployed scheduling platform, including restart/retry configuration; use the same idempotent service as fallback. Verify unattended weekly generation without invoking the optional CLI.
5. Extend native `ItemModels.swift`, collection decoding/caching and `CollectionCoordinator.swift` for intervals, allowances and clock anchoring. Update `CollectionScreen.swift` / `ItemCommerceViews.swift` with daily sections, countdown and refresh. Its current foreground handler refreshes Catalog only, so Shop needs explicit integration.
6. Add backend reset/concurrency/persistence tests, Swift clock/lifecycle/recovery tests, contract fixtures, and seven-day preview acceptance instructions. Keep `ActivitySyncCoordinator.swift` and HealthKit bucket definitions independent of shop time.

The full catalogue is intentionally undecided. Aim for ten launch items (five Common, three Rare, two Epic), using fixture/placeholder content for implementation review rather than choosing production identities or prices here. Current published source commerce supports the Common Wooden Bench only; new asset files do not establish eligible definitions or published sale offers. Before live launch, publish compatible definitions, art and token prices for at least three Commons, one Rare and one Epic, ideally the recommended ten. The bench can join the Common pool rather than remain permanently available; previous purchases retain their pinned price/resale and replay behavior. Later content expands the appropriate pools for future, ungenerated weeks. Further item skills are outside Stage 6.

## 9. Completion gate and reviewable demonstration

Use a controllable server clock injected into the app factory, read services, purchase services and preparation service. Also inject native monotonic timing/network responses for deterministic client tests. No production public “advance clock” endpoint. Tests use an isolated database; preview defaults to read-only inspection or a clearly marked rollback simulation.

| Check | Required evidence |
| --- | --- |
| Immediately before reset | At `T - 1 microsecond`, old interval and new purchases valid |
| Exactly at reset | At `T`, new interval active; fresh old-offer purchase rejected, wallet/grants/allowance unchanged |
| Lock wait across reset | Purchase waits before validation; fresh post-lock sample at `T` rejects old offer |
| Completed replay after expiry | Same UUID/body returns original receipt after expiry, compaction and API restart, with no second spend/grant |
| Global stock | Two accounts in different activity timezones receive identical global offers at one instant; only allowance usage differs |
| Rarity allocation | Three Common slots on each day; exactly three distinct Rare dates and two distinct Epic dates sampled independently; controlled draws demonstrate zero, one and two overlap days; every filled slot matches its saved rarity; every omission explained; no extra features on unscheduled days |
| Common sampling without replacement | Each day contains three distinct Common identities when pools suffice; another definition version cannot duplicate an item; later-day repeats are allowed; a three-item pool fills every day without omissions |
| Variety and repeat fallbacks | With five Commons, avoid identical consecutive complete trios using the declared adjustment; allow shared members; with three Commons, keep the same trio. Three Rares/two Epics yield distinct featured items within the week; smaller pools relax preferences without changing scheduled dates |
| Rarity pools and expansion | Pools resolve each identity to one definition/rarity; no fixed permanent Rare or extra legacy bench offer. Add candidates to each pool after saving a week: saved offers stay identical, and only the next eligible ungenerated week can use new candidates |
| Concurrent fallback | Separate sessions/API instances race on a missing Monday week; exactly one week, seven days and twenty-six scheduled-slot records (including any omissions) are committed, all responses agree |
| Stable publication | Restart API, change catalogue defaults/weights/prices and fetch every saved day; identical saved identities, prices and allocations |
| Missed job | Skip preparation, request after reset and recover full week from effective historical releases; later preparation is a no-op |
| Unattended preparation | Advance the injected clock through the preparation time and week boundary with no client visits or manual CLI calls; the enabled runner saves the next week automatically; runner restart/retry preserves the same published result |
| Candidate fallbacks | Exercise every pool row above, yesterday preference relaxation, duplicate definition versions, zero weights and event-only exclusions; no hidden rarity rerolls |
| Allowances | Concurrent distinct UUIDs cannot buy beyond the account limit; selling/relaunch/compaction do not restore allowance; another account retains its own allowance |
| Open and closed client | Automatic boundary fetch while visible; foreground refresh; close before reset and reopen after it with current stock |
| Device wall clock/timezone | Move wall clock forward/back and change timezone; monotonic countdown/authoritative availability unchanged; display may change |
| Local activity regression | Singapore local midnight changes activity date without shop reset; UTC midnight changes shop without resetting Singapore steps; test a DST timezone's local-day bounds too |
| Offline and busy recovery | Expired cached offers disabled, connectivity restores current stock, busy refresh retries, pending UUID/body survives refresh |

The review walkthrough lists a persisted Monday–Sunday plan including prices, each day's three distinct Commons, the three Rare dates, two Epic dates, any overlap, and Common-only days. First demonstrate automatic preparation with the app closed and no manual roll command. Then advance only the isolated test clock through midnight boundaries. Close the app between some visits, keep it open through another, and try expired Common and featured offers immediately before/at reset plus a completed replay afterward. Restart the API midweek and expand the pools/change defaults; compare saved IDs/prices, then inspect the next eligible ungenerated week using the expanded release. Separately skip preparation and demonstrate automatic request-time recovery. Record test results and separately identify native/device checks that have actually run.

## 10. Remaining balance/publication choices

The approved baseline is three distinct Commons sampled daily without replacement, three randomly selected Rare dates, and two independently selected Epic dates each week, with overlap allowed. There are no fixed permanent item identities or always-available Rare. The recommended initial catalogue is five Common, three Rare and two Epic; actual identities, final sizes and prices remain undecided. Expanding each rarity pool affects future, ungenerated weeks only. Accept or change the proposed UTC reset, one-copy featured allowance and omission fallback before release. Automatic preparation, activation and missed-job recovery are required; no routine weekly owner command is part of the design. Runtime implementation and any live publication remain separate work.
