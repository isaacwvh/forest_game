# Milestones redesign and reward plan

**Date:** 9 November 2026
**Planning revision:** 13 November 2026 — catalogue-scaled discovery, deferred cosmetic slots, and separate running/workout quests.
**Status:** Source implementation completed on 13 November 2026; live activation and native Mac/iPhone acceptance remain separate.
**Content prerequisite:** The repository now contains the 30-species Woodland catalogue and version-20 Standard, Enchanted (`select-woodland`) and Premium pack contracts. Verify the target deployment has published them before activating milestones.

## 1. Purpose and authority

Replace the current short introductory Milestones page with five long-term tracks: **Steps, Butterfly, Growth, Special, and Event**. Support a generous opening, meaningful intermediate rewards, and achievements that continue through months of play.

This document records the latest agreed presentation direction and the latest proposed reward schedules. It does not implement, activate, or publish rewards. Exact pack economics, existing-account compensation, and the explicitly listed open decisions must be resolved before activation.

Use this document instead of the earlier, more conservative reward schedule in `output/concepts/milestones-rebrand-v1/PLAN.md`. The older plan's 15–60-token rewards and its timelines for every category are superseded. Earlier provisional introductory and lifetime-step rewards in `IMPLEMENTATION_PLAN.md` must not be layered on top of this schedule.

### Accepted visual references

- [Steps and Butterfly concept](C:/Users/Isaac/forest_game/output/concepts/milestones-rebrand-v2/steps-butterfly.png)
- [Growth, Special and Event concept](C:/Users/Isaac/forest_game/output/concepts/milestones-rebrand-v2/growth-special-event.png)
- [Exact concept-generation prompts](C:/Users/Isaac/forest_game/output/concepts/milestones-rebrand-v2/prompts.json)

These are concept renders, not screenshots of implemented software. Match their structure, visual identity, icon arrangement and restrained copy; derive actual native sizing, accessibility and data behavior from the requirements below. The tables in this document govern rewards beyond the examples visible in the renders.

## 2. Goals and boundaries

### Goals

1. Give new players a useful garden quickly without removing the reason to welcome butterflies, gather tokens and buy packs.
2. Make meaningful milestones feel worth completing relative to the standard pack price.
3. Continue tracks well beyond the first few achievements, with widening threshold gaps and larger rewards.
4. Offer several independent ways to progress, including activity, garden growth, collection, visitors and occasional events.
5. Keep requirements, progress, rewards and claim status immediately readable.
6. Preserve server authority, one-time claims, recovery behavior and account isolation.

### Boundaries

- Implement after the catalogue and both new pack types are ready.
- Do not change the accepted garden, placement, pack-opening or butterfly interaction flows as part of the visual redesign.
- Do not silently change recurring visitor rates, standard pack prices, growth rates or existing owned pack definitions to make this schedule fit.
- New rewards grant unopened packs; they do not automatically open packs, create mature plants, place plants, or unlock permanent purchase access.
- All tracks progress simultaneously. Selecting a track changes the displayed content, not which rewards the account can earn.
- Do not add a hard cap preventing players from buying an earned fifth pack.
- No automatic or repeatable reward is implied after the last explicitly configured milestone. Extend the definition set later using stable identities and a deliberate reward budget.

## 3. Prerequisites and economic assumptions

### Catalogue and pack readiness

Before implementation begins:

- Finish importing the intended species, variants, growth profiles, attraction profiles, thumbnails and models.
- Publish the actual pack pools and immutable pack versions; local artwork alone does not make a species available in a pack.
- Create Select Woodland and Premium Woodland pack contracts, contents, odds, artwork associations and opening support.
- Confirm each pack's token/gem price, rarity guarantees, selection behavior, eligible species and treatment of duplicates.
- Ensure every discovery threshold offered to players is achievable within the published catalogue.
- Confirm the economy/catalogue version that will receive the new milestones.

The currently inspected milestone service is gated to named launch catalogue versions. The new service must use explicit supported milestone/reward policy publication rather than accidentally disappearing when the expanded catalogue receives another version identifier.

### Baseline used for this proposal

At the inspected published policy:

| Item | Baseline |
| --- | --- |
| Standard Woodland pack | 1,200 tokens |
| Ordinary welcomed/collected butterfly | 1 token |
| Step-earned gems | 1 per 10,000 accepted lifetime steps |
| Existing starter | One starter plant; count as one opening pack-equivalent |
| Current level gifts | Capacity benefits; no pack gifts found in the inspected policy |

These are repository-policy observations, not a fresh query of the live database. Recheck them after the catalogue and pack work. If standard prices change substantially, reconsider the token tables as a whole rather than copying the numbers unchanged.

### Select and Premium packs

The reward tables preserve the latest proposal's Select Woodland rewards. A name or illustration does not establish a value: a curated random pack and an unrestricted species-choice pack have very different economics.

Premium Woodland is a prerequisite for the intended future pack system, but **no milestone currently promises Premium packs**. Decide its value before assigning it. A possible later use is to replace an existing Select reward at a major multi-million-step or late Growth landmark. Treat any such replacement as a new balancing decision, not an additional unbudgeted pack.

