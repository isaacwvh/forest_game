# F8.1 first-release polish acceptance

Source implementation: 26 October 2026. Native execution and device results must
be recorded separately; portable parsing is not Apple SDK compilation.

## Lifecycle follow-up — source implemented, iPhone acceptance pending

**First-return / butterfly retest:** after this follow-up, repeat a 35–45-second
absence and return without opening Notification/Control Centre or tapping the
screen. The recap must appear on that first return. Dismiss it, then briefly open
Notification Centre: no second recap. Repeat from Garden, Activity and Packs with
no existing blocking flow. Manual Sync now must remain quiet. Force-close and
launch again to check startup artwork: the model is preloaded during connection,
and any remaining import shows Loading butterfly rather than an old butterfly.
The actual model must replace loading without a tap, resize, recap dismissal or
another app switch. Welcome visitor remains usable during the import. An actual
asset failure still shows its explicit recovery message/fallback.

Use the existing installation and account; do not uninstall, clear queues or
reset Health consent. No backend migration or balance change is needed. Copy the
updated frontend source and Xcode project to the Mac, keeping the existing local
signing/Auth settings. From the repository root run
`bash frontend/scripts/test-mac.sh`; require XCTest/UI and the Release build to
pass before installing. Windows validation cannot execute these Apple checks.

1. **Fresh launch:** expect one recap over Garden once identity is verified.
   With a warm verified connection, the sheet should start appearing within
   roughly 0.5 seconds of an eligible return, even if its contents still say
   Checking activity. Slow cold authentication is a separate timing interval.
2. **Normal play:** close the recap; orbit/pan/zoom, inspect plants/skills, move,
   rotate, store and replant a copy. Open Activity and Sync now. Check current
   progress, stable camera and no automatic recap during these actions.
3. **Short interruptions:** leave for 5–10 seconds and return at least five times.
   Expect no recap. Open/dismiss Notification Centre and Control Centre at least
   five times each. Expect no new entry sheet or growing input lag.
4. **Long return:** leave for 35–45 seconds, including a locked-phone trial, and
   return from Garden, Activity and Packs. Expect exactly one loading recap over
   Garden. A short trip immediately afterwards must stay quiet. An existing
   settings/menu, Garden Storage/edit, Health consent, exchange confirmation or
   pack modal that is still presented suppresses that return's automatic recap;
   unseen receipts remain in Activity. The existing pack reveal closes on
   backgrounding; its committed result remains recoverable in Packs.
5. **Slow/offline:** enable Airplane Mode before a long absence. Return and close
   the loading recap immediately. Reconnect and use Sync now. The sheet must not
   reopen; no missing data should be presented as confirmed zero. Repeat rapid
   leave/return while work is pending; saved requests should eventually resolve.
6. **Visitors and economy:** check the actual butterfly, animation, projected taps
   at different zooms, the accessible Welcome action and stored-visit collection.
   An already loaded butterfly should not revert to the old fallback on ordinary
   switches. Check one reward per welcome/claim. Exchange tokens, inspect Packs,
   cancel an opening, then complete both taps of another opening. Interrupt once
   and verify the saved result survives with one debit/pack/plant only.
7. **Account and accessibility:** if another test account is available, switch
   while a refresh is pending and confirm no old account recap/results appear.
   Return to the original account and resolve its queue. Recheck Reduce Motion,
   large text, VoiceOver and the fixed portrait/light appearance.
8. **Sustained session:** play for at least ten minutes with at least twenty
   Home/app switches interspersed with the normal functions above. Compare
   responsiveness with the first minute. Check for progressive lag, delayed sheets,
   camera jumps and warm artwork fallbacks. Record iOS version, build and the
   exact action/time of any failure.

For diagnosis, capture the Xcode console with subsystem `MovementForest`, category
`Lifecycle`. Debug logs contain continuous elapsed timestamps, resume/sync IDs,
Health-read boundaries, sheet request/appearance/loading/dismissal and renderer
creation/detachment/disposal/destruction plus butterfly-import events. They omit
credentials and Health payloads. A normal pause should reuse the renderer and
loaded butterfly; repeated active/inactive transitions should not start new sync
passes. A real scene replacement should dispose and then release the old renderer.

The play-test establishes visible behavior. Use Instruments Allocations/Memory
Graph and Time Profiler/animation traces for resource/performance acceptance:
memory must settle after warm-up, retired instances and subscriptions must not
accumulate, and frame time must not deteriorate across cycles. The existing
provisional floor is 30 FPS. The iPhone 14 Pro reproduction and supported minimum
device are separate evidence. No device trace or native build is claimed here.

## Install and validate

Keep the existing app installation, account, API configuration, Health consent,
pending requests and Mac signing settings. Transfer the full source/project plus
`assets/packs/woodland/v1` and `assets/butterfly/v1`, alongside the existing Oak
and Moonwillow packages. These are bundled resources; no CDN or database upgrade
is introduced by F8.1. Existing scheduled-visitor backend prerequisites still apply.

