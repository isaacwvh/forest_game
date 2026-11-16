# Garden items, inventory and rotating shop — proposal

**Source update, 17 November 2026:** the user authorized implementation of the
consolidated release. Fifteen selected items (6 Common / 5 Rare / 4 Epic), workbook
prices, saved weekly rotations and all eight skills are source-implemented. See
[runtime rules and activation](backend/ITEM_ROTATIONS.md). The ten-item suggestions
and undecided-price passages below are historical. This update does not establish
personal-game activation or native/device acceptance.

Date: 15 November 2026; weekly-shop planning updated 16 November 2026.

Status: Saved for future consideration. Not an implementation instruction or approved release commitment.

This document preserves the user's garden-item concept and the codebase assessment discussed in this chat. It records recommended defaults and open decisions; saving the plan does not implement or activate items, shop rotations, rewards, skills or asset delivery. Recheck source and deployment state before implementation. Source implementation, live activation and native/device acceptance are separate facts.

The current Stage 6 design is recorded in [Saved weekly shop plans and daily rotations](weekly_shop_plan.md). The user approved three distinct Commons sampled daily without replacement, three randomly selected Rare days and two independently selected Epic days per week, with overlap allowed. There are no fixed permanent items or always-available Rare. Recommend ten launch items: five Common, three Rare and two Epic. The three Rare identities are selected in section 3; remaining launch identities and prices remain undecided. Catalogue expansion adds eligible entries to the appropriate rarity pools for future, ungenerated weeks without rerolling saved stock. This supersedes the earlier fixed permanent collection, two-rare-days and everyday Rare / 70–30 / Epic Saturday suggestions. Source stages 1–5 now exist; see [current item implementation](backend/ITEMS.md). The foundation/gap assessment below is historical, from before those increments.

## 1. User's concept

- Introduce garden-placeable items such as benches, lampposts, lights and gnomes.
- Each appearance requires a garden model and a UI thumbnail, following the plant presentation approach.
- Items have rarity tiers and can be acquired through the shop, special events and quests, creating secondary collection targets.
- A select few rare items may provide garden skills while placed; most items remain purely cosmetic.
- Offer approximately four or five standard items for tokens, with rare items appearing occasionally.
- Consider a weekly schedule that selects each day's shop items according to a distribution and resets automatically.
- Rename Exchange to Shop, retaining pack purchases at the top with decorations below in the same scrolling page.
- Extend inventory browsing to plants, items and unopened packs, including placed/stored status.
- Allow Edit storage to switch between plants and items for placement and storage.
- Evaluate bundled assets against CDN delivery as the catalogue grows.

The original navigation idea included renaming both Packs and My plants to Inventory, with Items accessible from both. Section 8 recommends one shared Inventory destination to avoid two identically named screens. This recommendation is not a confirmed replacement for the user's original layout.

## 2. Existing foundations and gaps

The current game provides:

- Versioned pack offers, transactional wallet spending and durable purchase/opening receipts.
- Account-scoped ownership, recovery journals and confirmed-state caching.
- Atomic garden edits, pinned per-copy circular clearances and layout-version checks.
- A frozen-snapshot skill resolver with strongest-per-group stacking and shared caps.
- Scheduled milestone events and permanent earned reward entitlements.
- Bundled, versioned USDZ/PNG packages, asynchronous model imports and bounded template caching.

The missing pieces are substantial enough to treat this as a feature across several systems:

- Owned objects and placements currently assume plants.
- Exchange offers reference pack definitions rather than general products.
- Plant manifests require four growth stages, and rendering expects wind animation.
- Milestone claims grant tokens, gems and packs; permanent item ownership/grants are not implemented.
- No general daily rotating shop or downloadable asset cache is implemented.

Relevant source and planning references:

