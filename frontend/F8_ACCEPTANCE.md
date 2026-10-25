# F8.1 first-release polish acceptance

Source implementation: 26 October 2026. Native execution and device results must
be recorded separately; portable parsing is not Apple SDK compilation.

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
3. Background the app, then return. Expect exactly one new sheet, including a
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
