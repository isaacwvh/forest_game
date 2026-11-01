# Stage 2 UI validation — 1 November 2026

Prepared for Mac testing. The user requested committing and pushing this batch
without waiting for CI; no CI result is claimed here.
This Windows environment cannot run Xcode, Apple SDK typechecking, XCTest or
iPhone screenshots; native results are pending, not recorded as passing.

## Portable checks

- Swift syntax parser: all 74 application/test Swift sources pass.
- Frontend validator: generated Xcode project, source/resource membership,
  bundled models/thumbnails/ornaments, wire fixtures, permanent discovery,
  quantity icons, journal/rarity contrast and release configuration pass.
- Targeted diff whitespace checks pass. Services, models, rendering, backend
  source, assets and stored data are unchanged by this batch.

## Native regression coverage added

- Connected rotation keeps the renderer visible, preview rotation changes the
  existing plant without reimporting it, and viewport/camera stay stable.
  Cancel restores the original transform without sending a request; Apply sends
  one rotate request with no position changes and preserves growth.
- Compact catalog metrics give 1000, 1,000 and 1000.1 one number row at the
  narrow four-stage layout width, retaining a 44-point icon touch target.
- The existing owned-copy UI walkthrough now checks Storage rarity-help
  isolation, placement, visible garden during slider use, angle updates,
  cancellation and applying rotation.

## Mac and device checks

Run the existing full native gate from the repository root:

    bash frontend/scripts/test-mac.sh

This executes native unit/UI tests and Release/InternalRelease builds.
Then check the following on a small portrait iPhone and with larger text:

1. Edit → Storage: cards match My plants, long names and fully grown copies keep
   equal heights, and icon help opens without selecting/placing a copy. Check
   empty/error/cached states and Load more when available.
2. Storage → copy → details → Place: Cancel keeps the copy stored; Apply places
   it through the existing save path. Select plant uses the same cards and
   selects the correct copy, including duplicates.
3. Select a planted copy → Rotate: the plant remains visible above the panel.
   Drag the slider and check live rotation; enter a precise degree value and
   dismiss the keyboard with Done. Check Adult preview, including its disabled
   state on adult plants. Cancel restores the saved angle; Apply saves it.
4. While rotating, background/reopen or use Done editing: the unsaved preview
   is discarded. Check save failures/retry retain the existing recovery flow.
   Move/Position, Store and scene zoom/orbit retain their behavior.
5. Catalog → plant → Growth stages: adult water 1000/1,000 stays on one line,
   full values remain accessible, and the stage grid adapts to larger text.
   Icon popups, undiscovered stages and variant selection still work.

No gameplay service, rule, precision, database or API change is included.
