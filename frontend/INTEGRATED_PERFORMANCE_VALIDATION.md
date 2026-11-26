# Request latency and recurring client work integration

26 November 2026. The integration combines `codex/request-latency` at `8b3d80f`
(including `9cc8a74` and the `7a8d926` recovery follow-up) with
`codex/frontend-performance-20261126` at `d532b73`.

The branches independently descended from `c5760ec`; the frontend performance
branch did not inherit the latency branch. The merge preserves the published
snapshot/receipt/signature contracts, catalogue reuse, and the newer visitor
rendering, timing, accessibility and asynchronous journal changes. The only Git
conflict was a comment in `prepare_strategy_validation.py`; the bounded garden
cache extraction and its explanatory comment are retained.

Backend files match the latency branch. Core request implementations match that
branch, and the rendering/visitor implementations match the frontend performance
branch. No production service, database, configuration or schedule was changed.
The original workspace's 39 modified tracked files were verified byte-for-byte
unchanged while integration was performed in a separate worktree.

## Frontend checks

- Portable resources: 188 USDZ packages and matching thumbnails, archives,
  checksums, fixtures, artwork, schemes and project membership passed.
- Canonical catalogue working-tree/index bytes and generated Xcode project passed.
- All 119 application/native-test/UI-test Swift files passed syntax parsing.
- Swift 6.1.3 Linux checks passed: 44 auth checks, 20 Home checks, 170 selection
  assertions, 92 strategy cases including reversed input order, draft persistence
  and action-impact cases, and expedition models/coordinator/HTTP contracts.
- All 35 extracted visitor XCTest scenarios passed, including suspended disk
  writes, heartbeat/tap ordering, durable replay and account/server isolation.
- All 21 extracted request/recovery/strategy XCTest scenarios passed. They cover snapshot
  reuse, no post-save read for fresh receipts, signature validation without a
  preview request, initial snapshot reuse, cacheless journal recovery, capacity
  preservation, activity preflight, catalogue invalidation, durable collection
  replay, persistence failures, account isolation and all five native strategy
  cases. Two stale native assertions were reproduced and corrected: the reference
  fixture contains 92 cases, and the published skill name is `Afterglow Reserve`.
  Its activity and offline-capacity components are still asserted separately.

`prepare_request_validation.py` extracts existing native assertions and the
actual wire models, editor/collection coordinators and disk implementation.
Observation, logging, effects, asset resolution and OS hashing use interfaces;
these checks do not validate Apple frameworks, artwork resolution or rendering.

To repeat the request checks with a Linux Swift 6.1.3 toolchain:

```bash
python frontend/scripts/prepare_request_validation.py
export FOREST_FIXTURES="$(pwd)/frontend/MovementForest/Resources/Fixtures"
cd frontend/.validation-tools/integration
swift test -j 2
```

## Backend checks

Backend lint, formatting and dependency consistency passed. The four disposable
database HTTP walkthroughs (activity, skills, launch and visitors), visitor pacing
simulation, local image build and image smoke passed. The image smoke covers
migrations/grants, restricted runtime permissions, API/worker separation,
maintenance and a verified backup/restore of 95 tables.

The full PostgreSQL suite passed: **856 passed, 3 skipped**, in 664.55 seconds.
The three skips are the explicitly opt-in physical storage benchmarks. All tests
used a new local PostgreSQL 17 container and randomly named disposable databases;
no hosted database or real player state was used.

## Native acceptance

No Xcode/Apple SDK is installed on this Windows host. Native XCTest/UI tests,
Debug/Release/InternalRelease builds and physical-device performance remain
unexecuted here. CI was not started or awaited for this merge.

On a Mac, run `bash frontend/scripts/test-mac.sh`, then rebuild/install this
integrated branch over the existing iPhone app. The hosted backend already
supports the restored client contracts; this frontend integration does not
require another backend deployment or schema migration.
