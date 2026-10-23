# Movement Forest — native frontend, activity, authentication and visitors

**F6 visitor implementation:** one shared butterfly controller, server sessions,
stored-visit collection, confirmed tokens/hosted counts and account-scoped durable
recovery are implemented. Use [F6_VISITOR_ACCEPTANCE.md](F6_VISITOR_ACCEPTANCE.md)
with your existing account over Tailscale. New F6 native/device acceptance remains
required. The user accepts the earlier B5/F5/F5a tested path; SMTP and Google/Apple
setup/live checks remain deferred. Earlier milestone status notes below are historical.

Native SwiftUI + RealityKit + read-only HealthKit, targeting iPhone on **iOS 16+**.
First physical validation target: iPhone 14 Pro, iOS 26.6.2.

For the detailed first-time Mac walkthrough, start with **[XCODE_SETUP.md](XCODE_SETUP.md)**.
For the current connected test flow, use **[F5A_AUTH_ACCEPTANCE.md](F5A_AUTH_ACCEPTANCE.md)**:
Supabase email/password → Windows backend → Tailscale HTTPS → iPhone → growth/recovery.
Google/Apple can be configured later; both are hidden by default. The old
[F5 guide](F5_ACCEPTANCE.md) remains the explicit development-token fixture path.

**Status:** implemented on Windows. Portable checks and static review are recorded
in `VALIDATION.md`. No claim of a successful Xcode build or device validation is
made until those checks run on a Mac. The code is a reusable frontend foundation;
it is not a complete game or a production release.

## Open on the Mac

1. Copy/clone the **repository**, including `frontend/` and the sibling `assets/`
   folder. Copying `frontend/` alone omits the models.
2. Use Xcode 16.3+ (Swift 6.1+), and a newer version if the phone's iOS requires it. The app's iOS 16 minimum
   does not let an old Xcode deploy to iOS 26.6.2. Check Apple's current matrix:
   https://developer.apple.com/xcode/system-requirements
3. Open `frontend/MovementForest.xcodeproj`. Xcode resolves the pinned
   supabase-swift 2.55.4 Auth product automatically. The project/shared scheme are
   included; do not manually add another SDK copy or regenerate to open it.
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
- **Account (Debug/Release when configured):** Supabase email/password signup,
  confirmation, login, recovery, Keychain session restore and refresh. Conditional
  Google browser/native Apple sign-in and explicit linking. Configure the app in
  ignored `MovementForest/Configuration/Local.xcconfig` from its adjacent example;
  configure backend verification in `backend/.env` using `.env.supabase.example`.
- **Connected garden:** authenticated B3 catalogue/garden/inventory reads,
  planting, moving, rotation, storage, adult previews and durable edit recovery.
  In-app repeat-safe account/starter provisioning. Confirmed
  garden/catalogue/inventory pages are cached for offline viewing.
- **Connected activity:** separate upload opt-in, server-timezone step
  observations, device enrolment/replacement, durable cumulative uploads,
  membership preflight, confirmed growth/attraction, stage updates and recoverable
  recaps. Workouts are local diagnostics; wider reward handlers remain B8.
- **Accessible plant list:** an alternative to selecting models behind foliage.
- **Activity:** optional Health explanation/permission flow; seven calendar days
  of steps and up to 100 recorded workouts in the last 30 days, excluding workouts
  explicitly flagged as manually entered; foreground/manual
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
| `GardenRepository` / `GardenServing` | Explicit sample repository or authenticated `APIGardenRepository`; async identity-bound Supabase token provider; separate API/render DTOs | B6/B8 endpoints |
| `AssetCatalogProviding` | `BundleAssetCatalog` resolves package manifests | Versioned game/asset catalogue and downloaded file resolver |
| `GardenRenderer` | Confirmed growth/stage updates, preserved transforms and separate local drag/adult previews | Cosmetic watering transitions |
| `HealthDataProviding` | `HealthKitService` / fixture provider; separate steps-only upload observation path | Additional supported metrics and observer delivery |
| `GardenEditorStore` / `ActivitySyncCoordinator` | One confirmed garden owner, scoped cache/journals, cumulative step uploads and edit coordination; late detached-account results are ignored | B6/B8 integration |

`GardenSnapshot` is a frontend view model, **not** a frozen backend wire schema.
Its UUIDs, `x`/`y`, degree yaw, catalogue and layout/state versions align with the
spec. `APIOwnedPlant` represents both stored and placed copies. Only the adapter
produces placed rendering models; bundled asset lists never grant ownership.

Supabase sessions are stored in the SDK's project/app-scoped Keychain store.
Access tokens refresh asynchronously and a 401 retries once with the same request
bytes/UUID under the same identity. Logout invalidates old API scopes and hides
private state; saved requests remain partitioned by game account/server. Cached
viewing can survive offline expiry, but queued mutations wait for fresh profile
confirmation. Development-token tooling remains available only in an unconfigured
Debug build with an explicitly development-auth backend.
One unresolved edit per account/server is saved atomically in Application Support
before transmission. Retries reuse identical request bytes and IDs. Pending saves
survive app relaunch and disconnection; uninstalling the app removes its container.
Confirmed garden and its matching catalogue/inventory pages are cached for cold
offline viewing. Unresolved operations and unavailable refreshes block editing.
Release builds support real configured authentication and connected game operations.
An unconfigured build retains the sample experience. Development connection controls
and automatic development-token loading remain disabled in Release.

Health diagnostic reads remain in memory. Connected step uploads require a
separate per-account opt-in. Their immutable request bodies are persisted in
protected, backup-excluded account/server-scoped files before transmission.
The account's server-defined game timezone and B5 baseline/window/device policies
control uploads. Nil observations never become zero. The access-request preference
is not proof of read authorization. Health data is not logged or sent to analytics.

HealthKit statistics provide aggregate step totals. Source totals are not added
together. Nil values remain unavailable/empty, not zero. The workout query excludes
`HKMetadataKeyWasUserEntered = true` before its 100-result limit; false or absent
flags pass this preliminary guard, without proving authenticity. Workout source/UUID
and the mapped manual-entry flag remain in returned observations for diagnostics.
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
- **F5:** source implemented with cached viewing, durable step uploads,
  baseline/device flow and confirmed growth/recaps; native acceptance is pending.
- **F5a:** Supabase session/auth UI and provider/linking source implemented;
  real project credentials, Xcode/XCTest and physical provider/Health acceptance
  remain pending. Email/password can be tested before setting up Google/Apple.
- **F6:** visitor interaction backed by B6 accounting.
- **F7:** Exchange/Catalog/Draws source implemented with durable token-to-pack exchange and server-confirmed openings. Unlocks/milestones and social screens are deferred. Use [F7_COLLECTION_ACCEPTANCE.md](F7_COLLECTION_ACCEPTANCE.md) for server upgrade and device testing.

Background Health delivery, CDN downloads/cache eviction, reward celebrations,
full storage editing and server writes are deliberately outside F1–F3. Device
performance, full minimum-device coverage and App Store preparation remain open.