Do not silently substitute Standard for Select/Premium when the configured pack is unavailable. Disable unpublished definitions or show the retained entitlement as temporarily unavailable, with a recovery path.

## 4. Page layout and copy

### Shared top section

Keep the navigation title **Milestones** and normal Garden back navigation. Immediately below it, show exactly five icon-and-label selectors:

| Track | Icon | Presentation |
| --- | --- | --- |
| Steps | Hiking boot | Vertical timeline |
| Butterfly | Lavender butterfly | Vertical timeline |
| Growth | Potted sprout | Independent quest cards |
| Special | Golden star medal | Independent quest cards |
| Event | Leaf calendar | Independent quest cards |

Preserve the accepted tactile artwork style and icon layout. Use a sage selection background and green underline. A small ready indicator may identify a different track with an available reward. Do not substitute a sixth track or turn the selectors into global app navigation.

Default to Steps on the first visit; subsequently restore the last selected track and its scroll position. Make long timelines scroll naturally, with a way to return to the next unclaimed goal. Do not render an unbounded history of thousands of rows at once.

### Copy discipline

Remove motivational headings, ornamental leaf headings, redundant subtitles and footer explanations. In particular, do not reintroduce:

- “Every step, a little further” or “A garden worth visiting”.
- “Watch your forest flourish” or “Grow · Discover · Collect”.
- “A little beyond the everyday”, “One-time challenges” or “Complete in any order”.
- “Your first visitor has arrived”, “All event progress is counted together”, or decorative bottom notes.

Keep useful information only: the requirement, exact reward, progress, claim state, useful filters, and the event's actual name/time remaining. Put genuinely necessary explanations in the existing information affordance or an appropriate detail view, not below every list.

### Steps and Butterfly timelines

- Use the accepted narrow vertical rail and circular nodes.
- Claimed nodes use checks; the next incomplete node uses an outlined current marker; future nodes remain visible and quiet.
- Preserve the row arrangement: reward artwork on the left, requirement/reward text in the middle, progress or claim state on the right.
- Show one compact total above the list, such as “3,240 lifetime steps” or “1 butterfly welcomed”. Avoid repeating it in several introductory blocks.
- Current progress can use a fine progress bar, but its denominator and scope must be clear. The exact numeric requirement remains visible.
- A timeline is an ordered display, not a prerequisite chain. A later earned reward is claimable even when an earlier earned reward has not been claimed.

### Growth, Special and Event quest cards

- Use separate full-width cards with consistent gaps.
- Do not use connecting rails, dotted paths, exterior circles, numbered stages or other graphics that imply a sequence.
- Put progress bars inside the relevant card only. Do not show one global progress total across unrelated objectives.
- Preserve the existing reward-icon/text placement. Use a compact green Claim action and an in-card Claimed state.
- Cards may independently be claimed, ready or incomplete. Do not lock one behind another unless an explicit future quest actually requires it.
- Retain Growth's useful **All / Maturity / Discovery** filters, with All as the initial view.
- Event may retain a compact real event name and remaining-time label. Remove “Day 2 of 7” and day/checkpoint prefixes from the accepted design.
- Use stable configured ordering; do not reshuffle cards unexpectedly while a user is interacting with them.

## 5. Opening allocation

The user specified **four total routine opening equivalents, including the starter and any level gifts**.

| Source | Requirement | Reward | Running guaranteed equivalents |
| --- | --- | --- | ---: |
| Existing starter | Account creation | Existing starter plant | 1 |
| Steps: New Beginnings | Available immediately on a new account's first Milestones visit | 1 Woodland pack | 2 |
| Butterfly | First confirmed welcomed/collected butterfly | 1 Woodland pack | 3 |
| Steps | 1,000 accepted lifetime steps | 1 Woodland pack | 4 |

New Beginnings is immediately claimable and does not require activity or another purchase. Do not grant a second starter plant. Any future routine early level pack must replace one of the three grant slots above.

This is the guaranteed opening allocation, **not a promise of at most four acquisitions in the first 24 hours**. More generous token milestones intentionally let engaged players purchase another pack. Exceptional one-time challenges may also grant another pack.

An optional workout-first alternative was discussed: 10 eligible workout minutes could satisfy the same opening First movement entitlement as 1,000 steps. This remains an open decision. If adopted, disclose the alternative clearly and use one shared reward identity; do not grant both a Steps pack and a separate workout pack for the same opening slot. This game requirement is not a claim of physiological equivalence.

## 6. Steps reward schedule

All thresholds are cumulative accepted lifetime steps. Count account progress once, independent of how many plants are placed, which species are growing, growth multipliers, or whether plants have reached adulthood.

