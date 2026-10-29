# F8.1 first-release polish acceptance

Source implementation: 26 October 2026. Native execution and device results must
be recorded separately; portable parsing is not Apple SDK compilation.

## F8.7 catalog discovery — source implemented, native acceptance pending

Apply backend migration `0009_catalog_discovery` explicitly before testing the
matching native build. Existing stored/planted progress is backfilled from pinned
profiles; no reset or reseed is needed. Windows automated tests use isolated
databases and do not perform this upgrade on the real game installation.

Run `bash frontend/scripts/test-mac.sh` for native XCTest/UI and public/internal
Release builds. `CatalogDiscoveryTests` covers the shared wire fixture, variant/
species/account isolation, cache persistence, unknown/failure states, stale versions,
coalescing, invalidation during a read, detach and cache-write failure. Parsing on
Windows is not an Apple SDK typecheck or an executed native test.

1. On a fresh account, open Catalog: all species rows show full-color sprouts.
   Open each species and switch variants: its header and sprout row stay full-color,
   including unowned variants. Seedling/young/adult show flat silhouettes and
   Not discovered. Names, values, skills and odds stay readable.
2. Grow Standard Oak through the stages. Each confirmed stage reveals only its
   matching Standard image. A multi-stage credit reveals every crossed stage.
   The header/list portrait stays a sprout after adult discovery.
3. Blue/Vined later stages remain locked. Grow Blue to seedling: only that stage
   reveals. A new Standard duplicate starts at sprout without relocking Standard.
   Stored copies retain their discovered catalog art; storing alone adds no growth.
4. Upgrade an existing account with mature stored and planted copies. Verify correct
   variant discoveries from actual progress, and persistence after restart/relogin.
   Viewing old unrestricted artwork alone must not count as earned discovery.
5. Open Catalog during a sync and switch variants rapidly: no full-color locked
   frame may flash. A confirmed sync refreshes visible discovery without a new
   Health read, pack operation or reward ceremony. Return to Garden: camera and
   mounted renderer remain intact, with the normal visitor lifecycle.
6. Disconnect after loading discovery: confirmed art remains with Last confirmed
   discovery and Retry. With no valid discovery cache or an older backend, sprouts
   remain visible and later stages say Checking discovery / Discovery unavailable,
   never showing all art. A failed discovery read does not block pack recovery,
   growth confirmation or an entry recap.
7. Switch accounts/server during an in-flight read. No old discovery can apply to
   the new account. Switch back and confirm the correct saved state. Check another
   device after a fresh catalog read and compare discoveries.
8. Check VoiceOver stage/status and variant-specific unlock hints, large text,
   contrast and Reduce Motion. Missing art uses Image unavailable without relocking
   a discovered stage. Owned-copy/My plants/placement previews retain current art.

## F8.6 reward and growth effects — completed, user accepted 29 October 2026

User acceptance includes the shimmer restoration follow-up (`4c7784a`) after the
original effects delivery (`8c6cd40`). The walkthrough below remains a regression
reference; unrecorded native automated/build and broader device checks remain open.

The user requested a GitHub push for Mac testing without waiting for CI. Run on Mac:
`bash frontend/scripts/test-mac.sh` (Debug XCTest/UI plus public Release and
InternalRelease builds). Record results separately from the Windows checks.

Fast deterministic visual flow: Xcode → Product → Scheme → Edit Scheme → Run →
Arguments Passed On Launch: add `--fixture-health` and `--fixture-effects`.
This Debug-only screen never signs in, uploads Health, contacts an API or writes
an account journal. Remove the arguments to test the live account afterward.

1. Tap **Reward +1**. The balance changes 100 → 101, the token icon/count shimmers
   once and a readable +1 briefly floats beneath it. Tap **Collect** after it
   finishes: balance 101 → 113, with one +12. Nothing moves the camera or header
   during playback. Repeat at large accessibility text size; amounts remain clear.