- [Working specification](forest_game_v1_spec.md), especially placement, skills, transactions and assets.
- [Implementation plan](IMPLEMENTATION_PLAN.md), including the later asset-delivery decision.
- [Plant asset workflow](PLANT_ASSET_WORKFLOW.md).
- [Woodland release and resource measurements](backend/WOODLAND_RELEASE.md).
- [Inventory capacity and selling](backend/INVENTORY_MANAGEMENT.md).
- [Milestone implementation and activation](backend/MILESTONES.md).
- [Milestone plan and reserved cosmetic rewards](milestones_plan.md).
- [Monthly expedition proposal](expeditions_plan.md).
- [Scaling and retention contract](backend/SCALING_S4_S6.md).
- [Ownership and placement models](backend/src/forest_api/models.py).
- [Atomic garden edits](backend/src/forest_api/placement.py).
- [Pack offers and economic receipts](backend/src/forest_api/collection_models.py).
- [Purchase/replay handling](backend/src/forest_api/collection.py).
- [Skill resolver](backend/src/forest_api/skills.py) and [skill components](backend/src/forest_api/skill_rules.py).
- [Milestone claims and event scheduling](backend/src/forest_api/milestone_tracks.py).
- [Collection UI](frontend/MovementForest/Features/CollectionScreen.swift), [plant inventory](frontend/MovementForest/Features/MyPlantsScreen.swift) and [garden editor UI](frontend/MovementForest/Features/Garden/ConnectedGardenScreen.swift).
- [Asset manifests](frontend/MovementForest/Models/AssetManifest.swift), [bundle resolver](frontend/MovementForest/Services/Assets/BundleAssetCatalog.swift) and [renderer](frontend/MovementForest/Rendering/GardenRenderer.swift).

Older specification passages describe remote asset delivery, but current runtime assets are bundled. The implementation plan leaves bundled/remote/hybrid delivery as a separate decision. Do not interpret those older passages as an implemented downloader or an approved migration.

## 3. Recommended initial collection

Use **Decorations** for the shop category and **Items** in inventory. Reuse Common/Rare/Epic/Legendary names and colours, while keeping appearance rarity, acquisition availability and skill strength separate.

| Candidate | Initial role |
| --- | --- |
| Wooden bench | Standard token purchase |
| Lamppost | Standard purchase with restrained visual glow |
| Garden gnome | Standard token purchase |
| Birdbath | Standard token purchase |
| Decorative stone or signpost | Standard token purchase |
| Special lantern or ornament | Additional rare rotating purchase; possible skill |
| Event-themed decoration | Additional quest/event reward when that event is ready |

Updated layout: three distinct Commons sampled daily without replacement from the Common pool, plus one Rare feature on three randomly selected days and one Epic feature on two independently selected days each week. Dates may overlap, giving three, four or five total decoration offers on a day. There are no fixed permanent identities or always-available Rare. Keep the three rarity pools separate, pin one definition/rarity per identity, and forbid same-day duplicate identities across versions. Commons may appear again on later days.

Recommend ten launch items: five Common, three Rare and two Epic. The technical minimum is three Commons, one Rare and one Epic, but then the same Commons appear daily. Five Commons support varied trios; three Rares and two Epics allow distinct featured items within a week. Prefer a different complete Common trio from yesterday when possible, while allowing individual repeats. Prefer not to repeat featured identities within a week; relax repeat preferences when pools are small. Exact appearances and prices remain undecided. Future eligible additions simply expand their rarity pool for future, ungenerated weeks; never reroll or reprice a saved week. See [the Stage 6 plan](weekly_shop_plan.md).

Items do not grow, receive activity water, mature or count as plant species/copies. A rare item need not have a skill. Treat a reward as a grant of an owned copy initially; unlocking permission to purchase additional copies is a separate mechanic requiring explicit configuration.

### Selected Rare items — 16 November 2026

The user selected **Snail Mailbox, Beekeeper's Skep and Foxfire Kiln** as the three Rare items. This supersedes the undecided Rare identities above; Common and Epic identities, prices, publication and live activation remain separate decisions.

