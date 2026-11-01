# Stage 3 activity journal — 1 November 2026

Prepared for Mac testing. The user requested committing and pushing this batch
without waiting for CI. No CI result is claimed.

## Completed validation

- Full PostgreSQL backend regression suite: **511 passed, 3 skipped** in 475.93
  seconds. The three skips are the existing opt-in physical-storage benchmarks.
- Focused activity regression suite: **74 passed**, including complete metric
  receipts, saved workout identities/count inputs, idempotent replay, no-water
  recap recovery and late previous-day steps after midnight.
- Portable frontend validation: generated project/source membership, existing
  asset/wire/discovery contracts, journal/rarity contrast and new orange progress
  and text contrast pass. All **77 Swift files** parse without syntax errors.
- Backend Ruff lint/format checks pass. Scoped whitespace validation passes.

Tests used temporary forest_test_* databases in the existing isolated local
validation cluster on port 55483. The cluster was shut down afterward. No live
game database, deployment, asset package or economy configuration was changed.

## Data contract and compatibility

No schema migration is needed. New reward-event/recap JSON includes
activitySummaryVersion: 1, all reconciled activityDays (including their existing
per-metric receipts), and workouts with identity, outcome and newly eligible
minutes. Awarded plant entries also include species/variant identity and their
pinned maximumGrowthMicroUnits, allowing a stable cumulative recap bar even if
the live plant advances later or is absent from the loaded inventory page.

Newly accepted input produces an acknowledgeable recap even for fully grown
plants, an empty garden or an exhausted water cap. This supersedes the older
activity API note limiting visible recaps to positive integer growth. Existing
growth calculations, input caps, duplicate handling, upload queues, saved request
IDs and acknowledgement semantics are unchanged. Repeated totals produce no new
recap. Celebration recipients still require positive awarded plant growth.

The new client decodes older responses without these optional fields. Missing
legacy activity details show New unavailable; no historic workout counts are
invented. The backend update is needed for complete new recap summaries. It
does not backfill immutable historical receipts.

Today is a full local Health read in the game timezone, independently of the
selected recap. It never derives new input by subtracting daily totals. The
daily strip distinguishes unreadable and step-only observations from zero,
refreshes on entry, and checks the displayed calendar date across midnight.
Workout count deduplicates identities and duration clips to today's interval.
Server-eligible new duration retains the server's overlap/cap decisions.

The last confirmed presentation batch is retained after acknowledgement in the
existing protected account/server-scoped activity file. The next successful
recap refresh replaces it. Raw daily Health reports are not persisted by this
feature. Presentation-cache writes are best-effort and do not fail a confirmed
upload or change editing eligibility. Account separation and deletion use the
existing activity-file lifecycle.

## Native gate still required

This Windows machine has no Apple SDK/Xcode. Native compilation, XCTest/UI test
execution, HealthKit/device reads and visual acceptance are **not recorded as
passed**. New native coverage includes midnight separation, rational quantities,
duplicate receipts/workouts, legacy/mixed batches, frozen stage-crossing bars,
adult/unknown growth, step-only data, clipped daily workouts, presentation-cache
relaunch/failure and the horizontal daily-total strip. The existing editor UI
walkthrough also checks that Move/Rotate have no mature-preview switch.

On the Mac, run from the repository root:

    bash frontend/scripts/test-mac.sh

Then review on a small portrait iPhone and at large Dynamic Type:

1. Activity: scroll the top strip through all six metrics. Check zero, positive,
   unavailable, sample and partially readable Health results. Verify normal
   consent, Sync now, queued/offline recovery and reporting-device replacement.
2. Entry popup: Activity recap is explicit; Continue remains reachable. Review
   the same saved new-input batch on Activity after dismissing the popup.
3. After midnight: today's steps may be zero while new accepted steps include
   yesterday. Late Health records and retries must not inflate the new amounts.
4. Plant cards: uniform frames, rarity help, numeric gains, skill contribution,
   stage transitions, orange growth and the fully grown scale. Zero/mature cards
   add no orange. Stored/missing identities remain honest and inspectable by
   accessible labels. VoiceOver reads the complete amounts.
5. Edit: Move and Rotate expose no mature-preview option and never load adult
   art, including stale preview state. Initial placement keeps its prior preview
   behavior. Recheck Cancel, Apply, precise Position and background cancellation.