2. Tap **Growth recap**, then **Continue**. Only five recipients receive descending
   droplets and foliage shimmer; the other ten stay quiet. The fixture's recipient
   counter reads 5. Repeat using swipe dismissal. Each fresh recap may water again.
3. Tap **No growth**, then Continue. Recipient counter reads 0: no droplets, shimmer
   or stage burst. Repeat after the positive-growth scenario has finished.
4. Tap **Reset**, then **Stage recap**. While the sheet is open, replacements may
   load but do not visibly reveal. Continue: three recipients receive water, an
   upward shimmer and a leaf/light burst; stage models switch at its peak. Repeat
   to test later stages, then Reset. Plants remain grounded with the same yaw and
   camera. **Water 15** exercises the bounded concurrent-effect queue.
5. During effects, background the app and return. No old ceremony resumes. Pan,
   zoom and select before/after effects; hit targets and controls remain usable.
   Repeat with **Reduce Motion** enabled in iOS Settings. The fixture also accepts
   `--fixture-reduce-motion`: no falling particles/spatial token motion; stationary
   amount, gentle plant highlight and a short stage fade remain.
6. Check VoiceOver: one token reward announcement and a readable current balance;
   cosmetic particles never become accessibility/touch targets. Confirm increased
   contrast/Reduce Transparency, small portrait screens and the 15-plant case.
   Inspect native captures and measure performance on the minimum supported device.

Live-account regression flow:

1. Welcome one real butterfly and Collect multiple stored visits. Wait for server
   confirmation before any +N; the amount matches the actual receipt. Pending and
   failed requests retain existing recovery feedback, with no optimistic reward.
2. Lose a reward response, then retry the same request. Its first confirmation in
   the current visible session may celebrate once. Further retries/refreshes and
   relaunch recovery do not repeat it. Navigate away or switch accounts while pending:
   old feedback must not appear in the new view/account.
3. With a planted, non-mature copy, record real activity, leave for at least 30
   seconds, return, wait for the recap, and dismiss it. Only positive saved growth
   recipients water/shimmer, including copies that did not advance a stage. A
   mature copy with a zero capped award and any now-stored copy stay quiet.
4. Return without new credits: the quiet recap produces no effect. Manual/observer
   sync never opens a watering ceremony. Test a multi-stage credit: one transition
   from the prior to final stage, rather than several intermediate ceremonies.
5. Dismiss **Checking activity…** before reconciliation finishes. No late sheet or
   watering/stage ceremony appears. Saved growth still resolves normally. Interrupt
   a loaded recap by backgrounding/account change; do not leak its effects.
6. Interrupt acknowledgement/offline recovery after watching a recap, then relaunch
   and reconnect: no replay from the same receipts. New receipts still animate.
   A missing stage asset keeps the prior model with existing artwork/retry feedback;
   retries, initial loads, adult previews and stored-copy browsing never celebrate.

The existing F8.5/navigation, pack recovery and visitor-session acceptance below
still applies. Catalogue discovery remains deferred; no economy/API change is implied.

## F8.5 minimal UI cleanup — source implemented, native acceptance pending, 28 October 2026

This is the current highest-priority presentation batch. It supersedes historical
walkthrough instructions below that expect opening history or controls/visitor
details inside Garden info. Saved history and the accepted opening/recovery
mechanics remain. The user requested a GitHub push for Mac testing without waiting
for CI; native build and device acceptance remain separate gates.

On Mac first run `bash frontend/scripts/test-mac.sh`: Debug XCTest/UI, public
Release and InternalRelease builds. Newly added native tests have not run on
Windows. Debug launch arguments `--fixture-health --fixture-collection` provide
the actual compact collection views with synthetic in-memory data and counters;
no account/network/Health upload or disk journal is involved.

Live-account/device walkthrough:

1. Open Exchange. Confirm token balance at the top and compact pack rows with icon,
   name, price, information icon and Purchase pack. Tap information: only tier
   names/percentages and plants initially appear. Expand a plant for detailed odds.
   Close: wallet and owned packs are unchanged. Repeat with an older owned pack and
   verify its frozen contents, not the current offer's definition.
