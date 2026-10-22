# First Mac / iPhone session

Record: Mac model ____ / macOS ____ / Xcode ____ / simulator ____ / iPhone OS ____.
Target device: iPhone 14 Pro running iOS 26.6.2. No paid membership is assumed.

## Preflight and build

- [ ] Mac runs a compatible Xcode for the phone OS; an iOS simulator runtime is installed.
- [ ] Full repository is present; `assets/oak/v1` and `assets/moonwillow/v1` exist.
- [ ] Open `frontend/MovementForest.xcodeproj`; choose MovementForest scheme.
- [ ] Select own Personal Team, automatic signing and unique app bundle ID.
- [ ] Connect/trust/unlock the iPhone and enable Developer Mode if prompted.
- [ ] Build and run on device. Save any compile errors verbatim for correction.
- [ ] Run `bash frontend/scripts/test-mac.sh`; both Debug tests and Release build pass.

If Xcode reports a signing conflict, confirm that the app ID is unique and that
the HealthKit capability is present. Do not remove HealthKit merely to claim F3
passed. If Xcode cannot support the installed phone OS, update the compatible
toolchain or use another Mac; changing the deployment target won't resolve it.

## F1 — first garden

- [ ] Launch with no Health access; garden and Plants list remain usable.
- [ ] Garden loads all 15 sample plants without asset errors.
- [ ] Materials match the delivered art; no missing textures or detached parts.
- [ ] Roots meet the shared surface; sprouts are not buried or floating.
- [ ] Plant details show the correct species, variant and four-stage label.
- [ ] Closing/reopening restores the same sample layout. No fabricated reward appears.

## F3 — real Health data (do this early)

- [ ] Activity > Connect Apple Health shows only steps/workouts read requests.
- [ ] Garden remains usable if all or some Health types are not shared.
- [ ] Empty results say “No readable data”; they do not claim permission was denied.
- [ ] With access enabled and existing steps, compare today and recent days with Health.
- [ ] Record any total differences, source combinations and timezone used; don't sum source totals to “fix” them.
- [ ] Take a short walk, reopen/refresh, and observe a changed total when Health has updated.
- [ ] An existing recorded run appears as Running with stable UUID/source in diagnostics.
- [ ] Add a manual workout in Health/Fitness: it does not appear in the game's workout read. A normally recorded workout still appears. False/missing manual-entry flags pass this guard; this is not workout authenticity verification.
- [ ] With a test Health store containing more than 100 newer flagged manual workouts, an older recorded workout in the 30-day window still appears (the exclusion runs before the query limit). An all-manual window displays the normal empty state, not a permission error.
- [ ] If no recorded run exists, record one with your normal compatible tracker and wait for it to appear in Health first. Ordinary phone steps alone do not create a workout.
- [ ] Refresh twice: observation lists/totals replace previous results rather than accumulating.
- [ ] Revoke a type in Health, refresh, and confirm the UI does not retain stale values as current after a successful empty query.
- [ ] Background/lock/unlock/return: failures are recoverable and no permanent loading spinner remains.
- [ ] If using Watch or a third-party tracker, test delayed sync and overlapping sources when available.
- [ ] No activity advances sample plants or awards tickets.

No available real workout means workout feasibility is **pending**, even if the
synthetic screen works. Full delayed-sync and multi-source testing can require
another session.

## F2 — rendering and interactions

Open Settings > Developer tools in the Debug build.

- [ ] Asset Inspector: check all **20** species/stage/variant combinations.
- [ ] Verify ground contact, materials, scale and named wind motion for each.
- [ ] Stage changes keep the anchor fixed and preserve relative authored sizes.
- [ ] Watch each species/stage for at least two five-second loops; check root stability and loop seams.
- [ ] Bounds guides agree with rotated/asymmetric plants. Guides are not clearance.
- [ ] Orbit, pinch, two-finger pan and Reset camera are responsive and bounded.
- [ ] Ground-picking mode reports the board point beneath tree canopies, not leaf height.
- [ ] Run all five scene presets, including 15 mature trees and 15 adult Moonwillows.
- [ ] Use Instruments to record FPS/frame time, CPU/GPU load, memory and thermal behaviour on device.
- [ ] Repeat scene changes and leave/reenter tools; memory settles, animations restart correctly and no hidden view keeps animated work running.
- [ ] Test at least a 10-minute session with gestures and repeated scene changes.

The scene-update interval shown in tools is diagnostic timing, **not GPU frame
time**. Do not infer a minimum-device performance guarantee from this iPhone.

## Native usability

- [ ] Test light/dark appearance, portrait/landscape and a large accessibility text size.
- [ ] Buttons remain reachable, text readable and controls clear of Dynamic Island/home indicator.
- [ ] VoiceOver can navigate tabs, activity controls, the Plants list and plant details.
- [ ] Turn on Reduce Motion before launch: wind stays paused, including during loading.
- [ ] Toggle Reduce Motion while running; wind responds without moving plant anchors.
- [ ] Switch tabs, open/dismiss Settings/details, background and reopen; the garden resumes cleanly.
- [ ] Test an older supported simulator if its runtime is available. Record versions actually tested.
- [ ] Capture native screenshots of garden, plant details, Activity and an empty state in both appearances.

## Handoff record

| Check | Device / OS | Result | Evidence / issue |
| --- | --- | --- | --- |
| Debug build + tests | | Pending | |
| Release build | | Pending | |
| All 20 assets | | Pending | |
| Camera / ground picking | | Pending | |
| Mature stress scene | | Pending | |
| Real steps | | Pending | |
| Real recorded running workout | | Pending | |
| Empty / revoked / unavailable | | Pending | |
| Lifecycle / Reduce Motion | | Pending | |
| Accessibility / appearances | | Pending | |

Keep the app installed for follow-up observations. Free Personal Team signing
expires after seven days, after which it needs rebuilding/reinstallation.

## F5 connected acceptance

Follow [F5_ACCEPTANCE.md](F5_ACCEPTANCE.md) for the current backend/Tailscale flow.
Record native results, including Xcode/OS versions, there. The earlier checklist
above also applies to rendering, accessibility and local Health diagnostics.
