# Stage 1A–1C — native review checkpoint

Source implemented on 31 October 2026. The user requested a commit/push for Mac
testing without waiting for CI. This batch is ready for native build and on-device
review; source and portable validation do not establish a successful Xcode build
or a CI result.

## Scope

- **1A:** My plants copy grids, rarity frames, compact growth, loaded-page
  search/filter, journal palette and tap/hold icon explanations.
- **1B:** inset owned-plant inspector, fixed Close/Place regions and scrollable
  body; no description; existing guarded placement retained.
- **1C:** species catalog grid and full species page with selector, attributes,
  approved description, four responsive stages, multipliers, skills and odds.

The recap and the extended renders' other pages are not implemented in this batch.
Existing Storage/Garden lists keep their layouts; only their shared detail
presentation is adapted so opening an inspector stays consistent.

## Build first on Mac

Copy the full repository, including assets/journal/, alongside existing
Oak/Moonwillow/quantity assets. The Xcode project is generated and current.

Run the existing gate locally, without pushing:

    bash frontend/scripts/test-mac.sh

It runs Debug XCTest/UI and public Release/InternalRelease builds with the Apple
SDK. Keep any failures as failures; Windows parsing is not a replacement.

New coverage is in JournalPresentationTests (five tests) and ForestUITests (two
new UI flows plus the updated owned-inspection/placement regression). The Debug
--fixture-health --fixture-collection route now offers Catalog in its page picker.
The existing --fixture-health --fixture-garden route covers My plants/Storage.
These fixtures do not connect to a real account or upload Health activity.

## Device walkthrough

Check a typical portrait iPhone and the smallest supported viewport, first at the
normal text size, then at the largest accessibility text size. Capture My plants,
the owned inspector, catalog index and catalog detail together for review against
the original approved renders. Do not extend the design to the next batch until
this checkpoint has been reviewed in the actual application.

1. **My plants:** compare grid density with the old rows. A typical 390 pt width
   uses three compact columns; narrow and larger-text layouts use fewer columns.
   Check Oak and Moonwillow names, varied stages, long amounts, duplicates and
   both Planted/Stored sections. Search/filter only applies to loaded copies;
   Load more remains usable and cannot imply that unloaded copies do not exist.
2. **Rarity:** Oak Standard/Blue/Vined all have Common grey frames; both
   Moonwillow variants have Epic purple. Verify icon tap and a stationary hold
   open the explanation without opening the plant. Scrolling must cancel a hold.
   Missing rarity stays neutral, never guessed.
3. **Inspector:** open from My plants, normal Garden selection and Edit Storage.
   Confirm margins on all sides, a visible scroll indicator, exact current-stage
   art, fixed Close and reachable final content. Close, scrim tap and VoiceOver
   Escape return to the previous screen without changing a plant.
4. **Read-only boundary:** My plants and normal Garden never offer Place/Move/
   Store controls. Edit Storage alone offers Place. Tap Place, cancel the local
   preview, repeat and place normally. Confirm the same copy/progress is retained,
   no second mutation occurs and the candidate survives the modal transition.
5. **Owned facts:** at 250 water with pinned boundaries 100 → 400, the bar is
   50%, with 150 to Young. Adults show Fully grown. Unknown progress is unavailable
   rather than zero. Multipliers use this copy's pinned profile. Skill activation,
   storage inactivity and duplicate resolution remain unchanged.
6. **Catalog:** search/filter species; open before ownership; switch each variant.
   The header always uses that variant's sprout. Three primary attributes precede
   the description, which precedes Growth stages. There is no lower Clearance &
   plant information section, legacy initial-collection sentence or inline tips.
7. **Descriptions:** verify the exact Oak/Moonwillow text below on a real
   catalog, including a cached legacy-placeholder catalog. Do not show it on My
   plants tiles or owned details. Debug fixture descriptions may remain explicitly
   synthetic. Authored server descriptions take precedence over the legacy fallback.
8. **Discovery:** sprouts stay visible; later art remains a solid silhouette until
   confirmed for that exact variant. Switch variants during refresh/failure and
   check there is no full-colour flash. Keep confirmed offline unlocks, readable
   thresholds/attraction and missing-image versus locked-state distinctions.
9. **Accessibility:** inspect VoiceOver reading/focus order, 44 pt icon controls,
   help dismissal, Dynamic Type, contrast and reduced motion/transparency. At
   larger text sizes the stage strip becomes 2×2, then a vertical stack.
10. **Regression:** background/return, connection loss, pending edits and account
    changes retain their existing recovery. Confirm the Garden's mounted renderer,
    camera and transforms are stable. Purchases, visitor accounting, activity
    growth, entry recap and pack-opening behaviour are unchanged.

## Approved catalog copy

- **Oak:** Broad-crowned oak with sculpted branches, grouped foliage and softly
  veined early leaves.
- **Moonwillow:** Curved trunk, cascading silver-green foliage and tiny
  crescent-shaped leaves

The app bundles this copy only as a fallback for empty/legacy server
descriptions. Fresh server publications use the same text. Existing
databases can preview/apply the existing-field update using:

    forest update-catalog-descriptions
    forest update-catalog-descriptions --apply

Run against the intended configured database only. The operation refuses missing
species, is transactional/repeat-safe, and changes description text only. It does
not republish balance, change a catalog/rule version or apply a schema migration.
The running local game database was not changed during this task.
