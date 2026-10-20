# Movement Forest — native frontend and connected F4 editor

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
- **Connected garden (Debug):** authenticated B3 catalogue/garden/inventory reads,
  planting, moving, rotation, storage, adult previews and durable edit recovery.
  See [F4_ACCEPTANCE.md](F4_ACCEPTANCE.md) for connection and database checks.
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
| `GardenRepository` / `GardenServing` | Explicit sample repository or authenticated `APIGardenRepository`; separate API DTOs map to render models | Managed-login token provider and activity sync |
| `AssetCatalogProviding` | `BundleAssetCatalog` resolves package manifests | Versioned game/asset catalogue and downloaded file resolver |
| `GardenRenderer` | Incremental confirmed updates and separate local drag/adult previews | F5 confirmed growth/stage updates |
| `HealthDataProviding` | `HealthKitService` / fixture provider | Reuse reads under a durable activity-sync coordinator |
| `GardenEditorStore` / `ActivityStore` | Confirmed garden, inventory, local candidate and durable pending request; independent local Health reads | Cached viewing and durable activity uploads |

`GardenSnapshot` is a frontend view model, **not** a frozen backend wire schema.
Its UUIDs, `x`/`y`, degree yaw, catalogue and layout/state versions align with the
spec. `APIOwnedPlant` represents both stored and placed copies. Only the adapter
produces placed rendering models; bundled asset lists never grant ownership.

Development API addresses are saved in preferences and bearer tokens in Keychain.
One unresolved edit per account/server is saved atomically in Application Support
before transmission. Retries reuse identical request bytes and IDs. Pending saves
survive app relaunch and disconnection; uninstalling the app removes its container.
Other confirmed garden/inventory data remains in memory, so a cold offline launch
does not offer editable cached state. Release builds retain the sample experience;
development connection controls and automatic development-token loading are disabled.

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

Unit tests cover API mapping/encoding, shared exact geometry, pending-edit
recovery, token replacement, conflicts, pagination, renderer entity reuse,
asset resolution, DST day boundaries and Health state semantics. They require
Xcode to execute. Portable parsing does not certify Apple SDK typechecking,
RealityKit rendering or HealthKit device aggregation.

## Subsequent milestones

- **F4:** source implemented; native build, tests and live device acceptance pending.
- **F5:** managed login, cached viewing, durable activity uploads,
  baseline and cumulative observations, confirmed growth/stage changes.
- **F6:** visitor interaction backed by B6 accounting.
- **F7:** collection economy and social screens backed by confirmed API results.

Background Health delivery, CDN downloads/cache eviction, reward celebrations,
full storage editing and server writes are deliberately outside F1–F3. Device
performance, full minimum-device coverage and App Store preparation remain open.