2. Tap Purchase pack. Change quantity; check total and affordability. Cancel once
   with no spend. Confirm an affordable purchase: one debit, correct pack count,
   updated wallet and concise success/Open packs. Tap repeatedly and test a lost
   response/relaunch/retry: recover the original request and quantity, never buy twice.
3. Open Packs: tokens → unopened packs → last confirmed opening. No opening history
   or acquisition-date text. Load additional pack pages if present. Information is
   read-only. Cancel an Open confirmation: nothing consumed. Complete a fresh
   confirmation → tear tap → reveal tap → Continue: one consumed pack, one saved
   sprout, updated last result. Buy another pack or claim a milestone; the latest
   opening remains the displayed result. Relaunch and verify it is still available.
4. Interrupt opening at confirmation, tear, reveal and final result; try network
   loss, relaunch and account switch. Retain original request recovery and one saved
   plant. Known confirmed results do not replay the ceremony. No cross-account data.
5. Garden info shows only active skills or a concise empty/unavailable state. Skill
   name/effect is visible; description/source appears only after expansion. Check
   source duplicates, cap detail and last-confirmed cached data where applicable.
6. Settings → Game help: expand controls, visitors and other topics. Current visitor
   values are read-only and labelled last confirmed. Sample accounts can browse
   sample plants here. Return to Garden: camera/selection and butterfly hit targets
   are preserved; visitors resume normally. Verify Edit → Storage → details → Place,
   cancel/confirm and Done still work, including accessible camera controls.
7. Inspect Catalog, My plants/details, Milestones, Activity/Health, recap and account.
   Supporting information expands, while search/filter/pagination, claim, Place,
   consent, sync, recovery and account actions remain available. Missing data never
   appears as zero. Dismissing recap does not award growth again.
8. On a small screen and at accessibility text sizes, scroll every page to its final
   row above bottom navigation. Check readable rarity colours, 44-point information
   targets, VoiceOver disclosure/actions and Reduce Motion's unchanged pack flow.

## Lifecycle follow-up — done, user accepted on iPhone, 26 October 2026

The user confirmed expected recap behavior, then confirmed that cold-start
butterfly loading works without a stuck loading state or manual artwork retry.
They accepted the lifecycle/loading tickets as done. This covers the follow-ups
in `1d51fad`, `03abe14` and `4d151a1`; the earlier Packs routing/entry destination
acceptance remains valid. No new XCTest, Release-build or Instruments execution
is inferred from this report. The broader pending gates below remain separate
from these closed functional tickets.

The following procedures remain regression references, not an outstanding request
to repeat accepted play-tests before beginning F8.2. See the exact four-item
F8.2 scope in [the implementation plan](../IMPLEMENTATION_PLAN.md).

**Cold-start import timeout / recovery retest:** kill the backgrounded app and
reopen it at least five times. Artwork should load normally; a stalled import
must stop showing Loading butterfly after roughly ten seconds of import time
and expose an artwork timeout with Retry visitor artwork. Tap that action without
opening Notification Centre: a fresh load should replace the error when it
succeeds. During a network outage, Retry visitors is separate from the artwork
retry. Restore connectivity and confirm that a successful visitor refresh removes
the old Visitors paused message. Welcome/claim rewards must occur once. Recheck
the accepted first-return recap and quiet manual sync. In Debug, record the
butterfly checksum/import-start/import-complete-or-failure lines and visitor error
domain/code; the asset is bundled and does not download from the game backend.

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

The accepted play-test establishes reported visible behavior. Use Instruments Allocations/Memory
Graph and Time Profiler/animation traces for resource/performance acceptance:
memory must settle after warm-up, retired instances and subscriptions must not
accumulate, and frame time must not deteriorate across cycles. The existing
provisional floor is 30 FPS. The iPhone 14 Pro reproduction and supported minimum
device are separate evidence. No device trace or automated native-build result
is recorded here; these broader measurements do not reopen the closed tickets.

## Targeted iPhone acceptance — completed, 26 October 2026

