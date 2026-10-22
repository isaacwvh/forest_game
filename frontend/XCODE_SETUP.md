# Run Movement Forest in Xcode

For the current Supabase login/game flow, follow **[F5A_AUTH_ACCEPTANCE.md](F5A_AUTH_ACCEPTANCE.md)**
after the signing/pairing steps below. It covers the Windows backend, Tailscale,
email/password configuration, step sync and provider setup. The sample/local-Health
walkthrough below remains useful when testing without a backend.

Start here after pushing from Windows and pulling/cloning the repository onto
the borrowed Mac. Code is prepared for iOS 16+, with your iPhone 14 Pro on
iOS 26.6.2 as the first physical test device. Native compilation and device
behaviour remain to be verified; the Windows checks do not replace them.

## 1. Confirm the files arrived

In Finder, open the repository folder. It should contain:

```text
forest_game/
  frontend/
    MovementForest.xcodeproj/
    MovementForest/
    MovementForestTests/
    MovementForestUITests/
    scripts/
  assets/
    oak/v1/
    moonwillow/v1/
  backend/
```

Each species package needs its JSON manifest, `models/` USDZs and `ui/` PNGs.
The project references those sibling asset folders directly. Do not move only
the frontend into another folder. No backend needs to be started.

Optional Terminal check, replacing the example path with your actual clone:

```bash
cd "/Users/YOUR_MAC_USERNAME/Projects/forest_game"
ls frontend/MovementForest.xcodeproj/project.pbxproj
ls assets/oak/v1/oak.json assets/moonwillow/v1/moonwillow.json
```

All commands below assume Terminal is in this repository root unless stated
otherwise. Finder also lets you navigate without typing the path.

## 2. Prepare Xcode

1. Check the Mac's macOS version from Apple menu > About This Mac.
2. Open Xcode. If it isn't installed, obtain it from the Mac App Store or Apple's
   official developer downloads. Use a stable version compatible with the Mac
   and your phone's installed iOS. Check the current compatibility matrix:
   https://developer.apple.com/xcode/system-requirements
3. Let Xcode finish first-launch setup. Accept its license yourself if prompted
   and allow required components to install. This can take time.
4. If asked which platforms to install, select iOS. For simulator testing, also
   install an iOS Simulator runtime in Xcode > Settings > Components (called
   Platforms in some versions).
5. Keep the phone's OS version separate from the app's deployment target:
   **iOS 16.0 is the app minimum**, not the SDK/Xcode version you should install.

The pinned Supabase Auth dependency requires **Swift 6.1 / Xcode 16.3 or later**.
Use a newer Xcode when needed for your phone. Xcode automatically resolves the
package when opening/building; do not add a duplicate package manually.

The borrowed Mac may already have everything needed. Do not change unrelated
Mac or iCloud accounts to set up the app.

## 3. Open the existing project

1. Double-click `frontend/MovementForest.xcodeproj` in Finder.
2. Open/trust the project if Xcode asks.
3. Wait for indexing to settle.
4. In the top toolbar, choose the **MovementForest** scheme. If necessary,
   use Product > Scheme > MovementForest.

Do not create a new project, run the project generator, install CocoaPods or
add Swift packages. The checked-in project already includes sources, tests,
resources and a shared scheme.

## 4. Configure signing for your phone

1. Open Xcode > Settings > Accounts (some versions label this Apple Accounts).
2. Add **your own Apple Account**. Complete sign-in and two-factor authentication.
3. A free account normally appears as **Your Name (Personal Team)**.
4. Close Settings and select the blue **MovementForest project icon** at the top
   of the left Project navigator. Cmd-1 shows that navigator if hidden.
5. In the editor's **TARGETS** list, select the **MovementForest app target**.
   Select the target, rather than the PROJECT settings or a test target.
6. Open **Signing & Capabilities**.
7. Leave **Automatically manage signing** enabled.
8. Choose your **Personal Team** in Team.
9. Replace the example bundle identifier `com.example.movementforest` with a
   unique identifier, for example `com.isaacwvh.movementforest.prototype`.
   If that identifier is unavailable, choose another unique suffix.
10. Confirm the **HealthKit** capability is present. The project already contains
    its entitlement. Don't enable Clinical Health Records or Background Delivery.
11. Allow Xcode to finish provisioning. Internet access may be needed.

A free account can install for personal testing; no App Store Connect setup or
paid membership is needed for this testing path. Personal Team provisioning
expires after seven days and then requires rebuilding/reinstalling:
https://developer.apple.com/help/account/basics/about-your-developer-account

Local signing choices change `project.pbxproj`. That is expected. The Mac test
script tolerates those edits. Regenerating the project would reset them.

## 5. Pair your iPhone

1. Connect the iPhone 14 Pro using a data-capable USB cable.
2. Unlock it. Accept **Trust This Computer** on the iPhone if prompted and enter
   your passcode. Accept any corresponding accessory prompt on the Mac.
3. In Xcode, open Window > Devices and Simulators. Select your iPhone and wait
   for pairing and any “Preparing device” work to finish.
4. If Xcode requests Developer Mode, on the iPhone open Settings > Privacy &
   Security > Developer Mode. Enable it, restart as instructed, then confirm
   enabling it after restarting. Reconnect/unlock the phone if necessary.
5. If Developer Mode isn't visible yet, pair the phone in Xcode first and check
   again. Apple's instructions are here:
   https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device
6. Choose your **actual iPhone name** in Xcode's run-destination control beside
   the MovementForest scheme. Do not choose “Any iOS Device”.

