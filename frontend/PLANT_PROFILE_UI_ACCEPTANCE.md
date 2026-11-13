# Plant profile UI refinement — 13 November 2026

The user requested committing and pushing this batch for Mac testing without
waiting for CI. No CI result, personal database migration or service deployment
is claimed.

## Scope

- Catalog and owned profiles show centered, wrapping plant tags below the variant
  and above the existing attribute strip. Duplicate/empty tags and repeated rarity
  tags are omitted. Tag labels are noninteractive and accessible as one group.
- Catalog, My plants, Garden details and Edit Storage share the compact activity
  multiplier component. Each icon/value stays together; the grid uses wider cells
  and the heading no longer competes with a decorative divider. Metric help names
  the activity and its multiplier, including wildcard and typed workouts.
- Full owned profiles integrate the current-stage start and next threshold into
  the growth bar. Stage names sit above the endpoints, water thresholds below,
  and remaining water/"Stage N of 4" in an adaptive footer. There are no dot
  separators or separate Growth details disclosure. Adults show Fully grown and
  their terminal water threshold; unavailable progress is not shown as zero.
- Compact inventory bars, gameplay calculations, skills, growth accounting,
  rewards, placement/sale callbacks and the mounted garden renderer are unchanged.

The user explicitly approved two additive read-only owned-plant API fields,
`metricMultipliers` and `gameplayTags`. The existing PlantPresenter resolves them
from the copy's pinned behavior/attraction profiles. Historical copies no longer
depend on those profiles being included in the current catalog. There are no
database model/migration or gameplay-rule changes. Swift fields are optional for
older responses/caches; the compatibility lookup uses an exact profile ID/version
and never substitutes current species defaults. Refresh against the updated API
is necessary to fill values absent from old cached snapshots.

## Validation

- Portable frontend assets/contracts/project/palette validation: passed.
- All 92 Swift application/test sources syntax-parse: passed. This does not
  establish Apple SDK typechecking or execute XCTest.
- Woodland release/compiler/assets verification: passed.
- Backend Ruff lint and format checks: passed.
- Design detector over changed UI source: no findings.
- Backend AST comparison: only the two DTO fields and corresponding presenter
  values differ. Migrations, gameplay calculations, database models, frontend
  services/rendering and owned-copy actions are unchanged.
- Full backend regression suite: **632 passed, 3 skipped**, 972.29 seconds.
  The three skips are the existing opt-in physical-storage benchmarks. The
  repository test helper used disposable `forest_test_*` databases in its
  dedicated local PostgreSQL cluster and shut that cluster down successfully.

New regression coverage checks pinned metadata after catalog defaults change,
including inventory, planted and individual-copy API reads; exact compatibility
lookup; known empty values; tag presentation; narrow/accessibility layouts; and
both My plants and Edit Storage profile entry points. Native tests are added but
have not been executed in this Windows environment.

## Native acceptance

On a Mac, run from the repository root:

```sh
bash frontend/scripts/test-mac.sh
```

This runs Debug XCTest/UI plus Release/InternalRelease simulator builds. Then
review a small portrait iPhone at normal and accessibility text sizes:

1. Catalog: switch variants and verify the tags, icon/value rows, help popovers,
   discovery masks, stage facts and native back navigation.
2. My plants: inspect planted and stored copies, including duplicates and copies
   acquired before Woodland. Verify tags/multipliers match the copy's pinned
   values, and no Place/Move/Store controls appear in read-only inspection.
3. Garden and Edit: open the same copy through details, then Edit Storage. Confirm
   tags/multipliers and growth endpoints are consistent, Close remains fixed and
   only Edit Storage offers Place. Store/replant retains identity and progress.
4. Growth: 250 water between pinned thresholds 100 and 400 is a half-filled bar,
   with 150 remaining and Stage 2 of 4. Check sprout, young, adult, fractional
   water, legacy thresholds and unavailable progress. No Growth details dropdown
   or dot separator remains in the full profile's growth section.
5. Accessibility: verify tag reading, exact water accessibility values, activity
   names/multipliers, 44-point help targets, footer reflow, readable endpoint
   labels and reachable final content. Close/Place/Sell behavior remains intact.

No simulator screenshots, native visual acceptance or successful Xcode build is
claimed by the portable checks.
