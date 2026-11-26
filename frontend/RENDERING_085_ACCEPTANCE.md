# Fixed 0.85 garden rendering and recurring-work follow-up

26 November 2026. Based on integrated branch commit 465d407.

## Behavior

- The RealityKit viewport uses 0.85 times its display's native scale. Reattachment
  and display-scale changes recalculate from the display scale, so the multiplier
  never compounds. View bounds, camera coordinates and SwiftUI text resolution
  are unchanged. No frame-rate switching or additional rendering clock is added.
- Normal/fair thermal conditions retain the original lighting, shadows, wind
  and effect budgets. Serious/critical thermal pressure or Low Power Mode omits
  the directional shadow pass, pauses optional plant/item wind, and uses opaque
  parchment for Home control backgrounds. Butterfly motion, taps and expiry
  retain their existing timing and Reduce Motion behavior.
- Conserving mode limits newly started growth reveals to three concurrent effects
  and six particles each (normal: six and twelve). Already-running reveals finish;
  queued stage replacements are retained. Normal effects resume after thirty
  continuous seconds without serious/critical pressure or Low Power Mode.
- A single process-wide notification owner manages thermal/power state and one
  cancellable cooldown task. Renderer subscriptions are cancelled on disposal.
- Root navigation observes a coalesced routing/attention projection. Leaf HUDs
  and pages retain direct store observation; selection, preview changes, routine
  heartbeat publications and shop countdowns do not invalidate the whole root
  unless navigation, entry eligibility or a badge actually changes.
- Editor rendering snapshots are cached and invalidated by draft, catalogue,
  confirmed garden, fallback render or editing-state changes. Selection and
  candidate previews reuse the snapshot.
- Decoded presentation images share an NSCache with a 24 MiB cost target and
  48-entry limit, keyed by resolved resource and requested pixel size. Memory
  warnings clear that cache.
- Inactive visitor ticks with no read/recovery/session-ending work return before
  publishing busy changes. Eligibility transitions and durable recovery still
  follow the original protocol and heartbeat schedule.

No artwork, LOD assets, model hierarchy, collision shapes, reward rules, API
contracts or backend code changed. This increment needs an iPhone rebuild/install;
it does not require backend redeployment or database migration.

## Passed here

- Portable frontend validator: 188 USDZ packages/checksums/archives and matching
  thumbnails, fixtures, artwork, schemes and 90 app-source project references.
- All 124 app/native-test/UI-test Swift files passed syntax parsing.
- Generated-project consistency, canonical catalogue/index bytes and whitespace.
- Swift 6.1.3 Linux XCTest: 36 actual visitor scenarios plus the render-policy test
  (17 shared assertions), all 37 tests passed. Includes inactive tick behavior,
  fixed scaling, thermal pressure, cooldown reset and recovery.
- Swift 6.1.3 Linux XCTest: all 22 editor/collection/strategy scenarios passed,
  including editor-cache reuse, draft/undo/refresh invalidation and prior recovery.
- Existing shared Swift checks: 44 auth, 20 Home, 170 selection assertions,
  92 strategy calculations plus draft/action-impact checks, and expedition
  model/coordinator/HTTP contracts passed.

Linux suites run actual production logic and extracted native assertions with
platform interfaces. They do not compile UIKit, SwiftUI, Combine or RealityKit.
No backend regression run is claimed or required for this frontend-only increment.
CI is intentionally skipped.

## Native validation still required

This Windows host has no Xcode/Apple SDK. Native XCTest/UI, Debug/Release/
InternalRelease builds and device heat/FPS measurements have not run here.
New native tests cover fixed scale across view mounts, image cache reuse and
memory-pressure eviction, filtered root observation, and completion of every
queued growth replacement under the constrained budget. Existing camera-ray,
visitor tap/accessibility and model reuse tests now exercise the 0.85 viewport.

On the Mac, run:

    bash frontend/scripts/test-mac.sh

On iPhone, compare at least ten minutes of standalone Release gameplay against
465d407 with the same garden, brightness and charging conditions. Measure actual
rendered FPS/frame pacing, CPU/GPU time, memory and thermal state using Instruments.
Check camera gestures, overlapping plant/item selection and visitor taps at all
zoom levels; navigation, entry/level-up blockers and reward badges; draft previews,
Undo/Redo/Save; and VoiceOver/Reduce Motion/Reduce Transparency.

Toggle Low Power Mode and verify optional effects change, visitor behavior remains
correct, and normal effects return after the continuous thirty-second cooldown.
Performance improvement and visual acceptance remain unmeasured until these device
checks run; portable validation is not proof of lower power use.