On the Mac, run `bash frontend/scripts/test-mac.sh` from the repository root.
Require Debug XCTest/UI and Release build success before installing the build.
The new Debug-only pack fixture route uses in-memory requests and synthetic
receipts. It never connects to the player's account or writes a journal. UI tests
exercise both taps for all four rarity labels and the Reduce Motion sequence.

## Player walkthrough

1. Launch/sign in. Expect one scrollable **Your garden update** sheet. After
   confirmation, inspect named plant copies, water, saved skill bonus and stage
   changes/progress. Duplicate copies remain separate. Continue closes the sheet;
   growth was already saved. Stored visits are not collected by this action.
2. While playing, use Activity → Sync now, pull to refresh and plant/store a copy.
   Ordinary sync must not reopen the sheet. Briefly opening Control Centre or a
   system permission sheet must not count as another app entry.
3. Background the app for at least 30 seconds, then return. Expect exactly one new sheet, including a
   quiet no-new-growth state if appropriate. Repeat from Activity and Packs too.
   Close while it is loading: a delayed result must not reopen it during play.
4. On Garden, open Storage directly. Choose a copy; the existing placement editor
   starts. Place it and confirm progress/identity are preserved. Plant details
   show water remaining to the next named stage. Stored sources stay inactive;
   only the strongest duplicate Sleeping Dew source applies. A source becoming
   adult enables subsequent uploads, not a retroactive bonus for that upload.
5. Exchange → View contents and odds. Inspect and go back: no purchase occurred.
   Choose quantity, inspect total, select Exchange and cancel once. Then confirm
   one exchange. Expect inline pending/success feedback, correct confirmed balance
   and **Open packs**. A failed list refresh must not obscure confirmed purchase.
6. In Packs, cancel **Open pack?** once and check the pack remains unopened.
   Confirm another opening. First tap tears the wrapper and shows rarity light;
   wait here and verify it does not auto-advance. Second tap reveals the sprout,
   species/variant/rarity and Continue. Common uses grey, including a Common
   Golden Moonwillow receipt. Continue restores Packs; latest result/history and
   exactly one new stored sprout remain. Only Woodland has themed wrapper art;
   other pack types use a generic wrapper and the same two-tap flow.
7. Return to Garden. Check the actual butterfly artwork, continuous wing motion,
   depth/perspective through orbit/pan/zoom and tapping. The separate Welcome
   visitor button remains available. Heartbeats/sync must preserve flight;
   editing, sheets and backgrounding pause active visitors. Due visitors expire
   normally and repeated taps do not duplicate rewards.
8. Rotate the phone: the app stays portrait. Set the phone to Dark Mode: the app
   and native sheets retain their light appearance. This is a single appearance,
   not a second Dark Mode theme.

## Recovery and accessibility

- Disable connectivity before entry. Cached progress is labelled; unavailable
  activity is not shown as zero. Reconnect and sync without a surprise popup.
- Interrupt an exchange/opening immediately after confirmation and relaunch.
  Retry the original saved request. Check one debit/pack/plant only. A recovered
  opening appears as the durable result/history without replaying the ceremony.
- Background or force-close during both pack taps. The committed plant stays in
  Storage even if the reveal was skipped. Unknown requests remain recoverable.
- Dismiss a loaded recap during another sync. Only displayed receipts are
  acknowledged; later/unseen credits remain pending in Activity.
- Switch accounts with pending work. No previous account's recap, result, wallet
  or delayed response may appear in the new account.
- With VoiceOver, check focus enters the recap/opening, actions have clear spoken
  labels, underlying screens cannot be activated and dismissal restores useful
  focus. Both pack actions are accessible buttons, not gesture-only controls.
- At the largest accessibility text size, scroll every recap/result and reach
  Continue, Storage, purchase and recovery actions on a small portrait iPhone.
- With Reduce Motion enabled before launch and toggled while running, flight and
  wing motion pause; pack opening still requires two deliberate actions with
  simplified fades. Expiry, confirmation and rewards remain functional.

## Performance and evidence

Select and record the supported minimum physical device. Measure a starter and
10–15 mature/mixed plants with up to 12 due visitors. Use Instruments for frame
time, CPU/GPU, memory and thermal behaviour; the in-app scene interval is not a
GPU measurement. Provisional garden floor: 30 FPS. Keep a ten-minute session and
repeat opening/dismissing collection/recap flows at least 20 times; memory must
settle and hidden views must stop animated work. Check camera/anchors remain
stable across growth, sync, invalid placement and modal return.

Delivered Woodland PNGs: 3,911,092 compressed bytes; all three canvases are
1024×1536, approximately 18 MiB decoded RGBA before overhead at full resolution.
The opening downsamples each to at most 900 pixels on the long edge; inventory
uses 180 pixels. One butterfly template is shared across visual copies. These
limits do not establish total GPU memory or actual minimum-device performance.

| Gate | Result / device / evidence |
| --- | --- |
| Apple SDK Debug + XCTest/UI | Pending |
| Release simulator build | Pending |
| Existing-account walkthrough | Pending |
| Portrait / large text / VoiceOver / Reduce Motion | Pending |
| Minimum-device frame time, memory, thermal session | Pending |

Catalogue discovery, new milestone/step rewards, watering/swarm effects, remote
asset delivery and deployment are separate work.