The user confirmed commit `dc392fd` works on their native iPhone installation:
Packs inspection and opening are separate actions, and the entry activity recap
appears automatically over Garden without first visiting Activity. These two
follow-up fixes are done. The later first-return recap and cold-start butterfly
loading fixes are also user accepted, as recorded above. These confirmations do not record every walkthrough,
accessibility, automated-build or performance gate below.

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
| Lifecycle / first-return recap / cold-start butterfly | Done — user accepted on iPhone, 26 October 2026; expected recap, no stuck artwork loading or manual artwork retry |
| Existing-account walkthrough | Targeted Packs action routing, Garden entry recap and lifecycle/artwork follow-ups accepted by user on iPhone, 26 October 2026; remaining cases unrecorded |
| Portrait / large text / VoiceOver / Reduce Motion | Pending |
| Minimum-device frame time, memory, thermal session | Pending |

Catalogue discovery, new milestone/step rewards, watering/swarm effects, remote
asset delivery and deployment are separate work.

## F8.2 local implementation and test flow

**F8.2 completed — user accepted 27 October 2026.** Live testing confirmed more
seamless butterfly taps, acceptable draft icons, fixed pack lighting and working
Milestones. The user explicitly closed this batch. Commit `cedba46` was pushed
to GitHub `main`. Apple SDK build/XCTest/UI, broader accessibility/performance
checks and current CI results are not established by this acceptance. On Mac,
run `bash frontend/scripts/test-mac.sh` from the repository root for native checks.
The walkthrough below remains the regression reference for F8.3.

1. Cold-launch Garden and observe loading → model without an intermediate fallback
   or manual retry. Orbit, two-finger pan and pinch; tap each visible butterfly's
   centre and edges, especially the upper scene boundary. Repeat at minimum/maximum
   zoom and after camera gestures. Menu/status taps must retain their own behavior;
   offscreen visitors must not leave active targets. Repeated taps award once.
   With multiple visitors, tap each independently. Check VoiceOver Welcome.
2. Open a Woodland pack. Sealed art hides rarity. First tap tears; receipt-coloured
   light stays inside the mouth with restrained upward spill, never across the
   opaque front. Wait several seconds: no automatic reveal. Second tap shows the
   matching sprout halo, then Continue. Cover Common grey (including Golden
   Moonwillow), Rare blue, Epic purple and Legendary gold, with/without Reduce
   Motion. Test generic packs and background/relaunch recovery of one saved sprout.
3. Open sidebar → Milestones. Verify every existing title, requirement and token
   reward, locked/ready/claimed states and that Exchange no longer lists milestones.
   Claim a ready row repeatedly: one wallet award. Lose connectivity during claim,
   navigate away, relaunch and retry the saved claim; the original result recovers.
   Also test refresh failure before/after data loads, and successful retry clearing
   stale errors. A confirmed reward survives a failed subsequent refresh. Switch
   accounts and verify no other account's rows, pending claims or confirmation leaks.
4. Compare token icons in Garden, Exchange, Milestones and receipts; compare metric
   icons in owned-copy details, Catalog and Activity. Check differing pinned-copy
   multipliers, supported/default/unknown workouts, zero/unavailable metrics, units,
   largest accessibility text and VoiceOver without decorative icon announcements.
5. Return to Garden after visiting every sidebar destination: camera remains intact.
   Background for at least 30 seconds: recap appears once over Garden and loaded
   butterfly artwork remains reusable. Brief Notification/Control Centre interruption,
   manual refresh and ordinary sync stay quiet. Recheck tap alignment after sheet
   dismissal, sync and resume.

Automated additions cover geometry/boundary selection, rendered-camera targeting,
one welcome, claim recovery/freshness, runtime icon resolution, Milestones routing
and four receipt rarities with both motion settings. Existing preload/cache,
loading-to-model, timeout and renderer-retention tests remain unchanged. Added
native tests are not recorded as passing until run with Apple SDKs.


## F8.3 first-version frontend — completed, user accepted 27 October 2026

