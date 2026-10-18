# Movement Forest — frontend baseline

Native SwiftUI + RealityKit + read-only HealthKit, targeting iPhone on **iOS 16+**.
First physical validation target: iPhone 14 Pro, iOS 26.6.2.

For the detailed first-time Mac walkthrough, start with **[XCODE_SETUP.md](XCODE_SETUP.md)**.

**Status:** implemented on Windows. Portable checks and static review are recorded
in `VALIDATION.md`. No claim of a successful Xcode build or device validation is
made until those checks run on a Mac. The code is a reusable frontend foundation;
it is not a complete game or a production release.

## Open on the Mac

1. Copy/clone the **repository**, including `frontend/` and the sibling `assets/`
   folder. Copying `frontend/` alone omits the models.
2. Use Xcode that supports the phone's installed iOS. The app's iOS 16 minimum
   does not let an old Xcode deploy to iOS 26.6.2. Check Apple's current matrix:
   https://developer.apple.com/xcode/system-requirements
3. Open `frontend/MovementForest.xcodeproj`. No package manager or project
   generator is needed. The project and shared scheme are included.
4. In Xcode Settings > Accounts, sign in with your own Apple Account. Select
   the **MovementForest app target > Signing & Capabilities**, choose your
   Personal Team and keep automatic signing enabled. Change the example bundle
   ID to a unique ID, such as `com.yourname.movementforest`.
5. Connect your unlocked iPhone, trust the Mac, and enable Developer Mode when
   prompted. Select your iPhone as the run destination, then Run (Cmd-R).
6. Follow `MAC_TEST_CHECKLIST.md`, especially the real HealthKit check early in
   the session. A simulator does not validate personal Health data.

Apple lists HealthKit as available to free Apple developers. Personal Team
installations expire after seven days and require rebuilding/reinstalling.
TestFlight is not part of this free-account workflow.

- https://developer.apple.com/help/account/reference/supported-capabilities-ios
- https://developer.apple.com/help/account/basics/about-your-developer-account

No team ID, credentials, API key, backend, Apple Watch app, camera access or
location permission is required by this baseline. An existing recorded workout
in Health is enough to test workout reads. Phone steps do not imply a workout.

## What runs

- **Garden:** a stable 15-plant sample, continuous board coordinates, shared
  temporary ground, orbit/pan/zoom, camera reset, plant selection and details.
- **Accessible plant list:** an alternative to selecting models behind foliage.
- **Activity:** optional Health explanation/permission flow; seven calendar days
  of steps and up to 100 recorded workouts in the last 30 days; foreground/manual
  refresh and empty/error/unavailable states.
- **Settings:** explains data handling. Debug builds additionally expose Asset
  Inspector, scene presets, Health diagnostics and synthetic activity scenarios.
- **Assets:** all 20 delivered USDZs and PNGs are bundled directly from the root
  packages. Models load asynchronously, checksums are verified off the main
  thread, cached templates are cloned, and wind respects Reduce Motion.

The sample banner remains visible: real Health observations do **not** change
sample plants. No growth thresholds, rarity odds, rewards or clearance radii are
invented. Asset versions are pinned to the delivered `1.0.0` packages.

## Architecture and extension points

| Boundary | Current implementation | Later implementation |
| --- | --- | --- |
| `GardenRepository` | `SampleGardenRepository` reads a bundled fixture | API repository maps confirmed DTOs to `GardenSnapshot` |
| `AssetCatalogProviding` | `BundleAssetCatalog` resolves package manifests | Versioned game/asset catalogue and downloaded file resolver |
| `GardenRenderer` | `RealityGardenRenderer` | Reuse for F4 editing and F5 confirmed state updates |
| `HealthDataProviding` | `HealthKitService` / fixture provider | Reuse reads under a durable activity-sync coordinator |
| `GardenStore` / `ActivityStore` | Observable screen state | Add cached confirmed state and sync status |

`GardenSnapshot` is a frontend view model, **not** a frozen backend wire schema.
Its UUIDs, `x`/`y`, degree yaw, catalogue and layout/state versions align with the
spec. Keep API decoding/mapping in the repository when FastAPI is ready.
The model currently represents placed plants only; F4 adds owned inventory and
editing commands without turning catalogue assets into individual ownership.

Health observations are kept in memory. The only persisted Health-related value
is whether the user attempted the access request; this is never treated as proof
of read authorization. No health data is uploaded, logged or added to analytics.
The timezone is captured for the current app session. F5 must replace this with
the account's server-defined game timezone, baseline and backfill policy.

HealthKit statistics provide aggregate step totals. Source totals are not added
together. Nil values remain unavailable/empty, not zero. Workout source/UUID and
manual-entry metadata are retained for diagnostics and later eligibility rules.
Reward deduplication, corrections and authorization enforcement belong to the
backend. Historical diagnostic reads grant nothing.

## Rendering conventions

- Logical ground `(x, y)` maps to world `(x × unitMetres, 0, y × unitMetres)`.
- Models keep their metre dimensions. Do not independently normalize them to
  a common height; camera framing is separate from model scale.
- A fixed placement parent owns identity/position/yaw. The visual child contains
  the model and wind rig. Stage inspection keeps the same placement.
- The loader compares imported and authored dimensions to detect whether the
  importer already adapted Z-up. It corrects only a Z-up result. This heuristic
  must be visually verified against every delivered model on the Mac/iPhone.
- Bounds guides are visual foliage envelopes. They are not gameplay clearance.
- A yellow square marks selection; it does not communicate a reserved radius.
- The temporary board can be replaced inside `makeBoard` while retaining a top
  surface at world Y=0 and the same logical coordinate mapping.
- Fifteen plants is a scene fixture, not an enforced active-plant limit.

## Development and tests

Windows, no extra dependencies:

```powershell
python frontend/scripts/validate_frontend.py
```

After adding or removing Swift files, regenerate the checked-in project:

```powershell
python frontend/scripts/generate_project.py
```

The generator rewrites the project, including example signing settings. Preserve
local signing choices separately or reselect your team after regenerating. Do
not regenerate merely to open the project on the Mac.

On macOS, with an iPhone simulator installed:

```bash
bash frontend/scripts/test-mac.sh
# Optional: choose a simulator explicitly
bash frontend/scripts/test-mac.sh SIMULATOR_UDID
```

The script validates plists/resources, runs Debug unit/UI tests, and builds
Release to check the configuration without developer screens. UI tests use
synthetic activity and never request real Health access. For manual simulator
testing, set the Run scheme argument `--fixture-health`; optionally also use
`--empty-health` or `--failed-health`. These switches exist only in Debug.

`.github/workflows/frontend.yml` runs the same Mac checks on GitHub after a push.
This session does not push commits or run remote CI automatically.

Unit tests cover asset resolution, stable scene identities, coordinates, axis
conversion decisions, stage placement preservation, DST day boundaries and
Health state semantics. They do not certify RealityKit rendering or HealthKit's
device aggregation. Inspect both separately.

## Subsequent milestones

- **F4:** owned inventory, editor input modes, exact shared clearance validation,
  adult previews and pending edit state. Reuse the renderer/camera/ground ray.
- **F5:** managed login, API repositories, cached viewing, durable retry queue,
  baseline and cumulative observations, confirmed growth/stage changes.
- **F6:** packet collection and social screens backed by confirmed API results.

Background Health delivery, CDN downloads/cache eviction, reward celebrations,
full storage editing and server writes are deliberately outside F1–F3. Device
performance, full minimum-device coverage and App Store preparation remain open.