| Item | Description | Width x depth x height (m) | Proposed radius | Approved skill while placed |
| --- | --- | --- | --- | --- |
| Snail Mailbox | Sage woodland mailbox with a terracotta spiral-shell roof, two leaf letters and one small parcel. | 0.72 x 0.88 x 1.35 | 0.65 | Patient Post: +5% offline visitor storage capacity. No earning-rate or inventory-capacity increase. |
| Beekeeper's Skep | Seven broad straw coils on a honey-wood stand, with a honey pot, water saucer and a gentle honey-drip loop. | 0.90 x 0.80 x 1.05 | 0.65 | Pollinator's Welcome: +3% garden attraction, applied in the existing garden-attraction layer. |
| Foxfire Kiln | Smooth terracotta kiln with an open firing chamber, short chimney, three acorn cups and softly flickering green foxfire. | 1.08 x 0.88 x 0.92 | 0.75 | None. Cosmetic. |

Both skills have fixed, unconditional magnitudes and activate only while placed. Proposed profile IDs are `patient_post` and `pollinators_welcome`, with stacking groups `item_patient_post` and `item_pollinators_welcome`. Duplicate copies apply strongest once within a group; retain existing destination caps shared with plant/item effects. Skills remain selected for future runtime integration, not active merely because art or planning records exist.

The Rare art follows the existing Abyssrium-inspired miniature-world treatment: smooth matte surfaces, small soft bevels, restrained broad tonal variation and clean silhouettes. The previously closed wax pot becomes an open honey pot to support the requested drip animation. The skep and kiln use four-second skeletal loops; foxfire uses pulsing emissive geometry rather than relying on animated shader intensity or embedded Blender lights. Keep root placement fixed throughout each loop.

The production source and validation record is [Rare item production](art/rare-garden-items-production/SOURCE.md). Asset packages live under `assets/items/<item-id>/v1`; each contains its USDZ, matching transparent 384 x 448 PNG and item manifest. Proposed clearances enclose all fixed accessories at any yaw. Verify native iPhone appearance, playback and performance before release. The item planning workbook records the selected definitions and skills; prices, resale values and runtime definition versions remain unassigned.

## 4. Shop structure and weekly distribution

| Section | Recommended behaviour |
| --- | --- |
| Packs | Existing pack purchases at the top; always available unless explicitly retired |
| Daily Common decorations | Three distinct token offers sampled from the Common pool without replacement each day |
| Featured decorations | Three Rare days and two independently selected Epic days per week, from their respective rarity pools; overlap allowed |
| Event offers | Explicitly scheduled and governed by their own eligibility rules |

Choose three distinct shop dates uniformly without replacement for Rare features, then independently choose two distinct dates uniformly without replacement for Epic features. Each selected date has one guaranteed offer of the corresponding rarity, provided an eligible candidate exists. Generate and save all seven days together, including the three Commons for every day. An overlap day has both features; an unselected day has only its three sampled Commons. There is no fixed Epic weekday or daily 70/30 roll. Legendary shop availability is not assumed.

This produces twenty-one Common slots plus exactly three Rare and two Epic featured appearances per week when pools suffice. Zero to two dates may overlap, so three to five days have featured stock and two to four days have only sampled Commons. Randomness chooses dates and item identities, not whether an allocated feature appears. No overlap count is forced. Start with equal item weights within each rarity; later versioned weights may govern item selection, not the weekly date allocation.

When the pool grows, the generator should:

1. Allocate three Rare and two Epic feature slots using the versioned policy.
2. Sample the two rarity date sets independently without replacement, allowing overlap.
3. Filter candidates by release status, availability window, acquisition channel and required client capabilities.
4. Select items within each slot using configured weights.
5. Sample three Common identities without replacement each day; enforce whole-day uniqueness across definition versions and apply soft Common-trio / same-week featured repeat preferences.
6. Persist the exact selected offers.