Commit `219381b` was pushed to GitHub `main`. The user confirmed live testing
works as planned and accepted F8.3 as complete. Portable checks are recorded in
VALIDATION.md; no unrecorded XCTest, Release-build or CI result is inferred from
that acceptance. The walkthrough below remains the regression reference for the
accepted baseline; it does not reopen this batch.

The follow-up batch is **F8.3b — Garden viewport and layout refinement** in
[the implementation plan](../IMPLEMENTATION_PLAN.md). It replaces the browsing
panel/Plants controls, visible Welcome and routine success text described below;
these describe the historical F8.3 behavior. F8.3b source now supersedes those controls;
its user acceptance is recorded below.

Use the existing account/backend installation. Debug includes tools. For optimized
internal device testing select **MovementForest-Internal** (InternalRelease).
Regular MovementForest archives public Release without Developer tools.

1. Cold launch: Garden opens, with the existing recap/loading sequence. Dismiss
   the recap. Check My plants / Garden / Edit / Activity order and the sidebar's
   Exchange / Packs / Catalog / Milestones destinations. Orbit, pan and zoom.
2. Open **My plants**. Planted appears above Stored. Inspect a copy in each section;
   details have no Place/Move/Rotate/Store. Check progress, pinned multipliers and
   skill state. Load additional stored pages, including duplicates. Return to
   Garden: camera and loaded artwork remain unchanged.
3. Tap **Edit**. Normal bottom navigation, Settings and sidebar disappear. Storage,
   contextual controls and **Done editing** remain. Storage → copy opens details
   with a bottom **Place**. Back out without Place: nothing previews or saves.
4. Repeat Storage → details → Place, then Cancel. The copy remains stored. Repeat
   and apply a valid placement (valid drag release also saves). Check invalid
   placement, precise Position, rotation and adult preview; no invalid save occurs.
5. Select a planted copy via the scene or **Select plant**. Check **Move, Rotate,
   Store, Plant details**. Details only inspect. Confirm a move/rotation, then
   Store. Done returns to Garden without undoing confirmed changes. My plants
   shows the same copy in the correct section, preserving growth/profiles.
6. Background with an unsubmitted preview: resume in browsing, with no edit sent.
   Separately interrupt connectivity after submitting: Done, relaunch and retry
   retain the original saved request, with one confirmed result. A pre-edit sync
   that completes after Done must not submit a cancelled preview. Check cached
   browsing and pagination while activity blocks editing. Switch accounts; no
   previous copies, pending operations or details may leak into the next account.
7. Garden's summary shows confirmed visitor tokens, attraction and stored visits /
   capacity. Check Collect and accessible Welcome with pending/result/retry states.
   Garden info contains rates, capacity explanations, hosted totals and skills.
   Tap butterfly centres/edges at the upper scene boundary after orbit/pan/zoom,
   through loading, refresh and resume. Repeated taps/claims award once.
8. Visit Activity/Health, all sidebar pages, owned/catalogue details, account and
   Settings, including empty/loading/offline/failure states. No raw IDs, payloads,
   asset errors, schema/profile versions, verification output or developer setup
   instructions belong in these normal views. Useful odds, skill explanations,
   provisional/sample labels, consent and recovery remain available.
9. Open **Settings → Developer tools → Diagnostics**. Inspect the live renderer,
   current pending state, category/search filters and original request outcomes.
   Copy/export manually. Relaunch and confirm recent history remains. General logs
   omit credentials and Health bodies; explicit Health inspection remains local.
   InternalRelease has this route; public Release does not.
10. Recheck largest text, VoiceOver, Reduce Motion, 44-point controls and scrolling.
    Recheck real background ≥30 seconds versus quiet brief Notification/Control
    Centre interruptions, ordinary sync and manual refresh. Existing normal
    details/info sheets retain their flow and entry blocking across backgrounding.
    Verify the accepted two-tap pack lighting and Milestones claims. **Continue
    later remains**; workout eligibility rules are unchanged.