| Milestone | Tokens | Unopened packs | Bonus gems | Other |
| --- | ---: | --- | ---: | --- |
| New Beginnings | — | 1 Woodland | — | Immediately claimable |
| 1,000 steps | — | 1 Woodland | — | Opening allocation |
| 5,000 | 300 | — | — | |
| 10,000 | 300 | — | — | |
| 25,000 | 600 | — | — | |
| 50,000 | 900 | — | — | |
| 100,000 | — | 1 Select Woodland | — | |
| 200,000 | 1,200 | — | 2 | |
| 300,000 | 1,200 | — | 2 | |
| 400,000 | 1,200 | — | 2 | |
| 500,000 | — | 1 Select Woodland | 5 | |
| 750,000 | 2,400 | — | 5 | |
| 1,000,000 | — | 1 Select Woodland | 10 | |
| 1,500,000 | 3,600 | — | 10 | |
| 2,000,000 | — | 1 Select Woodland | 15 | |
| 3,000,000 | 4,800 | — | 20 | |
| 5,000,000 | — | 2 Select Woodland | 30 | |

The 5k–50k nodes grant 2,100 tokens in total: 1.75 standard packs at the assumed price. Larger gaps later reflect the stronger garden and longer-term play. Extend beyond 5 million in a future policy; do not add an automatic repeatable pack-per-fixed-step formula by default.

### Deferred cosmetic slots

Leave the cosmetic component empty in the initial reward definitions and player-facing UI. Keep the pack, token and gem rewards at these tiers unchanged. The following exact milestones are reserved for a future cosmetics update:

| Track | Milestone | Previously suggested cosmetic |
| --- | --- | --- |
| Steps | 1,000,000 accepted lifetime steps | Badge |
| Steps | 5,000,000 accepted lifetime steps | Title |
| Butterfly | 100,000 lifetime butterflies | Badge |
| Growth / Maturity | 500 distinct plant copies matured | Title |

Do not show placeholder rewards, empty cosmetic icons or promises of future cosmetics. Preserve stable milestone identities and earned/claimed facts so a later cosmetics update can attach rewards to these tiers. That update must explicitly decide cosmetic eligibility for accounts that already earned or claimed them; do not reopen the original currency/pack claim or assume a retroactive cosmetic grant now.

## 7. Butterfly reward schedule

Count lifetime **confirmed active welcomes plus actually collected offline visits**. Merely generated, visible, missed, expired, or uncollected stored visitors do not count. Token awards from milestones, sales or conversion do not count as hosted butterflies.

| Lifetime butterflies | Tokens | Unopened packs | Bonus gems | Other |
| ---: | ---: | --- | ---: | --- |
| 1 | — | 1 Woodland | — | Opening allocation |
| 3 | 75 | — | — | |
| 10 | 75 | — | — | |
| 25 | 150 | — | — | |
| 100 | 300 | — | — | |
| 250 | 450 | — | — | |
| 500 | 600 | — | — | |
| 1,000 | 600 | — | — | |
| 2,000 | 900 | — | — | |
| 5,000 | 1,200 | — | — | |
| 10,000 | 1,800 | — | 3 | |
| 25,000 | 3,000 | — | 5 | |
| 50,000 | 4,800 | — | 10 | |
| 100,000 | 7,200 | — | 15 | |

The one- and three-visitor nodes should not both award packs: the tutorial and early arrivals are too close together. Small early token bonuses teach the system; later landmarks carry useful rewards.

Through 10,000 visitors, token milestones total **6,150**, in addition to the 10,000 ordinary visitor tokens and initial pack. Through 100,000 visitors, token milestones total **21,150**, a 21.15% supplement to normal visitor tokens. These verified totals supersede any earlier conversational arithmetic.

The track must be extensible beyond 100,000. Candidate later thresholds are 250k, 500k and 1 million, with token/gem bundles to be budgeted after observing the expanded garden economy. Those later rewards are not yet specified; do not publish fabricated values or promises.

## 8. Growth reward schedules

Growth contains independent Maturity and Discovery quests. The filters change visibility only; both groups accumulate progress together.

### Maturity

| Requirement | Tokens | Unopened packs | Bonus gems | Other |
| --- | ---: | --- | ---: | --- |
| First seedling earned through accepted activity | 150 | — | — | |
| First mature plant earned through accepted activity | — | 1 Woodland | — | |
| 5 distinct plant copies matured | 600 | — | — | |
| 10 distinct copies matured | — | 1 Woodland | — | |
| 25 distinct copies matured | 1,800 | — | 3 | |
| 50 distinct copies matured | — | 1 Select Woodland | 5 | |
| 100 distinct copies matured | 3,600 | — | 10 | |
| 250 distinct copies matured | — | 2 Select Woodland | 20 | |
| 500 distinct copies matured | 6,000 | — | 30 | |

Each owned copy contributes at most one first-maturity credit. Duplicate species copies can count as different matured copies. Storing, moving, selling, replanting, syncing again, or switching devices never repeats the credit. Selling a previously matured copy does not reduce lifetime progress. Developer/test maturity grants must not masquerade as earned growth.

The existing base launch profile needs about 100,000 steps to mature a plant before other activity and boosts. Recalculate against the imported catalogue. Plants grow in parallel, so several maturities may arrive together; do not forecast the five-copy quest as five sequential maturation periods.

### Discovery

Count permanent unique **species** discoveries within their published rarity. Variants and repeat copies are not additional species. Discoveries remain earned after sale or removal from the current garden.