Validate candidate pools before publication. Prefer a different whole Common trio from yesterday, allowing shared members; three from five cannot avoid every yesterday item. For features, relax yesterday's repeat preference, then same-week uniqueness if needed. Keep same-day uniqueness, required rarity and eligibility as hard rules. With fewer than three Commons, show each eligible identity at most once and explicitly omit unfillable slots; never fill them with duplicates. Missing Rare/Epic pools similarly omit their scheduled slots without moving dates. Never reroll rarity, substitute another tier or borrow event-exclusive rewards. [The Stage 6 plan](weekly_shop_plan.md) defines the ordered rules and all small-pool cases.

Keep prices stable within each published offer. Item weights govern appearance in the shop, not a random outcome at purchase: players see the exact item they are buying.

## 5. Automatic resets and server implementation

### Recommended timing

- Use one global shop timezone initially, independent of each account's activity/game timezone.
- Proposed reset: **00:00 UTC / 08:00 Singapore time**.
- Use a clearly defined weekly boundary, provisionally Monday at the same reset time.
- All players see the same global daily rotation initially. Personalised shops are outside this first scope.
- The server clock determines availability; device clock/timezone changes cannot reroll stock.
- Shop time is independent of activity time. Step days, caps and HealthKit buckets remain midnight-to-midnight in the account's saved IANA `game_timezone`; a Singapore account's step day resets at 00:00 local time, while the proposed shop resets at 08:00 local time. Device timezone changes do not change that saved account setting. Travel-based timezone migration is separate work.

### Generation and activation

Generate a week of daily offers ahead of time and save their start/end timestamps. At reset, the next saved interval becomes current; no phone needs to be running and no midnight write is necessary for an already-generated rotation.

Use an idempotent scheduled backend job to prepare upcoming weeks, with a request-time fallback that creates a missing plan under a database lock. Enforce uniqueness for the shop/week and daily rotation identities so concurrent requests or multiple API instances cannot generate conflicting results. The existing maintenance worker is for retention, not an existing shop scheduler; any scheduling integration is new work.

Generating only on the first request after a boundary is also valid. It provides the correct current shop when needed, but does not mean work literally executes at midnight. Pre-generation plus fallback is recommended for previewability and resilience.

Persist selected results, not only a random seed. Record the generation policy/version, candidate catalogue version and optional seed for audit/reproduction. Catalogue edits or generator changes must not reroll a published day. Generation must be chronological where recent-repeat rules depend on prior selections.

### Proposed records

- **Shop policy:** versioned distribution, weights, repeat rules, timing and fallbacks.
- **Rotation:** identity, shop date, start/end, policy/catalogue version and publication state.
- **Offer:** exact item definition/version, currency, price, purchase allowance and rotation identity.
- **Purchase allowance usage:** account/offer counts, updated transactionally.

Start with per-account allowances rather than globally limited stock. Global sellouts add contention and competition and are unnecessary for this first release. Standard duplicate limits and featured purchase allowances remain product decisions.

The Stage 6 recommendation is one copy per featured Rare/Epic offer per account/rotation. Daily Common offers retain capacity/funds/request-quantity limits and no purchase quota, but expire with their daily interval too. Selling does not restore featured allowance. Effective historical policy/catalogue releases must be retained so missed preparation uses the intended inputs, even after defaults change. Pool additions become eligible only for future, ungenerated weeks; all saved selections and prices remain unchanged.

After the initial implementation, deployment and catalogue/policy configuration, weekly preparation, date/item selection, saved publication and interval activation must run automatically. Deploy and enable a preparation runner with restart/retry handling; no owner-issued weekly command, manual seed, code injection or per-week approval is required. A missed job is recovered automatically by request-time fallback. Preview/preparation commands remain optional inspection/troubleshooting tools, not routine weekly work. The catalogue can be decided later; content authoring is separate from rolling each week's schedule.

### Client refresh

The shop response should include `serverNow`, the active rotation identity and `endsAt`/next reset. Refresh when entering Shop, returning to the foreground and crossing the boundary while open. Use server time for the countdown and revalidate before purchase. Cached stock may remain visible with a stale/offline indication, but purchases require server confirmation.