Run `bash frontend/scripts/test-mac.sh` on Mac for Debug XCTest/UI plus public
Release and InternalRelease builds. Debug `--fixture-health --fixture-garden`
provides an in-memory edit journey without network, disk journals or Health uploads;
use live accounts for recovery/relaunch, visitor and reward acceptance.

## F8.3b Garden viewport and layout refinement — completed, user accepted 27 October 2026

Completed and user-accepted following live testing, including `70ab8e9`'s popup
position and quiet-welcome fixes. The checks below remain the regression reference;
user acceptance does not establish unrecorded XCTest/build/CI results.

- Verify the continuous Garden between existing top/bottom navigation, with no
  permanent white status/controls panels. Selection, balance updates and notices
  never resize the scene, reimport models or reset the camera.
- At ordinary text sizes, verify tokens / attraction / stored visits-capacity in
  one row; Garden info left and green-outlined Collect beneath stored visits on
  the right. Collect greys out with no whole visits; pending requests block repeats.
  Unknown values remain unavailable, not zero; cached values remain identified.
- Verify no browsing Plants strip or permanent visible zoom/reset buttons. Tap
  each planted copy: a transparent green-outlined popup above the bottom navigation
  shows name, variant, stage and read-only Plant details. Another selection updates
  it; close/empty-ground tap dismisses it. Test duplicate identities, account changes
  and confirmed removals, with camera gestures working outside the popup.
- Verify direct butterfly taps at centres/edges through orbit/pan/zoom, new header
  and popup boundaries, cold/warm loading and resume. No standalone Welcome button;
  VoiceOver activates the butterfly itself. Controls retain their own touch areas,
  no offscreen target remains active and repeated taps award once.
- Verify routine Saved/welcome +1 success text is absent while confirmed balances
  update. Interrupt requests: compact pending/failure/retry/offline feedback remains
  useful, and diagnostics retain original request outcomes. Do not require Developer
  tools for recovery. No token shimmer/floating +1 or other new animation is expected.
- Recheck My plants, focused Edit/Storage/Done/placement, navigation, cold/warm
  artwork loading, 30-second recap versus brief interruptions, pack ceremony and
  Milestones. Cover small screens, large text, VoiceOver, camera accessibility
  actions, Reduce Motion and contrast/Reduce Transparency needs.
- Run portable validation and updated native viewport/navigation/selection/
  accessibility tests, then `bash frontend/scripts/test-mac.sh` on Mac and live
  iPhone testing. Record actual checks separately from user acceptance.

Token/reward/watering/stage-transition animations, workout eligibility,
pack-opening cleanup (including removing Continue later), new assets and cloud
delivery remain separate work.

### F8.3b live-account walkthrough

1. Open Garden and dismiss any legitimate entry recap. Check the continuous scene,
   three summary metrics, Garden info left and Collect right; no browsing Plants,
   Welcome or zoom/reset strip. Orbit, pan and pinch to a recognisable perspective.
2. Select plant A, then B (including duplicate species/variants). Check popup name,
   variant and stage. Open Plant details and verify the exact copy and read-only
   context. Close details, close the popup, select again and tap empty ground.
   None of these actions should shift the camera. Gesture outside the popup.
3. Open Garden info: rates, hosted totals, active skills and gesture help remain.
   Return and check camera retention. Switch My plants → Activity → Garden.
4. With whole stored visits, tap Collect repeatedly, including during a heartbeat.
   Progress appears, repeats disable, one confirmed reward updates the counters.
   With zero visits Collect is grey/disabled. No welcome/+1 success text appears.
5. Tap butterfly centres/edges after orbit/pan/pinch and beside header/popup controls.
   Check one award per visitor and that controls still work. With VoiceOver, focus
   the butterfly and double-tap; use Garden scene Actions for camera commands.
6. Interrupt connectivity during a claim or edit; return to Garden. Check concise
   last-confirmed/pending/retry feedback, then reconnect and retry. Confirm one
   reward/edit and unchanged camera. Inspect Diagnostics for original request outcomes.