#### Proposed schedule scaled to the current catalogue

The repository's `backend/src/forest_api/data/woodland-v1.json` contains **30 species: 10 Common, 10 Rare, 7 Epic and 3 Legendary**. Use those published species counts as the initial collection journey. Retain the attainable Common/Rare tiers, move the unreachable 10-Epic completion reward to 7 Epic, and add a short Legendary journey at 1 / 2 / 3 species. This is a planning proposal; no definitions or rewards are activated by this revision.

| Rarity | Unique species | Tokens | Bonus gems |
| --- | ---: | ---: | ---: |
| Common | 3 | 300 | — |
| Common | 5 | 600 | — |
| Common | 10 | 1,200 | — |
| Rare | 1 | 300 | — |
| Rare | 3 | 600 | — |
| Rare | 5 | 1,200 | — |
| Rare | 10 | 2,400 | — |
| Epic | 1 | 600 | — |
| Epic | 3 | 1,200 | — |
| Epic | 5 | 2,400 | — |
| Epic | 7 (current rarity completion) | 3,600 | 5 |
| Legendary | 1 | 1,200 | — |
| Legendary | 2 | 2,400 | — |
| Legendary | 3 (current rarity completion) | 4,800 | 5 |

Do not show unreachable thresholds for a rarity with insufficient published species. Define discovery against durable catalogue records rather than scanning only current inventory. Historical rarity changes require an explicit migration policy; immutable discovery/category semantics must not randomly change progress after a publication.

The four rarity endpoints are 10 Common, 10 Rare, 7 Epic and 3 Legendary; together they cover all 30 species. No additional all-catalogue completion reward is proposed in this revision, avoiding another reward stacked onto all four endpoints. Legendary discoveries are earned collection goals, not guaranteed pack outcomes. The new Legendary ladder adds 8,400 one-time tokens and 5 bonus gems; include this addition in the combined economy simulation before activation.

Keep these as fixed, versioned species thresholds, rather than percentages that move whenever content is added. If the catalogue expands, preserve earned/claimed tiers and append deliberately budgeted thresholds. In particular, a later 10-Epic quest would be a new tier; it must not replace or reset the 7-Epic reward. Before activation, verify the actual published catalogue matches these counts and each species is obtainable through the published packs or another supported acquisition path.

## 9. Special quests

All quests are independent, optional and one-time. Use concise literal requirements instead of motivational titles.

| Requirement | Reward |
| --- | --- |
| First accepted day with at least 10,000 steps | 300 tokens |
| First accepted day with at least 20,000 steps | 600 additional tokens |
| First eligible running workout of at least 5 km | 1 Woodland pack |
| First supported workout with at least 60 active minutes | 1 Woodland pack |
| First eligible running workout of at least 10 km | 1 Select Woodland pack |
| Activity on 7 distinct days within a rolling 14-day period | 600 tokens |
| Activity on 30 distinct days over the account's lifetime | 1 Woodland pack + 5 gems |
| Activity on 100 distinct days over the account's lifetime | 1 Select Woodland pack + 10 gems |

### Requirement semantics

- Use inclusive thresholds: at least 5 km / 60 minutes, not strictly greater than the displayed requirement.
- An activity day is provisionally **at least 1,000 accepted steps OR 10 eligible workout minutes**, counted once per game date. Confirm this definition before release.
- The 7-of-14 quest is a rolling window, not a consecutive streak. A day without activity never resets already-earned lifetime days.
- The 20k-day reward is additional: crossing both daily thresholds can award 900 tokens total. Show its reward clearly; do not present 600 as the entire ladder total.
- Use the game's authoritative date/time-zone and enrollment rules. Do not give new rewards for arbitrary pre-enrollment health history or change eligibility by switching time zones.
- Duration uses accepted active workout time, excluding pauses. A 5 km or 10 km run means one qualifying running workout, not several workouts added together.
- Keep valid workout identity/provenance and deduplicate it. The existing pipeline records workout distance diagnostically; milestone qualification using that distance needs explicit implementation and validation.

### Overlap rules

The 5 km run and 60-active-minute workout are **two separate one-time quests**, each with its own stable entitlement identity and one Woodland pack reward (for example, `special_run_5km` and `special_workout_60min`). Neither is a prerequisite for the other. One accepted run lasting at least 60 active minutes may satisfy both, issuing one pack per quest; retries or repeated qualifying workouts cannot repeat either reward. Do not require different workouts or exclude running from the duration quest.

The existing proposed 10 km replacement rule remains an open decision, now scoped **only to the 5 km running quest**: for the first qualifying run that satisfies both running thresholds, pay the Select reward and mark the lower 5 km entitlement fulfilled/superseded without issuing its Standard pack. The UI must show that status before allowing a lower claim. Derive both eligibility and supersession from the same accepted final workout facts so claim order cannot change the result. A separately earned 60-minute workout reward remains claimable in full, including when the 10 km run also meets that duration threshold.

