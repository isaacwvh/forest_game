# Stage 1A–1C validation — 31 October 2026

**Native build/visual acceptance is pending.** This records local validation
completed before publishing the change. The user subsequently requested a
commit/push for Mac testing without waiting for CI. No live game database or
running API was changed; no CI result is claimed here.

## Executed and passed

- Complete PostgreSQL suite: **508 passed, 3 skipped in 505.44 seconds**.
  The skips are the existing opt-in physical-storage benchmark cohorts, not UI or
  gameplay regression failures.
- Four new descriptive-copy tests also passed independently: preview changes
  nothing; apply changes only two existing description fields; repeat application
  is a no-op; missing species refuse partial updates; fresh publication/API reads
  include approved copy. The apply test compares every table's contents and
  allows differences only in the two description values.
- All four real HTTP walkthroughs: activity, Sleeping Dew, launch/rescale/restart
  recovery and visitor/collection. The visitor pacing model also passed.
  No synthetic fixtures were re-exported by these runs.
- Portable frontend validation: generated project/current source membership,
  existing asset and wire contracts, discovery isolation, all five new ornaments'
  dimensions/alpha/checksums, matching bundled/server descriptive text, actual
  journal text/action/frame contrast and existing rarity text contrast.
- **74 Swift source files** parsed without syntax errors, including the new
  presentation helper and five new native unit tests. This is not Apple SDK
  compilation or XCTest execution.
- Ruff check and format across the backend: all checks pass, 100 files formatted.
  Python compilation, installed dependency consistency and diff whitespace pass.
- A task-start hash comparison verifies **39 protected source files unchanged**:
  gameplay services/models, rendering, activity recap and pack-opening code.
  Existing root specification/planning edits from other work remain untouched.

Tests used a dedicated temporary PostgreSQL 17 cluster under the ignored
backend/.local-postgres/stage1-ui-validation directory. Test databases had random
forest_test_* names and were dropped; the cluster was shut down after each run.
No game/Supabase database, account, growth, balance, placement, rule, pending
request or discovery record was changed by validation.

## Native gate still required

This Windows host has no Xcode, Apple SDK or iPhone simulator. The following are
**not recorded as passed**:

- Apple SDK typecheck/build of Debug, public Release and InternalRelease.
- Native XCTest/UI, including icon-hold navigation isolation, catalog browsing,
  inspector dismissal and the existing Storage → Place regression.
- Native screenshots compared with the approved four-screen concept set.
- VoiceOver, Dynamic Type, transparent modal fallback on iOS 16.0–16.3, compact
  popovers on iOS 16.4+, touch interaction, image cache/performance and device review.

Run the existing local Mac gate and [device walkthrough](STAGE1_UI_ACCEPTANCE.md)
before accepting the appearance or starting the next UI batch:

    bash frontend/scripts/test-mac.sh

The Docker engine was inaccessible/unresponsive from this environment; no
application-image build or deployment is claimed. The Dockerfile and dependency
lock were unchanged. Backend source was exercised directly in the full suite and
the four HTTP walkthroughs.

## Descriptive copy and deployment

The running local game database could not be reached for the read-only preview,
so no live description update was applied. The native bundle contains the exact
approved Oak/Moonwillow copy as a catalog-only fallback for blank/legacy metadata;
authored server descriptions take precedence. The copied text never appears in
owned inspection.

The optional preview-first description command updates existing text columns
only. No schema migration or balance publication is required. Fresh catalog
publications use the approved strings. See the acceptance guide for the command.

## Scope

My plants and Catalog grids, the shared inset inspector, icon explanations,
rarity/typography/palette/ornaments, catalog description order, and corresponding
presentation tests/resources are changed. Existing detail entry points are
adapted to the modal; Storage/Garden list layouts are deliberately deferred.
The placement operation/guard and all service/model/recovery logic are retained.
Recap, Garden/Edit styling, economy pages, settings/account redesigns and social/
weather features are outside this batch.
