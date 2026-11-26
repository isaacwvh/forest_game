# Client recurring-work optimizations — 26 November 2026

The integrated branch also retains the request-latency changes from
`codex/request-latency`. See [merge provenance and local validation](INTEGRATED_PERFORMANCE_VALIDATION.md)
before making another branch or rebuilding the app. The original rendering branch
and latency branch independently descended from `main`; both feature sets must
be present in the installed build.

This is a frontend-only change. Rebuild/install the iPhone app; no backend
redeployment, database migration, API change or visitor-rule publication is needed.
Artwork, rendering quality, frame rate, flight paths, wind and reward rules are
unchanged. Device heat/frame-rate improvement has not been measured on this host.

## Implemented

- Loaded 3D butterflies have no SwiftUI flight timelines or invisible projected
  buttons. RealityKit keeps movement, current-frame taps and native accessibility.
  Loading, failed-artwork fallback and standalone 2D flight retain their behavior.
- Moving accessibility geometry is refreshed at up to 10 Hz while VoiceOver or
  Switch Control needs motion updates. Identity/reward/viewport changes, camera
  changes and overlay changes refresh immediately. Native accessibility queries
  also refresh current geometry, preserving automation and other accessibility
  clients without unconditional per-frame bounds/projection work.
- Frame timing has a separate observable metrics owner and diagnostic row. Its
  periodic publication does not invalidate the gameplay renderer/session/screen.
- Visitor flight height is cached when installed plant diagnostics change. One
  visible-opportunity list is reused for each render/accessibility update.
- Visitor journal reads, validation, encoding, writes and removal run on one
  serial utility queue. Restoration is coalesced before requests can proceed.
  Coordinator write transitions remain serialized across suspension, so a queued
  tap cannot be discarded by heartbeat completion. Original UUIDs/body bytes,
  atomic protected files, account/server partitioning and quiet recovery remain.

## Executed local validation

- Full portable frontend validator: 188 USDZs/checksums/archives and matching
  thumbnails, resources, fixtures, plist/scheme and project membership checks.
- Swift syntax parser: all 119 app/test/UI-test source files.
- Deterministic generated Xcode project check and diff whitespace check.
- Swift 6.1.3 Linux XCTest: 35 visitor scenarios using actual coordinator, models,
  journal, account disk implementation and extracted native tests. Only platform
  observation/logging and CryptoKit hashing interfaces are substituted. Cases
  cover suspended restoration/writes, queued tap/heartbeat ordering, failed saves,
  detachment, original-byte replay, legacy files and account/server isolation.
- Existing portable Swift suites: 44 auth checks, 20 Home checks, 170 selection
  assertions, 92 strategy calculation cases plus draft/action-impact checks, and
  expedition model/coordinator/HTTP-contract checks with platform interfaces.
- The strategy-store validation helper now extracts only its required garden
  cache type, avoiding unrelated account-bootstrap/auth dependencies.

The pre-existing catalogue manifest had the wrong byte count/hash for Git's LF
blob. Its already-present LF/manifest correction is a separate prerequisite to
clean-checkout validation; descriptions and gameplay content are unchanged.

## Native validation still required

No Xcode/Apple SDK is available on this Windows host. Apple SDK compilation,
native XCTest/UI tests and physical-device performance/VoiceOver checks have not
been executed. Frontend CI is intentionally skipped at the user's request.

Native regressions were added for no fallback flight frames after model readiness,
bounded accessibility motion/on-demand queries, isolated timing notifications and
flight-height cache invalidation. Existing camera/tap/accessibility, delayed import,
fallback motion/expiry and request-recovery cases remain in the native suite.

On a Mac, run `bash frontend/scripts/test-mac.sh`. On iPhone, test normal taps,
camera gestures, artwork fallback and Reduce Motion; enable VoiceOver/Switch
Control and check moving visitors, control occlusion and activation. Compare a
ten-minute Release session with a similar mature garden before/after, recording
CPU/GPU load, frame pacing, memory and thermal state with Instruments.

## Repeat portable visitor checks

Run `python frontend/scripts/prepare_performance_validation.py`, then run
`swift test` in `frontend/.validation-tools/performance` with `VISITOR_FIXTURE`
set to the absolute path of
`frontend/MovementForest/Resources/Fixtures/visitor-contract.json`.
This suite does not substitute for an iOS build or native rendering acceptance.