If the 5 km Standard reward was earned from an earlier qualifying run, a later 10 km run can earn the Select reward in full. Confirm this proposed running-tier supersession rule before implementation because it changes which overlapping running rewards can be collected. Splitting the duration quest does not settle this separate decision.

The split adds up to one Standard pack relative to the previous shared 5 km / 60-minute entitlement. Include both quests in acquisition forecasts; these are exceptional one-time rewards outside the four routine opening equivalents.

Lifetime Steps, daily steps, growth and other independent tracks can still advance from the same valid activity. Do not suppress that intentional overlap.

## 10. Event quests

The accepted Event layout is a set of **parallel independent quest cards**, not a timeline or day-release ladder.

Illustrative event: **Woodland Week**, seven days. No event has been scheduled by this plan.

| Requirement during the event | Reward |
| --- | --- |
| Earn accepted growth on a planted sprout | 300 tokens |
| Welcome/collect 50 butterflies | 300 tokens |
| Complete 3 activity days | 600 tokens |
| Complete 5 activity days | 1 Woodland pack |

All four quests are available from event start. Their progress accumulates concurrently. No Day 1/3/5/7 release gating, prerequisite quest completion, purchase requirement, or rare draw requirement is implied.

The maximum value is **1,200 tokens plus one Standard pack**, or two Standard pack-equivalents at the assumed price. The activity-day definition matches Special. Visitor counting includes active welcomes/actual offline collections during the configured event eligibility interval; decide how pre-event stored visits are attributed so players cannot satisfy an event solely from an old bank without an explicit design choice.

Implement actual start/end timestamps, an authoritative event identity, time-zone presentation, reward policy/version, and a clearly defined claim grace period. Distinguish the earning deadline from the claim deadline. Do not revoke earned rewards merely because the event leaves the main list.

An occasional event can carry this value. Continuous weekly events would make it a recurring income source and require their own aggregate budget. Budget simultaneous events together. Outside an active event, show a short honest empty state; do not display a fictional countdown.

## 11. Gems and long-term reward value

Bonus gems are additional to the normal step entitlement. The proposed Steps schedule grants 26 bonus gems through 1 million steps, alongside the 100 gems earned from steps at the current baseline. Other tracks add their own one-time bonuses.

Review the combined sources after deciding what gems can purchase and the prices of Select/Premium packs. Gem quantities are provisional until their purchasing power is established. Avoid advertising a desirable reward with no usable destination or a pack whose mechanics remain undefined.

### Required accounting change

The inspected `progression.py` derives step gem entitlement from accepted steps and uses `lifetime_gems_earned` as its high-water mark. Its reconciliation currently equates all GemGrant totals, wallet balance, the lifetime field, and step entitlement while spending is deferred.

Do **not** credit milestone gems by increasing that step high-water mark. That can break later step grants and reconciliation. Add explicit source-aware accounting that separates step entitlement from bonus grants, includes any future spending, and preserves durable unique reward identities. Update account-summary semantics, history compaction/reconciliation and migration/backfill behavior accordingly before enabling mixed gem rewards.

## 12. Combined balance and pacing

### Meaningful rewards

At a 1,200-token pack price, 300 / 600 / 1,200 tokens represent one quarter / one half / one full Standard pack. That is the intended scale for meaningful intermediate milestones. Very early visitor tutorial nodes can be smaller because they complete quickly.

### Day-one example

Assume a new player earns 10k accepted steps, hosts 100 butterflies, earns the first seedling, and completes the 10k-day Special quest:

| Source | Reward value |
| --- | ---: |
| Starter + three routine opening pack grants | 4 plant/pack-equivalents |
| Steps at 5k and 10k | 600 tokens |
| Butterfly at 3 / 10 / 25 / 100 | 600 tokens |
| First seedling | 150 tokens |
| First 10k-step day | 300 tokens |
| Total milestone tokens | **1,650** |
| Ordinary tokens from 100 butterflies | **100** |

This example can purchase another Standard pack and retain 550 tokens, before sales, other discoveries or events. That is intentional under the more motivating schedule. It is materially more generous than the earlier low-token proposal.

If the same player qualifies for the separate 5 km running and 60-active-minute workout quests, add up to two exceptional Standard packs, subject to the proposed 10 km replacement rule for the running tier only. If an event overlaps, include its separate rewards. Consequently, four is not a hard day-one total. If a strict four-acquisition total becomes necessary later, these token rewards and exceptional rewards would need redesign; do not enforce it through hidden purchase restrictions.

### Collection depth and growth

The old published test pool contains only Oak and Moonwillow. After a guaranteed Oak starter and three Standard opens at 25% Moonwillow odds, the chance of finding Moonwillow is 57.81%. The expanded catalogue is therefore a material prerequisite, not just visual content.

Re-run forecasts using actual imported species, footprint limits, skills, mature attraction, duplicates, sales and pack guarantees. Several growth/step rewards may arrive in the same session: 100k steps can coincide with first maturity, and batches of plants can mature together.

### Tuning targets

