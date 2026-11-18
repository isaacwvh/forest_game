# Compact milestone rows — 18 November 2026

Implemented the approved compact composition in `MilestoneTracksScreen.swift`.
All five tracks share quest-type artwork, one description, an in-bar progress
label and an equally sized reward/state box. The default target is an 88-point
row with an 80 × 72-point reward box. A single measurement across all tracks and
filters reserves space for the longest real description, numeric labels, reward
bundles and state messages. Narrow/large-text layouts wrap or stack. No requirement is line-limited.

Rewards use the bundled token/gem/pack artwork and quantities without visible
reward names. Dotted boxes are uncollectable; green boxes reuse the existing claim
button; Pending, Claimed, Previously fulfilled, superseded, Unavailable and Pack
storage full use the same frame. Full unavailable reasons remain available from
a labelled 44-point information target on the quest icon and in accessibility.
The introductory display copy reads Start your journey. Event metadata is outside
the standard quest card; decorative timeline rails are removed. The summary and
next-unclaimed control share a compact row when they fit.

## Scope verification

No backend, service, coordinator, API, model, persistence or asset source changes.
The existing `progressFraction`, integer progress formatting, state precedence,
`store.claim(row)`, `store.canMutate`, pack-room guard, retry/status handling,
ordering/filtering and saved track/scroll lifecycle are preserved. A source diff
review compared these unchanged functions/guards with HEAD. UI state for the full
unavailable-reason alert is local to the row; it performs no game operation.

## Local validation

Passed on Windows:

- `python frontend/scripts/validate_frontend.py`: project freshness, resource and
  archive hashes, bundle membership, wire contracts and palette contrast.
- `python frontend/scripts/check_swift_syntax.py`: all 105 Swift files.
- `python tools/validate_woodland_release.py`: all species, variants and packs.
- Impeccable detector on the changed milestone UI: no findings.
- Scoped `git diff --check` and the source/guard review above.

- New reward and in-bar text contrast: at least 6.40:1 in the checked composites.
- Full backend regression: **751 passed, 3 existing opt-in physical storage
  benchmarks skipped**, in 793.80 seconds. Used a newly initialized isolated local
  PostgreSQL cluster, which was stopped after the run. Log:
  `backend/.local-milestones-ui-validation/3ed89534ca/tests.log`.

No push or remote CI has been performed.

## Added native regressions — execution still required

`MilestoneTracksTests` now checks description-only copy, named accessibility for
mixed reward bundles, unavailable/claimed/future/introductory progress, standard
row/reward dimensions across states, 320/375/393/430-point device widths, ordinary/
XXXL/maximum accessibility fonts, three reward types and long exact ratios.
Hosted view tests measure both short and long real quest requirements. The UI
suite checks that row heights match and that all visible progress bars and claim
buttons remain within their row across Steps, Butterfly, Growth and Special.
Existing selector-painting, repeated cached-entry, empty-Event, saved-anchor and
maximum-text UI regressions remain in place.

These XCTest/SwiftUI tests were syntax-parsed, not run on Windows. This host has
no Xcode/Apple SDK or iPhone simulator. Run `bash frontend/scripts/test-mac.sh`
on macOS for native XCTest/UI execution and Debug/Release/InternalRelease builds.
Then inspect:

- Every track, especially event headers/deadlines and long Growth requirements.
- Locked, ready, pending, claimed, legacy, superseded, full-storage and unavailable
  boxes; no frame change when a pending claim is confirmed.
- Visible selector painting after leaving/returning, refreshing and saved scrolling.
- In-bar numeric text at zero/tiny/full/over-target/missing progress, large values
  and maximum Dynamic Type; no clipped descriptions or quantities.
- VoiceOver requirement, progress, all named reward types, button/state semantics,
  full unavailable explanations and existing pending/offline recovery messages.
- Real claims still use confirmed-only accounting and the existing storage and
  mutation restrictions. This UI change does not certify a native device pass.

The older entries below describe historical implementations; the compact layout
above supersedes their timeline/reward-text guidance.

