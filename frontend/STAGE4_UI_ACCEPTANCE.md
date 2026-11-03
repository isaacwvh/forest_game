# Stage 4 Garden/Edit completion — 3 November 2026

Prepared for Mac testing. The user requested committing and pushing this batch
without waiting for CI. No CI result is claimed.

Follow-up correction: the user requested the original viewport, with overlays
and no dedicated browsing slots. The pre-Stage 4 viewport is restored while
retaining the new selection card. The normal header uses one aligned compact
row; token feedback has shared space instead of offsetting only its icon.
The native viewport tests now enforce full-scene browsing and navigation
clearance, replacing the reserved-region contract described below.
The correction passes portable frontend/syntax/whitespace checks; the updated
native header and viewport tests still require Xcode.
Edit follow-up: editing also renders the full viewport. Status, selection,
position/rotation controls and the compact side panel overlay it without fixed
blank strips. Regression coverage now checks full width/height in both modes
and unchanged camera/model identity when switching modes or expanding notices.

## Executed validation

- Full backend regression suite: **511 passed, 3 skipped** in 442.17 seconds.
  The skips are the existing opt-in physical-storage benchmarks.
- Portable frontend checks pass: generated project/source membership, model and
  image packages, permanent discovery, wire fixtures, journal/rarity/recap
  contrast and release configuration. **78 Swift files** parse without syntax
  errors. Backend Ruff lint/format and scoped diff whitespace checks pass.
- A task-start versus final SHA-256 comparison verifies **249 tracked files
  unchanged** across backend source/tests/migrations, frontend services/models/
  renderer and assets. Existing unrelated documentation and untracked artwork
  remain outside this batch. No database migration or asset generation is needed.

Backend tests used only randomly named forest_test_* databases on the isolated
local validation cluster, which was stopped afterward. No live game data or
running game service was modified.

## Presentation and preserved behavior

- Garden and Edit share a current-plant selection card with rarity, portrait,
  variant, stage and available growth. Garden exposes Details/Close. Edit adds
  the existing guarded Move, Rotate and Store operations. Native label-only
  context menus explain action icons on hold without invoking the tap callback.
- Header, garden and popup/editing controls have separate clipped regions.
  Browsing honors the actual navigation edge; editing keeps its side layout in
  compact height. Slots remain constant for selection, loading, saved-state and
  recovery content changes. Large text/content scrolls inside a slot. The
  scene stays mounted; keyboard/safe-area changes follow the available bounds.
- Panel hit-exclusion preferences are clipped to visible panel bounds before
  conversion to scene coordinates. Scrolled-off header/card content cannot
  block an otherwise visible butterfly's native accessibility target.
- Precise Position replaces its old form with inline numeric fields and angle
  slider. Formats remain three decimal places for coordinates and two for the
  angle. Store updates, validation, drag-release autosave, request encoding,
  preflight, retries and Apply/Cancel operations are unchanged. Scene ground
  input is blocked during precise entry while rendering stays live. A controlled
  Apply does not cancel itself if preflight removes its preview.
- Move/Rotate do not reveal mature art. Initial placement preview is retained.
  Done/background cancellation remains routed through the existing handlers.
- Garden header/info/recovery and sample plant browsing now match the journal.
  Token feedback and visitor calls/eligibility are unchanged. Attraction is
  rounded for display only. Sample cards do not invent owned-copy water data.

## Native gate still required

Windows cannot run Xcode/Apple SDK compilation, native XCTest/UI tests or iPhone
screenshots. Those results are **pending, not recorded as passed**. New/updated
native coverage includes dock/garden/navigation non-overlap, region bounds at
small/large/compact sizes and large text, clipped hit exclusions, stable camera
and model imports, inline precise-position visibility, icon-hold isolation and
the sample browser's grid/details entry point.

On the Mac, run from the repository root:

    bash frontend/scripts/test-mac.sh

Then review on a small portrait iPhone and with large Dynamic Type:

1. Garden: select plants near each edge and with long names/variants. The card
   remains above navigation, outside the visible garden, and reachable. Close
   and empty-ground dismissal work. Details returns to the same selected copy.
2. Edit: select via scene and the plant picker. Check rarity/help, Move, Rotate,
   Store, Details, Storage, camera controls and Done. Hold Store without storing
   the copy; only its normal tap performs the existing operation.
3. Move/Place: check valid drag-release autosave and invalid/boundary feedback.
   Open Position; edit X/Y/angle, inspect live rendering and use keyboard Done.
   Cancel discards the candidate; Apply preserves exact coordinates and handles
   activity preflight, failure and saved-request recovery as before.
4. Rotate: the plant stays visible; precise angle entry, slider, Apply/Cancel
   work. Mature preview remains absent in Move/Rotate and available for initial
   placement. Background and Done discard only unsaved previews.
5. Force loading/offline/artwork/visitor recovery notices and expand skill
   descriptions. Panels scroll without covering the garden or selection card.
   Check token feedback, Collect, butterfly touch/VoiceOver and retry behavior.
6. Sample Garden and Game help's sample plant grid stay explicitly sample/read
   only. Selection, rarity help and details remain usable without Health/account
   access. No move/place/store control is introduced to those routes.