- Measure time to first opening, fourth routine equivalent, first token purchase, and first Select/Premium acquisition.
- Simulate 1 / 7 / 30 / 90 days for low-step, workout-first, highly active, mostly offline and heavy active-welcome accounts.
- Include storage saturation, collection cadence, available garden space, sales and new pack contents.
- Separate Standard pack grants, higher-value pack grants, milestone tokens, bonus gems, visitor tokens and resale in acquisition reporting.
- Aim provisionally for visitors to remain the main sustainable purchase source after the introductory burst. A 70–80% visitor share and 20–30% ongoing bonus share can be an initial diagnostic target, not a universal law or hard cap on one-time celebrations.
- Review broad catalogue completion speed and rarity access, not only pack quantity.
- Adjust future definitions prospectively. Do not silently reduce already-earned rewards or introduce delays after a requirement is complete.

## 13. Authoritative progress and reward definitions

### Definition model

Represent milestones/quests as versioned data rather than an expanding collection of UI conditionals. A definition should include:

- Stable milestone identity and track; Growth subcategory where relevant.
- Concise display requirement, configured order and icon/reward references.
- Metric and threshold or explicit compound predicate.
- Scope: lifetime, one game date, rolling window, single workout, or named event.
- Reward bundle: token amount, bonus gem amount, pack references/quantities and supported cosmetic references.
- Policy version, supported catalogue prerequisites, activation/retirement state and any event interval.
- Shared entitlement or supersession rules, if applicable.
- Progress semantics and claimability/claim status returned by the server.

New IDs should fit the current client journal's `[a-z][a-z0-9_]{0,63}` constraint unless both client and backend validators are deliberately migrated. Do not use dotted names in persisted IDs by accident. Example identity shapes include `steps_100000`, `butterfly_10000` and `growth_mature_25`; event identities also need a stable event instance association.

Define pack-version pinning explicitly. Once earned, a reward must not reroll into a changed pack pool merely because the player claims later. Prefer recording an immutable reward entitlement when the threshold is earned, including the pack contract/version and earning policy. Plan the equivalent pinned entitlement/backfill for already-eligible accounts at activation. If the architecture uses another approach, document how it preserves that same guarantee.

### Durable progress

- Reuse authoritative accepted lifetime steps and hosted totals where their semantics match.
- Maintain durable distinct-copy maturity and permanent species-discovery progress.
- Preserve sufficient daily/workout/window/event facts or aggregates to evaluate quests after existing detail-history cleanup. Do not depend on rows the maintenance worker is allowed to delete.
- Do not award progress from retries, re-enrollment, device changes, historical token rescaling, lower corrected totals or unaccepted manual activity.
- Show unavailable/awaiting-sync data honestly rather than converting missing data to confirmed zero.
- Cross-track observation must not mint multiple copies of a shared opening entitlement or any individual quest entitlement. The separate 5 km and 60-minute Special quests may each be earned once from the same qualifying workout.

## 14. Claim transaction and recovery

Extend the existing server-authoritative claim flow to reward bundles. A claim should atomically validate eligibility, resolve the immutable entitlement, record the once-only claim, grant all reward components, update versions, and return a durable replayable receipt.

Requirements:

1. Lock consistently with the existing account/garden/economy ordering.
2. Enforce a unique account/entitlement identity, including event instance when relevant.
3. Replaying the same request returns the same completion; changing the request UUID cannot duplicate an already claimed reward.
4. Validate token/gem arithmetic and pack capacity before committing. No partial currency grant if the bundled pack cannot be issued.
5. If pack capacity is full, retain the earned entitlement, consume nothing, explain the condition, and allow retry after making room. A future mailbox/reservation design is a separate decision.
6. Issue owned unopened packs through the established immutable pack/draw system. Do not draw a species during milestone claiming.
7. Include granted pack identities/versions, tokens, bonus gems, superseded entitlements and resulting wallet/version state in the completion as applicable.
8. Retain replay/entitlement information through history compaction so old retries cannot become fresh awards.
9. Do not increment hosted counts for milestone currency, gem grants, pack grants or sales.

Client recovery must preserve original request identity/body, account scope and pending state across interruptions. Do not optimistically show spendable balances or a completed pack grant before confirmation. On success, offer the existing Open pack flow; never auto-consume the reward.

## 15. Existing-account rollout

The existing introductory IDs are `first_movement`, `first_hosted`, `three_hosted`, `first_seedling` and `first_maturity`. Their rescaled rewards total 2,400 tokens. Existing claims and receipts are permanent facts.

Before activation, decide and document an explicit mapping for each legacy objective:

- Which new opening/maturity entitlement it fulfills, if any.
- Whether a supplemental grant is owed and its exact contents.
- How accounts that already purchased packs from old rewards are treated.
- How New Beginnings applies to existing accounts.
- Which lifetime thresholds can be backfilled from durable accepted progress.
- Which daily/workout/event objectives start at activation because older eligible evidence is unavailable or was compacted.

Do not reset legacy claims, infer a fixed compensation value from undefined Select/Premium prices, or grant the full new opening allocation on top of all old rewards by default. Backfill must be idempotent, account-scoped and previewable before applying it.