7. Edit → Storage → copy details → Place → Cancel. Repeat and Apply; select the
   planted copy for Details/Move/Rotate/Store, then Done. My plants stays read-only;
   storing/removing a selected copy clears the browsing popup.
8. Repeat with largest text, VoiceOver, Reduce Motion, Reduce Transparency/increased
   contrast, cold/warm artwork and background returns below/above 30 seconds.
   Sample mode: Garden info → Explore sample plants stays read-only, with no invented
   wallet/ownership. Spot-check pack opening and Milestones.


## F8.4 pack recovery and rarity-coloured names — completed, user accepted 28 October 2026

Pushed to GitHub `main` as `4f6e1f4`. The user confirmed the changes work as
expected. This closes the bounded functional batch; the walkthrough remains a
regression reference. No unreported native build/XCTest, VoiceOver, detailed
interruption-case or CI result is inferred from that acceptance.

1. Open Packs. Cancel an Open confirmation: no pack consumption. Confirm a fresh
   opening: no Continue later; tear tap, reveal tap and final Continue still work.
   Waiting alone must never reveal. Repeat Woodland/generic and Reduce Motion.
2. Background during confirmation, sealed, tearing, opened wait, reveal and result.
   Return: a confirmed result remains in Packs/history and its plant is in Storage;
   the ceremony never replays automatically. Unknown requests retain Retry and
   recover the same UUID/body. Repeated taps/returns must consume one pack only.
3. Repeat network loss, relaunch and account changes, including a result confirmed
   before the follow-up collection refresh fails. Confirmed ownership must survive.
   Opening presentation must never show another account's result.
4. Inspect plant names in Garden popup, Edit, My plants, Storage, plant details and
   titles, Catalog, pack contents/odds, reveal, latest result/history, recap/Activity
   and Garden skill sources. Common grey / Rare blue / Epic purple / Legendary gold.
   Variant/stage metadata and buttons retain normal styling. Historical results use
   their saved rarity even if current catalogue metadata differs.
5. Check sample Garden/list/details and Developer tools; approved sample Oak is
   Common and Moonwillow Epic. Missing/unrecognised/legacy rarity stays neutral,
   never inferred from variant names, artwork or growth stage.
6. Repeat largest text, VoiceOver and increased contrast on light screens and dark
   reveal. Text gold must remain readable. The glow palette is unchanged. Spot-check
   F8.3b popup placement, quiet visitors, scene/camera retention and focused Edit.

Run `bash frontend/scripts/test-mac.sh` for XCTest and Release/InternalRelease builds,
then perform this live-account walkthrough. Record actual automated results and
user acceptance separately. No F8.4 native automated/CI pass is claimed here.

For all-four-rarity visual checks without changing live game data, use Debug launch
arguments `--fixture-pack --fixture-common` (or `--fixture-rare`, `--fixture-epic`,
`--fixture-legendary`). After Continue, the fixture host shows the saved name on a
light background. View saved result returns directly to the dark result without
another opening. Add `--fixture-reduce-motion` for the reduced-motion variant.

## Shared bottom navigation follow-up — pushed 28 October 2026; device retest unreported

Commit `11040d2` reserves a separate layout row for the bottom navigation rather
than applying a safe-area inset around nested navigation stacks. One shared-shell
file changed; no per-page hard-coded bar padding was introduced. Portable frontend
validation, all 64 Swift syntax parses and whitespace checks passed. CI was not
awaited; native layout verification remains a device check.

1. Open Packs and scroll to the final opening-history row, including long content
   and pagination when available. It must be fully reachable above the bottom bar.
2. Check Exchange, Catalog, Milestones, My plants and Activity, including pushed
   plant/catalogue details. Last rows and bottom actions must remain reachable.
3. Return to Garden: popup stays above navigation, gestures work, camera is retained.
   Edit hides navigation; Storage/Place/Cancel/Apply and Done remain usable.
4. Repeat on a small screen with largest text. Check sidebar and Settings sheets
   still present/dismiss normally, and VoiceOver can reach final rows and navigation.
