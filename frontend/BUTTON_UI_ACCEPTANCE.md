# Botanical button UI acceptance

Source implemented locally, 6 November 2026. This is a presentation-only change.
No commit, push, CI run, server mutation or migration is part of this work.

## Executed on Windows

- `python frontend/scripts/validate_frontend.py`: passes generated-project,
  bundled resources, synthetic game contracts and palette checks. Button text
  meets 4.5:1 and olive control outlines meet 3:1 on paper/sage. Primary default
  and pressed colours are the inverse of the tested action/ink-on-paper pairs.
- `python frontend/scripts/check_swift_syntax.py`: all 79 Swift files parse.
- Source-token comparison of all 20 modified Swift files against their clean
  pre-change source: identical after excluding only visual modifiers and the new
  button-style/palette definitions. This retains every existing action closure,
  disabled expression, label, confirmation, request/recovery path and lifecycle
  operation. The local audit is `.validation-tools/check_button_ui_scope.py`.
- Backend source/migrations, models, services, renderer, native tests, resource
  fixtures, signing and Xcode project files are unchanged.
- Diff whitespace checks pass for this change. Unrelated existing edits remain.

These checks do not compile against Apple SDKs or establish native appearance.

## Compact follow-up after iPhone review

Remove resting frames/backgrounds from icon/tool controls. Reduce normal text
button font/padding, inset the visible face, soften its shadow and use a subtle
16-point vine on primary/secondary actions. Keep 44-point targets and existing
callbacks/guards. Catalog restores the exact variant selector from `44fd669`.
Repeat the portable checks below; native appearance still requires the Mac/iPhone.

## Mac build and native tests — pending

From the repository on a Mac with Xcode and an iPhone simulator:

```bash
bash frontend/scripts/test-mac.sh
```

This runs XCTest/UI tests and public Release/InternalRelease simulator builds.
Use existing fixture arguments/tests to avoid real Health reads and server writes.

## One native visual and interaction pass — pending

Use a compact supported portrait iPhone and the normal iPhone target. Capture
normal text and a large accessibility text size in the shipped light appearance.

1. Garden: inspect Info/Collect, selected-plant actions, Settings and collection
   menu. Controls must remain within their existing overlays. Camera, visitor
   touch access and the mounted scene must remain stable through browsing.
2. Edit: inspect Storage, selection/camera tools, Done editing, Move/Rotate and
   Position. Apply is primary; Cancel/Position are secondary. Invalid placement
   and saved-request guards still disable the same operations. Verify Cancel,
   Apply and Done retain their distinct existing effects.
3. My plants/Storage: test filters, Load more and the fixed inspector footer.
   Place and exact-price Sell must fit or stack without clipped text. Selling
   still requires the existing native destructive confirmation; cancel preserves
   the copy. Use a disposable test account for any actual sale.
4. Catalog: selected variants use the original capsule strip, retain their
   selected accessibility trait, and fall back to the native menu when needed.
   Rarity frames, discovery masks and explanation actions remain distinct.
5. Exchange/Packs/Milestones: check compact card actions, Purchase/Cancel, info
   targets, insufficient tokens, capacity-full, pending and recovery states.
   Quantity/total/confirmation and claimed/locked behavior are unchanged.
6. Opening: preserve confirmation, tear tap, reveal tap, result and Continue.
   Existing progress indicators remain visible. Interrupted/recovered openings
   still recover their original saved result without replaying rewards.
7. Activity/recap: inspect Sync now, Continue, Health actions, sync consent and
   retries. Keep request messages and saved/unknown states visible. Continue
   remains dismissal rather than a new reward claim.
8. Account/settings/help: check sign-in/profile/recovery/account actions, native
   back navigation and Done. Apple sign-in and all native alert/menu controls
   retain their platform appearance and semantics.
9. VoiceOver: verify names, selected/disabled traits, independent info controls,
   unchanged focus order and Close/Escape. Decorative vines are silent and never
   intercept touches. All app button targets remain at least 44 × 44 points.
10. Enable Reduce Motion and Increase Contrast. Primary presses must not move
    with Reduce Motion; text-button outlines strengthen with Increase Contrast. Disabled
    labels remain readable, and confirming Collect stays the same target size.

Batch any native findings, fix them together and confirm once. Native acceptance
must be recorded separately from the Windows checks above.
