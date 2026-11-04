# Stage 5 collection journal

Implemented on 5 November 2026. Native validation and device acceptance remain pending.

## Scope

- Exchange/Packs portrait grids, neutral botanical pack frames, fixed name/art/action
  slots and separate tap/hold information controls.
- Confirmed token/capacity summary and retained pending/cache/recovery/full notices.
- Inset scrollable contents/purchase inspectors with fixed Close and purchase footer.
- Rarity/species sprout tiles and concise conditional/overall odds below the selected
  tile; existing catalog disclosures reuse the same odds text.
- Saved last-opening plant card, journal reveal framing and fixed opening actions.
- Milestone checklist cards and collection-menu materials.
- Sale confirmation copy: "Sell this plant?" / "This action cannot be undone."

Existing artwork, native symbols, journal ornaments, rarity colors and plant art
are reused. No generated/new runtime artwork is needed.

## Executed Windows checks

- Swift parser: 79 Swift files pass. This is syntax validation, not compilation.
- Frontend resource/project/contract validator passes: 61 application Swift source
  references, generated project, 20 models/thumbnails, presentation resources,
  journal/rarity/orange contrast, collection accounting/odds and discovery fixtures.
- Scoped whitespace validation passes.
- The 252 tracked files under backend/src, backend/tests, backend/migrations,
  frontend/MovementForest/Services, Models, Rendering and assets match the
  pre-change fingerprint:
  d09e9e3a22d804e39dad0e8db888fdafe88ee0c0e40edd33366900642f58aec6.
- Pack submission/lifecycle handlers, interruption/recovery helpers, transition
  timings/state machine and mouth-light helpers are unchanged. Purchase submission,
  quantity/cost/eligibility guards, refresh, result selection and catalog/discovery
  behavior are retained. All Garden/Edit sources and app-shell geometry are unchanged.

No backend suite rerun is required for these presentation-only changes; no backend
code/tests/migrations were edited. No database was migrated or mutated.

## Native automation — added/updated, not executed on Windows

JournalPresentationTests covers equal card heights for long names/prices across
text sizes, invariant species-tile size when odds expand, and narrow summaries
with missing/large balances and over-limit counts.

ForestUITests retains the real-view purchase quantity/affordability/cancellation
checks and uses the new inspector controls. Added coverage checks information
long-press/odds expansion without a mutation and a reachable fixed purchase footer
at accessibility text size. Existing collection recovery, repeated-open, latest
receipt, all-rarity two-tap, generic-pack, Reduce Motion and background-interruption
tests remain in place.

Run on Mac:

    bash frontend/scripts/test-mac.sh

This runs native tests and Release/InternalRelease builds. Xcode/Apple SDKs and an
iPhone simulator are unavailable on this Windows host; no native pass is claimed.

## Device acceptance — pending

1. Check Exchange/Packs/Menu on a small iPhone and at normal/largest Dynamic Type:
   equal cards, readable prices, reachable 44-point actions, last content above
   navigation and one-column accessible layouts. Long names must not enlarge cards.
2. Inspect each offer and an older owned pack. Compare tier/species/variant odds
   against that exact definition. Expansion stays below its tier's grid; sprout
   art only. Check missing metadata/artwork and generic-pack fallback.
3. Cancel purchase through Cancel, Close and the backdrop: no wallet or inventory
   change. Buy quantity 1 and multiple packs; exercise insufficient tokens, full
   capacity and remaining room below 20. Success/failed refresh remains truthful.
4. Confirm pack opening still needs both deliberate taps. Check every rarity,
   generic artwork, Reduced Motion and readable light/dark contrast. Final Continue
   stays reachable while art/name/status scroll. Final copy is "Saved to Storage."
5. Background/depart during confirmation, tear, opened wait, reveal and result.
   Relaunch/recover the saved request: one pack consumed and one saved plant;
   confirmed interrupted results do not replay. Test a lost response/account switch.
6. Check empty/loading/offline/error/pending states and paginated packs. Global
   capacities must not use loaded counts. Old purchase/milestone/sale receipts
   must not replace the last confirmed opening.
7. Check eligible/ineligible/claimed/pending/cached milestones, disclosure and
   claim retry. No invented progress and no duplicate claim.
8. Check stored/planted/protected-starter sale states and exact-price confirmation.
   Only confirmation copy changes; failed/pending sales keep existing recovery.
9. Verify VoiceOver order, Close/Cancel, separate card information/action targets,
   result focus, non-color rarity labels and accessible odds/amounts.
10. Return to Garden/Edit after each route: full viewport, camera, visitors and
    existing collection-route pause/resume behavior remain intact.