---

# Milestone tracks acceptance — 13 November 2026

The native Milestones route now presents five artwork selectors on the existing
journal surface. Steps/Butterfly use lazy timeline rows; Growth/Special/Event use
independent cards. Growth retains All/Maturity/Discovery, with a native menu at
accessibility text sizes. Rewards, progress and claimability come from the server.

The approved v2 concept images remain the visual reference. Transparent boot,
lavender butterfly, potted sprout, gold medal and leaf-calendar assets are bundled
at 64/128 pixels with a manifest; all ten exports total 94,515 bytes. No cosmetic
rewards or placeholder cosmetic icons are displayed. Existing garden/edit,
placement, butterfly interaction and pack-opening presentation remain unchanged.

Client changes include track/progress/bundle/event models, `X-Forest-Milestones: 1`,
source-aware gem validation, a workout-distance upload field, complete milestone
receipt validation and account/server-scoped cached rows plus saved track/scroll
positions in the existing durable journal. Pending claim IDs/bodies survive disk
recovery. Currency and packs appear only after server confirmation. Pack rewards
offer the existing Packs/Open flow. Legacy mappings show Previously fulfilled;
superseded running rewards show Included in 10 km reward.

An information affordance explains qualifying activity days, single-workout rules,
the independent 60-minute reward, 10 km replacement, permanent collection credit,
old rewards, unopened packs and event collection/deadline semantics. Removed
slogans and footer filler are absent from the list.

## Executed portable checks

### Selector container replacement — 14 November 2026

Device feedback confirmed that the earlier height, layer and native scroll-edge
changes did not resolve the failure, including after refresh. Those diagnoses
were not established by native reproduction. The selector's horizontal ScrollView
is now removed. An intrinsic row retains the five artwork/text controls when they
fit; a labelled native menu provides all five tracks at narrow widths/large text.
There is no selector scroll state or iOS-26-only edge modifier. The failed edge
modifier and extra z-order override are removed. The scrolling milestone list,
account-scoped saved positions, reward data and claim operations are unchanged.

The pixel regression covers leaving/returning with and without list scrolling,
refreshing after return, and the large-text menu's selected track/visible label.
The fixture continues recreating the entire native NavigationStack on each route
change. Portable resource/project/contract/contrast validation, 94 Swift syntax
parses and whitespace checks pass. Native Xcode/UI/VoiceOver execution and device
confirmation remain pending; these portable checks cannot establish the original
UIKit/SwiftUI rendering cause or certify that the device symptom is resolved.

### Native scroll-edge follow-up — 13 November 2026

Device feedback confirmed that the sibling-layer correction below did not resolve
the blank-but-tappable strip on return. The next targeted change disables the
native top scroll-edge effect for both scroll views in the Milestones hierarchy
on iOS 26+, using Apple's `scrollEdgeEffectHidden` API. It is scoped to this screen;
other pages and the saved selection/scroll/claim state are unchanged. The compiler
guard preserves builds with the previously supported pre-iOS-26 SDKs.

The regression fixture now recreates the entire NavigationStack on destination
changes, matching the real app; previously it recreated only CollectionScreen.
Its native title is inline as in the app. The rendered-selector regression also
leaves and returns without first scrolling. This checks the reported route rather
than relying on hit testing. Portable syntax/resource/project/contract/contrast and
whitespace validation pass; Xcode execution and device confirmation remain pending
on Mac/iPhone. The native-edge-effect diagnosis remains unconfirmed on this host.

### Selector painting correction — 13 November 2026

Device feedback after the refinement showed a blank strip whose five selectors
were still tappable. This rules out a missing view/zero-height explanation and
points to drawing-layer overlap; the previous hit-testing assertions could not
detect it. The fixed selector/filter group now has an opaque journal-paper backing
and explicit foreground z-order. The vertical reader is clipped to its own bounds,
so its scrolling content/effects cannot draw over the fixed controls. Existing
layout dimensions, saved anchors and all selection/claim behavior are unchanged.