If an unsupported-device or missing-device-support message appears, verify the
installed Xcode/macOS combination before changing app settings. Lowering the
deployment target does not add support for a newer phone OS to Xcode.

## 6. Build and launch

1. Product > Scheme > Edit Scheme > Run > Info should use **Debug**.
2. Under Run > Arguments, leave `--fixture-health` unchecked/absent for real
   device Health testing. It is only for synthetic data.
3. Press **Cmd-B** to build. The first build may take a while.
4. If Build Succeeded appears, press **Cmd-R** or click the triangular Run button.
5. Keep the phone unlocked while installation finishes. Approve any normal
   development-app verification prompts shown by the phone/Xcode.
6. If the phone explicitly reports an untrusted developer, follow its Settings >
   General > VPN & Device Management instructions to trust your own development
   identity, then launch again.

Expected result: **Movement Forest** opens to a sample garden, with Garden and
Activity tabs. Models may take a moment to load on the first launch. No Health
prompt appears until you choose to connect it.

Try orbiting with one finger, pinching to zoom, panning with two fingers, resetting
the view and opening **Plants**. Tapping a plant or using that list shows details.
The sample garden remains fixed even when real activity is read.

## 7. Test real HealthKit data

1. Open **Activity > Connect Apple Health**.
2. Read the explanation and allow the read types you want to test: steps and
   workouts. The app does not request permission to write Health data.
3. After the prompt finishes, inspect today/recent days and recorded workouts.
4. Compare step totals with the Apple Health app for the same dates. Record any
   difference rather than adjusting totals manually.
5. Walk a little, allow Health to update, then use **Refresh activity** or return
   to the app. Watch/tracker uploads can arrive later.
6. To inspect UUIDs, source and timestamps, open Settings > Developer tools >
   Health diagnostics in the app.

No readable data is a valid result: the data may be absent or not shared. The
app cannot determine read permission conclusively. Change access through the
Health app's profile > Apps/app-access area if required; names vary by iOS.
An ordinary walk/run recorded as steps does not necessarily create a workout.
A compatible tracker must have saved a recorded workout into Health for it to
appear. Synthetic fixtures cannot establish real-device workout feasibility.

## 8. Inspect rendering

In the Debug app, open **Settings > Developer tools**:

- **Asset inspector:** select every species, variant and stage. Check materials,
  ground contact, relative sizes and wind. There are 20 delivered combinations.
- **Garden scenes:** test the mixed, mature, sprout and adult Moonwillow stress
  presets. Ground-picking mode should find the board beneath foliage.
- **Sample/empty/failure activity screens:** exercise UI states independently of
  your Health records.

Also test Reduce Motion, Dark Mode and a large text size. Use
`MAC_TEST_CHECKLIST.md` for the complete acceptance list. Developer tools are
excluded from Release builds.

## 9. Run automated tests on the Mac

For a straightforward Xcode test run:

1. Select an available **iPhone simulator** as the run destination.
2. Choose Product > Test, or press **Cmd-U**.
3. Tests use synthetic activity and do not require personal Health data.
4. View results in Xcode's Test navigator or Report navigator.

For the complete command-line check, open Terminal at the repository root:

```bash
bash frontend/scripts/test-mac.sh
```

This checks resources/plists, runs Debug unit/UI tests on an installed iPhone
simulator, then builds Release. It requires `python3`; check `python3 --version`.
If missing, install Python 3 from https://www.python.org/downloads/macos/ or use
the Xcode test run first. Python is a validation tool, not an app dependency.

If Terminal reports that the active developer directory is only Command Line
Tools, open Xcode > Settings > Locations and select your installed Xcode under
Command Line Tools. Then rerun the script. Use `xcodebuild -version` to confirm.

To choose a specific simulator:

```bash
xcrun simctl list devices available
bash frontend/scripts/test-mac.sh PASTE_SIMULATOR_UDID_HERE
```

For manual synthetic activity in Simulator, Product > Scheme > Edit Scheme >
Run > Arguments > Arguments Passed On Launch: add `--fixture-health`. Optionally
add `--empty-health` or `--failed-health`. Uncheck these before real Health tests.

## 10. Troubleshooting and preserving results

| Problem | What to do |
| --- | --- |
| Signing requires a development team | Select the app target's Signing & Capabilities and your Personal Team. |
| Bundle identifier unavailable | Choose a different unique identifier. |
| iPhone absent | Check cable/trust/unlock, Devices and Simulators, and Developer Mode. |
| No iPhone simulator | Install an iOS Simulator runtime in Xcode Settings, then select a device. |
| Missing oak/Moonwillow resource | Confirm root `assets/` was committed and pulled, with the folder structure intact. |
| `No such module` for Apple frameworks | Confirm the app target and iOS destination; do not compile the Swift files as a standalone script. |
| Compiler error | Cmd-5 opens Issue navigator. Copy the first full error with file/line and record Xcode/macOS versions. Avoid changing many settings at once. |
| App closes immediately | Rerun with Xcode attached; capture the exception/error from the debug console. |
| No Health results | Confirm records exist in Health and review shared access. Test empty states without assuming denial. |
| Plant loading warning | Open its details/reload action; record the exact file/error and inspect it with Asset Inspector. |
| App stops opening after a week | Reconnect and rebuild/reinstall; free signing has expired. |

Record build/test results in `MAC_TEST_CHECKLIST.md`. Keep personal Health
screenshots and payloads out of commits. Before returning the borrowed Mac,
remove your Apple Account from **Xcode's account settings** if you added it;
you do not need to sign the Mac owner's iCloud account out. Leave the app on your
phone for follow-up testing.