Existing lifetime step/visitor totals may qualify for many new thresholds. Show earned rewards without forcing all historical animations or blocking navigation. Preserve the reward value while keeping recovered presentation quiet.

## 16. Current integration points

These paths were inspected when writing this plan; recheck after catalogue work:

| Area | Existing location / implication |
| --- | --- |
| Page and current rows | `frontend/MovementForest/Features/CollectionScreen.swift` |
| Existing pack/reward artwork presentation | `frontend/MovementForest/Features/CollectionJournal.swift` |
| Botanical palette and shared controls | `frontend/MovementForest/Features/BotanicalJournal.swift` |
| Client collection/claim coordination | `frontend/MovementForest/Services/CollectionCoordinator.swift` |
| Milestone model, receipts, pending journal | `frontend/MovementForest/Models/CollectionModels.swift` |
| Milestone service and old objectives | `backend/src/forest_api/milestones.py` |
| Current claim endpoint | `backend/src/forest_api/collection_routes.py`; `POST /v1/me/milestones/{milestone_id}/claim` |
| Existing claim persistence | `backend/src/forest_api/activity_models.py`; token-only `MilestoneClaim` shape |
| Collection summary integration | `backend/src/forest_api/collection.py` |
| Step gem entitlement/reconciliation | `backend/src/forest_api/progression.py` |
| Currency and pack baseline | `backend/src/forest_api/visitor_rescale.py`; `backend/VISITOR_RESCALE.md` |
| Level capacity behavior | `backend/LEVEL_BENEFITS.md` |
| Compact history/recovery constraints | `backend/SCALING_S4_S6.md` and current recovery implementation |

The existing client milestone type only contains title/description, token reward and boolean eligibility/claimed state. The current client receipt validation expects milestone token fields. Both need deliberate compatibility updates for progress, tracks, direct packs, bonus gems and supersession; changing the backend response alone is insufficient.

## 17. Implementation sequence

### Phase 0 — finish content and lock economics

- Complete and publish the catalogue plus Standard/Select/Premium pack contracts.
- Confirm prices, odds, selection behavior and attainable discovery thresholds.
- Resolve the decisions in Section 19, including bonus-gem accounting and existing-account policy.
- Simulate combined rewards; approve the activation definition set and migration mapping.

### Phase 1 — backend foundations

- Add versioned quest definitions, durable progress/earned entitlements and reward bundles.
- Add any required copy/discovery/day/workout/event progress storage compatible with cleanup.
- Migrate source-aware bonus-gem accounting and reconciliation.
- Implement atomic pack/token/gem claims, supersession and capacity behavior.
- Provide a compact authoritative track/quest summary with sufficient progress metadata.
- Preserve existing replay receipts and define old-client compatibility behavior.

### Phase 2 — rollout and contract validation

- Build an idempotent preview/apply activation and existing-account backfill procedure.
- Publish/pin definition and reward versions without rewriting old packs/claims.
- Regenerate appropriate synthetic frontend contract fixtures using established project workflows.
- Verify counts, eligibility and accounting against isolated test accounts/databases.

### Phase 3 — native page

- Implement the five selectors and accepted visual identity.
- Build reusable timeline rows for Steps/Butterfly and independent quest cards for the other tracks.
- Add Growth filters and honest active/inactive Event states.
- Support reward bundles, readiness, capacity errors, pending claims and recovery.
- Integrate confirmed rewards with shared wallet summaries and existing pack opening.
- Match the concise copy and icon layout in the v2 references.

### Phase 4 — validation and activation

- Complete backend, contract and native checks below.
- Review actual rendered screens on supported devices and large text sizes.
- Apply the approved activation/backfill policy through the explicit deployment procedure.
- Observe acquisition sources and pacing before publishing additional late-game or Premium rewards.

## 18. Acceptance checklist

### Presentation

- [ ] Exactly five icon-and-label selectors; all tracks progress concurrently.
- [ ] Only Steps and Butterfly show timeline rails/nodes.
- [ ] Growth, Special and Event show separate quest cards with local progress.
- [ ] No removed slogans, redundant subtitles, instruction blocks or footer filler.
- [ ] Reward icons retain the accepted left-art/text/progress arrangement.
- [ ] Progress fills match their numerical ratios; zero is visually empty.
- [ ] Claimed, ready, incomplete, pending, unavailable and full-storage states are distinguishable without color alone.
- [ ] Dynamic Type, VoiceOver, Reduce Motion, contrast and 44-point touch targets work.
- [ ] Larger text can scroll selectors rather than shrinking labels illegibly.
- [ ] First-time, returning, offline/cached, error and no-active-event states render correctly.

### Progress and rewards