The repeated cached-entry UI regression now samples the rendered selector image
for visible artwork/text, before scrolling and after every return. It fails on a
blank-but-tappable strip and attaches the failing screen. Syntax/resource/project/
contract/contrast validation and whitespace checks pass on Windows; the native
pixel regression and iPhone visual confirmation still require Xcode. Verify the
actual painted icons/labels, not just tappability, after returning and refreshing.

### Frontend refinement — 13 November 2026

The track strip now keeps its intrinsic height above the list, including cached
return visits. Selection initializes from the saved journal, and one cancelable
post-layout task restores a valid row anchor once per track/filter. The rail is
an overlay sized by its row. Compact reward text removes duplicate currency icons;
ordinary narrow layouts fall back to stacked actions, as accessibility sizes do.

Routine Exchange affordability/success footers, the milestone receipt footer and
the pack-opening saved message are removed. Storage/My plants use the existing
categorized feedback filter. Pending, offline and actionable failures remain;
receipts, claim guards, account state and backend contracts are unchanged.

Portable frontend/resource/project/contrast validation, all 94 Swift syntax parses
and changed-source whitespace checks pass. New UI regressions cover repeated
cached entry, visible selectors, saved row restoration, all tracks, empty Event
return and large-text wrapping. Existing purchase/opening checks now verify quiet
success presentation. These native tests are added but **not executed on Windows**.
Use `--fixture-health --fixture-collection --fixture-milestones` for deterministic
manual inspection without network, authentication or disk writes.

- Generated Xcode project freshness and full resource/asset/contract validation.
- Tree-sitter syntax parsing of all 94 Swift files.
- Real HTTP-derived `milestones-contract.json`: 62 quests, catalogue endpoints,
  separate workout rewards, version-20 unopened packs, mixed token/gem receipts
  and account step/bonus gem reconciliation. The fixture contains synthetic test
  identities only and is regenerated by `backend/scripts/validate_milestones_local.py`.
- PNG RGBA dimensions, hashes, manifest and bundle membership; existing 188 plant
  assets, pack art, geometry, journal palettes and native configuration checks.

These checks do not compile or render SwiftUI. The following are still required
on a Mac/iPhone; no simulator screenshot or native test pass is claimed here.

## Native checks

Run `bash frontend/scripts/test-mac.sh` on macOS. It runs XCTest/UI tests and
Debug/public Release/InternalRelease build checks. New `MilestoneTracksTests`
exercise actual HTTP contracts, source-aware gems, discovery endpoints, progress
ratios/missing values and saved pending/selection state. Existing collection tests
also check that cached milestone rows survive coordinator recreation.

- Inspect Steps/Butterfly rail geometry, quiet future nodes, ready/claimed states
  and left artwork → text → progress/action arrangement against both v2 concepts.
- Inspect Growth filters and independent quest cards, a real event with a deadline,
  and No active event when none is scheduled. Only the two timeline tracks have rails.
- At the largest text sizes, confirm the labelled native track menu, the Growth
  menu, card wrapping/vertical actions and 44-point buttons. Check VoiceOver
  selection, ready indicators, progress, rewards, pending and full-storage states.
- Claim direct packs and mixed bundles, open through Packs, fill storage and retry
  after opening, disconnect during claiming/opening and recover after relaunch.
- Switch accounts/servers with cached progress and pending requests. Confirm no
  rows, selection, balances or rewards cross account boundaries.
- Record a real running workout with distance, a supported 60-active-minute
  workout and a single run meeting both. Verify server baseline, source/manual
  exclusions, pauses, overlap and 10 km supersession match the information text.
- Exercise first visit, return/scroll restore, large earned backfill, cold offline
  cache, failed refresh, Reduce Motion and both increased contrast/transparency
  settings. Verify no historical reveal sequence blocks navigation.

Deploy/migrate and preview activation using `backend/MILESTONES.md`; do not run
development seed/reset commands against the game database. This session does not
push, invoke remote CI, activate a personal reward policy or schedule an event.