Anchor countdowns to server time plus monotonic elapsed time, independently of device wall time and activity uploads. At expiry, disable fresh purchases and refresh, including open confirmation sheets. **“App closed between visits” is a recovery test, not a restart requirement:** stock changes automatically while Shop is open, and launch/foreground fetches the current interval after an absence. See [Stage 6 acceptance](weekly_shop_plan.md#9-completion-gate-and-reviewable-demonstration).

Do not depend on iOS waking the app at an exact hour. Apple controls background execution timing, and background launches can be delayed by hours. [Apple background-task documentation](https://developer.apple.com/documentation/backgroundtasks/starting-and-terminating-tasks-during-development)

## 6. Purchase transactions and economy

Reuse the established account locking, request hashing, wallet accounting and durable recovery patterns. Introduce item offers/products without forcing them into pack-definition foreign keys. New purchases must participate in wallet reconciliation and the existing recovery/retention classification.

A purchase transaction should:

1. Authenticate and check for an already-completed request before current availability/capacity checks.
2. Lock the necessary account state in the established order.
3. Validate the exact offer/version, server-time interval, eligibility and account allowance.
4. Validate the entire requested quantity against item capacity and funds.
5. Deduct currency, grant owned copies, update allowance usage and save the receipt atomically.

Never trust a client-supplied price. A completed purchase replays its receipt after the offer expires. An uncompleted request arriving after expiry refreshes stock without charging. Retries, relaunch and concurrent devices cannot duplicate spending or grants.

Use tokens initially for standard/featured items. Gem-priced items, discounts and resale are separate choices. Do not automatically apply the plant resale formula to decorations or introduce a buy/sell profit loop.

Choose prices after comparing item acquisition with existing visitor income, milestone rewards and the **1,200-token Standard Woodland pack**. Decorations compete with plant collection for tokens, so evaluate the combined pace rather than pricing each system in isolation. That pack price is the inspected baseline, not a guarantee about future live configuration.

## 7. Ownership, placement and capacity

Recommended separation:

| Record | Responsibility |
| --- | --- |
| Item definition | Stable identity, name, rarity, appearance reference, physical footprint, acquisition rules and optional skill profile |
| Owned item copy | Unique copy ID, owner, pinned definition/profile/asset references and acquisition source |
| Item placement | Garden, copy ID, ground position and rotation |
| Acquisition receipt | Permanent purchase/reward proof and repeat-safe source identity |

Owned copies share appearance files. Two benches need two ownership/placement records, not two copies of the asset package.

Keep plant and item capacities separate. A bench should not consume plant capacity or block opening a plant pack. Set item storage limits, per-item duplicate allowances and a separate conservative placement/performance allowance before release; exact counts require mixed-garden device testing. Preserve earned reward entitlements if capacity prevents a grant.

Reuse circular clearances initially, in the existing coordinate precision and garden units. A decoration's radius must accommodate its solid footprint at every allowed yaw. Benches may reserve generous circles; capsules or rotated rectangles could improve packing later but expand the geometry scope.

Validate the complete mixed layout: plant–plant, plant–item and item–item collisions and garden boundaries. Client previews and server validation must agree. Both object kinds should use one atomic edit transaction and shared layout version, even if their storage tables remain separate. Mixed swaps must not require an invalid intermediate placement.

Use an explicit object kind/identity in edit contracts and selection rather than treating items as plants. Keep ownership checks, stale-version errors, pending-edit recovery, rotation, storage and accessible selection for both kinds.

## 8. Inventory and editor navigation

Recommended navigation:

- **Shop:** pack purchases first, then standard, featured and event decorations in one scrolling page.
- **Inventory → Plants:** current all-owned plants view, retaining planted/stored sections and plant filters.
- **Inventory → Items:** all owned items, grouped or filtered by In garden/Stored, with quantity, rarity and skill indicators.
- **Inventory → Packs:** unopened packs and the existing opening/recovery flow.
- **Edit → Storage:** Plants/Items switch showing stored copies for placement.

Rename the current My plants destination to Inventory. The former Packs menu entry can become a shortcut to Inventory with Packs selected, or be removed when the new destination is discoverable. If two entry points remain, they should share the same underlying inventory state rather than creating duplicate collections.

Shop and owned-item artwork should normally be visible before/after acquisition respectively. Showing an item for sale requires showing what the player will receive; do not automatically inherit the plant catalogue's hidden-until-discovered art rule. Hidden event-reward previews, if desired, need a separate explicit policy.

Item inspection should show appearance, rarity, ownership/placement status, acquisition details and any skill without plant growth controls. Preserve account isolation, pagination, confirmed counts, accessibility and clear pending/offline states.

## 9. Asset production and delivery

### Item package

Reuse the plant workflow's visual language, garden scale, ground origin, camera/framing and export validation. A normal item appearance needs:

- One game-ready USDZ model, with embedded textures where applicable.
- One transparent PNG thumbnail, matching the existing 384×448 presentation where suitable.
- A versioned manifest containing model bounds, format/units, asset paths, sizes/checksums and optional animation/effect metadata.
- Separate gameplay configuration for rarity, reserved footprint and skills.

Example future paths: `assets/items/wooden-bench/v1/models/wooden-bench-standard.usdz`, `ui/wooden-bench-standard.png` and an item manifest alongside them. Exact schema/path conventions should be settled before authoring. Keep Blender sources, concept art and review renders outside runtime packages.

Do not require four growth stages or wind animation for static objects. A lamp can begin with an emissive material and restrained shared glow. Numerous real shadow-casting lights require separate performance evaluation and are not implied by producing a lamppost model.

### Inspected storage baseline

Read-only measurements on 15 November 2026 of packages referenced by the bundled manifest index:

| Resource | Count | Approximate decimal size |
| --- | ---: | ---: |
| USDZ models | 188 | 227.04 MB |
| PNG thumbnails | 188 | 22.65 MB |
| Species manifests | 30 | 0.22 MB |

The Woodland release guide records approximately **274.52 MB** for selected plant and other runtime artwork. These figures are source-resource measurements; they are not measured App Store download sizes, installed app sizes or memory budgets.

One ordinary decoration uses one model/thumbnail rather than four stages per plant variant. Illustratively, five items averaging 1 MB/model and 0.15 MB/thumbnail add about **5.75 MB**. This is an example budget, not a measurement of unproduced assets.

### Recommendation: bundle first, support hybrid delivery later

| Delivery | Benefit | Cost |
| --- | --- | --- |
| Bundled | Reliable offline presentation and simpler release/testing | Every installation includes the shipped catalogue, including unowned items |
| Downloaded | New artwork without an app update; selective local storage | Downloader, cache, failure handling and publication infrastructure |
| Hybrid | Bundled base items with expandable event content | Remote infrastructure is still needed when downloadable content starts |

Bundle the first collection. Give assets stable versioned references so delivery can change without rewriting ownership or gameplay. Bundled assets are shared per appearance, not per player copy, and are loaded as needed rather than all models being imported at launch.

The strongest reason to introduce CDN delivery is fresh event content without requiring an app update, rather than the likely storage cost of five decorations. Bundling several upcoming rewards in advance is also viable. If release-independent event artwork is required from launch, bring the remote-delivery work forward.

### Future remote resolver

CDN delivery means downloading and caching files locally, then importing them into RealityKit; it does not remotely render the garden.

- Resolve the exact bundled version first where available, otherwise a validated downloaded version.
- Download from trusted HTTPS asset origins using a separate asset-loading/cache path rather than routing binary files through the game API.
- Validate manifest compatibility, safe paths, sizes and hashes before atomic installation of files.
- Load shop thumbnails on demand; fetch models for placement, previews and gardens being viewed.
- Do not download every model simply because metadata appears in the catalogue.
- Do not restrict downloads to owned items: previews and eventual friend gardens can require unowned appearances.
- Bound disk storage and concurrent downloads/imports; prioritise retaining the current garden within the cache policy.
- Handle interruptions, missing/corrupt files, retries, eviction and offline views without changing ownership or skill state.

Supabase Storage/CDN fits the existing architecture direction. Public catalogue art can use shared public URLs; the backend remains authoritative for ownership and placement. Public artwork does not need per-account signed download URLs. Publishing credentials must remain outside the client. [Supabase asset delivery](https://supabase.com/docs/guides/storage/serving/downloads)

Use immutable published asset versions and retain versions referenced by owned items. Upload and verify files before publishing definitions, rewards or offers. Require supported client/content capabilities: a downloaded model cannot add an unknown gameplay mechanic to an old client. Bundle updates and CDN assets are both presentation delivery, not acquisition entitlements or spoiler protection.

## 10. Item skills

Extend skill resolution to distinguish emitters from plant recipients. Do not model a bench as an adult plant simply to satisfy the current resolver.

Recommended rules:

- A skill item activates only while placed and stops emitting when stored.
- Duplicate copies use strongest-per-group behaviour; different items sharing a group also obey that group.
- Plant and item effects share the applicable existing caps rather than multiplying separate uncapped bonus systems.
- Items do not enter plant species/count conditions, growth awards, maturity milestones or plant-discovery accounting.
- Skills use pinned, versioned definitions and retain source provenance in accounting/receipts.
- Placing/storing an item settles elapsed visitor earnings under the previous context before establishing future effects.
- Growth follows the current credit-time frozen-snapshot semantics and never recalculates already-awarded growth.
- Local placement previews, asset availability and UI animations never activate authoritative skills.

Begin with one modest effect using an existing supported destination, such as water or offline storage capacity. Actual magnitudes need balance review. New offline-rate mechanics, one-use effects or independent currencies are outside the first skill scope.

An exclusive event appearance can be a strong reward. Avoid making an exclusive event item the sole route to a material gameplay advantage; an equivalent obtainable effect is preferable if the bonus becomes important to progression.

## 11. Quest, milestone and expedition grants

Use one reusable item-acquisition service for purchases, milestone claims, event rewards and eventual expedition completion. Grant stable owned-copy identities with unique source references, including a copy ordinal for multi-copy rewards. Claims must be transactional and repeat-safe across alternate request IDs and concurrent devices.

Item ownership and earned reward entitlements survive event rollover. Capacity or asset-download failure must not delete an earned entitlement. Distinguish server grant success from local artwork readiness; re-downloading must never re-grant an item.

The current milestone implementation intentionally leaves reserved cosmetic components empty. Adding an item to a previously earned/claimed milestone requires an explicit prior-earner policy and, where appropriate, a separate supplemental item entitlement. Do not reopen or repeat the original token/gem/pack claim.

The expedition proposal initially suggested simpler fixed cosmetics because arbitrary placement did not exist. A completed general item system could supply its final reward category, but configurable expeditions, quest evaluators and map restoration remain separate work. Do not treat this item plan as implementation of the full expedition proposal or as approval of changed event deadlines.

## 12. Suggested implementation sequence

1. **Item foundation and launch content:** settle the definition/manifest contracts; target ten bundled items (five Common, three Rare, two Epic); implement ownership, transactional token purchases, mixed placement, rotation/storage and Inventory/Edit presentation. Stages 1–5 already supply the bench foundation; see current source status above. Actual catalogue identities/prices remain undecided.
2. **Rotating shop:** add versioned weekly policy (three distinct sampled Commons daily, three Rare dates, two independent Epic dates, overlap allowed), saved daily offers, an enabled automatic preparation runner/fallback, per-account limits, countdown/refresh and expiry-aware recovery. Each rarity uses its own pinned pool; additions affect future, ungenerated weeks only. Replace the legacy permanent item-offer path without changing completed receipts or owned-copy valuations. Use placeholder content until the actual catalogue is ready; do not require a manual weekly roll.
3. **Skills and reward integration:** add one modest skill item and one item reward through the shared acquisition service; cover visitor boundaries, growth snapshots and permanent entitlement recovery.
4. **Remote event assets:** implement hybrid resolution/download/cache/publication when fresh content without app releases becomes a requirement. Bring this phase forward if that requirement applies to the first launch.

Each increment needs explicit migration/publication and native acceptance where applicable. Do not activate personal-game changes merely because source or isolated tests pass. A content validator and preview/publication commands are sufficient initially; a full authoring CMS is not required.

## 13. Validation and acceptance

- Stable weekly results across retries, catalogue edits, restarts and multiple API instances.
- Three distinct Common identities sampled without replacement each day, plus exactly three Rare and two Epic dates weekly when pools suffice; test zero/one/two overlap cases and allowed later-day Common repeats.
- Expanding Common/Rare/Epic pools affects the next eligible ungenerated week, never any saved selections or prices; no extra legacy permanent offer remains active.
- Unattended preparation with no app visits or manual commands; automatic runner recovery/retry and request-time recovery after a missed job.
- Exact reset boundaries, global timezone handling, foreground refresh and device-clock changes.
- Empty candidate pools, repeat constraints, missed generation jobs and defined fallbacks.
- Expired offers, insufficient funds, full item capacity, purchase limits, concurrent devices and atomic rollback.
- Completed-request replay after expiry and after response compaction; no duplicated grants/spending.
- Mixed plant/item collisions, board boundaries, arbitrary yaw, atomic swaps, ownership checks and stale edit recovery.
- Correct instance quantities and placed/stored state across all inventory entry points and account switches.
- Static and animated item loading, ground anchors, selection and consistent thumbnails.
- Item/plant skill stacking, duplicate sources, caps, store/replant, visitor settlement and unchanged past awards.
- Reward uniqueness, prior-earner handling, full-capacity retry and ownership after event rollover.
- Missing/corrupt assets, offline states, interrupted downloads and cache eviction if remote delivery is included.
- Physical iPhone checks for mixed-garden memory, frame rate, startup/import latency, lamps/effects, accessibility and Reduce Motion.
- Combined token-spending pace alongside pack purchases and permanent/event rewards.

## 14. Decisions to settle before implementation

1. Remaining Common/Epic launch appearances and size/footprint targets; the three Rare identities and proposed dimensions are selected in section 3. Recommended ten-item split is five Common, three Rare and two Epic.
2. Final pool sizes and eligibility: at least three Commons, one Rare and one Epic fill the schedule with repeats across days. Full catalogue remains undecided; future additions expand the appropriate pool for ungenerated weeks only.
3. Confirm proposed global reset, soft Common-trio / featured-repeat preferences and slot-omission fallback from the Stage 6 plan. Three Common slots daily without replacement and the featured rarity distribution are specified above.
4. Token prices, purchase allowances, duplicate-copy limits and any future resale policy.
5. Item inventory and placed-item limits, independent of plant capacity.
6. One shared Inventory destination versus retaining two linked entry points.
7. Runtime integration/release order for the approved +5% offline-capacity Mailbox and +3% garden-attraction Skep skills, and a nonexclusive route to equivalent power if needed.
8. First reward source and treatment of prior milestone earners.
9. Whether fresh event artwork must ship without an app update from the first release.
10. Asset compatibility, publication and recovery contracts before live activation.

Recommended starting scope: **ten items (five Common, three Rare, two Epic), three distinct Commons sampled daily without replacement, three random Rare days and two independent random Epic days per week with overlap allowed, expandable versioned rarity pools, one shared Inventory, mixed plant/item editing, automatic server-controlled saved weekly/daily rotations, and one modest skill item after the basic loop works.** No item is permanently in stock. Catalogue identities and prices remain open. These are planning recommendations, not activated game rules. [The Stage 6 plan](weekly_shop_plan.md) supplies the implementation sequence and completion gate.