- [ ] Exact boundaries qualify; a sync crossing several thresholds grants eligibility for each once.
- [ ] Growth bonuses/plant count do not multiply step milestone progress.
- [ ] Stored visitors count only when collected under the approved event/lifetime semantics.
- [ ] Copy maturities and species discoveries survive sales without repeat credit.
- [ ] The 5 km and 60-active-minute quests have separate identities and can both qualify from one workout, with each reward issued at most once.
- [ ] Proposed 10 km supersession affects only the 5 km quest, is claim-order independent and handles earlier-run entitlements correctly; it never suppresses the 60-minute reward.
- [ ] Daily and rolling-window goals respect authoritative dates, enrollment and time-zone rules.
- [ ] Step-earned gems continue correctly after bonus gems; reconciliation and compaction remain valid.
- [ ] Reward pack versions are pinned and do not change with later catalogue publications.
- [ ] No unattainable discovery quest or nonexistent pack is advertised.
- [ ] Discovery endpoints match the initial 10 Common / 10 Rare / 7 Epic / 3 Legendary species; variants never add discovery credit and catalogue expansion does not reset existing tiers.
- [ ] The four reserved cosmetic slots remain absent from initial reward payloads and UI; their milestone identities and earned/claimed facts are retained for a future update.

### Transactions and compatibility

- [ ] Concurrent claims from two devices issue one reward bundle.
- [ ] Retry with the same or a fresh UUID cannot duplicate the same entitlement.
- [ ] Failed capacity validation or another failure leaves all bundle components unconsumed/ungranted.
- [ ] Closing during a claim or pack opening recovers without duplication or loss.
- [ ] Account switching never carries progress, rewards or pending requests into another account.
- [ ] Legacy receipts replay unchanged; backfill can run repeatedly without new awards.
- [ ] Detail-history cleanup does not remove required quest facts or reopen claims.
- [ ] Summary fetches and long tracks remain bounded; no full account-history scan per screen refresh.
- [ ] Test results distinguish portable/backend checks from actual Xcode/device acceptance.

## 19. Decisions to settle before implementation

1. **Pack values:** What exactly do Select and Premium guarantee, and what do they cost? Which, if any, listed Select milestones should instead grant Premium?
2. **Gem utility:** What can gems purchase, and do the combined bonus amounts preserve that economy?
3. **Opening alternative:** Adopt the shared workout alternative for the 1k opening slot, or keep it Steps-only?
4. **Activity-day definition:** Confirm 1,000 accepted steps OR 10 eligible workout minutes.
5. **Running-tier overlap:** Confirm the proposed 10 km replacement rule for the 5 km running quest. The 60-active-minute quest is already separate and remains independently rewarded.
6. **Existing accounts:** Approve the legacy mapping, New Beginnings eligibility, backfill window and any explicit supplemental grants.
7. **Events:** Confirm scheduling/frequency, stored-visitor attribution, game-date boundaries and claim grace period.
8. **Cosmetics — settled for this release:** Leave all four reserved cosmetic components empty, as listed in Section 6. Add cosmetics and decide prior-earner eligibility in a later cosmetics update.
9. **Catalogue-scaled discovery proposal:** Review the 7-Epic endpoint and new 1 / 2 / 3 Legendary ladder against the current catalogue and economy. Finalize values beyond the specified Butterfly/Growth/Discovery thresholds only after forecasting; preserve existing claims when extending the tracks.

## 20. Implementation record — 13 November 2026

The implementation follows the revised 62-quest schedule. No reward policy has been activated in the personal game database, no event has been scheduled, and no push or remote CI run is part of this change. Migration `0017_milestone_tracks` adds storage only; publication and bounded existing-account backfill use explicit preview/apply commands.

The initial publication preview records these concrete rollout defaults for review:

- Standard / Enchanted / Premium cost 1,200 tokens / 4,800 tokens / 5 gems in the existing catalogue; milestone rewards retain the listed Standard/Enchanted packs. Bonus-gem amounts are unchanged.
- The opening movement slot remains Steps-only. Activity days use 1,000 accepted steps OR 10 eligible workout minutes.
- The separate 5 km run and 60-active-minute workout each grant a Standard pack. The proposed first-10-km replacement rule is implemented only for the lower running tier; an earlier accepted 5 km run preserves its own reward. Growth caps do not suppress otherwise eligible workout achievements.
- Claimed legacy objectives fulfill their corresponding new tiers; any legacy claim also fulfills New Beginnings. Existing currency, purchases and receipts remain intact, with no automatic supplemental grants or clawbacks. Accounts without legacy claims use the new opening schedule. Lifetime durable progress backfills; new daily/window/workout evidence starts at activation.
- Cosmetics remain empty at the four reserved tiers. No event is scheduled automatically. Event authoring requires explicit start/end/claim timestamps and explicitly acknowledges collection-time visitor attribution, including pre-event stored visits.

The account wallet separates step-entitlement gems from bonus grants and spending. Claims atomically issue pinned unopened packs, tokens and gems with durable replay/alias recovery and storage-capacity retry. Discovery credits use permanent species records and frozen policy rarity; maturity uses the existing durable first-maturity counter. The native page adds the five artwork selectors, timelines/cards, Growth filters, reward bundles, cached rows, saved track/scroll state and information explanations.

See `backend/MILESTONES.md` for exact legacy mappings, publication/backfill commands, accounting and event semantics, and `frontend/MILESTONES_ACCEPTANCE.md` for portable evidence and the native acceptance checklist. These implementation defaults do not constitute live activation or economic/device acceptance.
