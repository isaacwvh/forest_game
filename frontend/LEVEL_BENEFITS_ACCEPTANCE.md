# Level benefits and celebration acceptance

The app uses the existing parchment/forest palette, XP artwork and bookplate
button. A compact centered card displays `Level X → Y` and only the benefits
earned by that crossing, with gains and new totals. It shows the skill-adjusted
offline total when it differs from the base. Profile adds current base/effective
offline capacity, owned plant capacity and upcoming increases. Home's compact
header and mounted garden renderer are preserved.

## Native validation on Mac

From the repository root, run:

```sh
bash frontend/scripts/test-mac.sh
```

This runs portable validation, the native unit/UI suite, and Release and
InternalRelease builds. The new unit tests cover durable presentation markers,
relaunch recovery, eligibility changes during a claim, another device winning,
disk-write failure, account isolation, late results after sign-out, stale capacity
merging and the HTTP-derived summary contract. UI coverage includes gains, ordinary
card height, largest Dynamic Type dismissal, Profile, and navigation without replay.

Windows syntax/project/asset/contract validation cannot establish Apple SDK
typechecking, XCTest results, actual layout or VoiceOver behavior. These native
checks remain pending until run on Mac/iPhone.

## Deterministic UI preview

In the Debug scheme's Run arguments, enable:

```text
--fixture-health --fixture-garden --fixture-level-up
```

1. Launch: expect one compact `Level 4 → 5` card, offline `+75 → 900 total` and
   plants `+10 → 60 total`. The card should fit its content at ordinary text size.
2. Continue: the garden is usable, with the same scene/camera position. Open
   Profile and check Level benefits shows base 900 and owned capacity 60.
3. Close Profile and switch Activity → Garden → My plants → Garden. No second
   card should appear in this session, and the slim Home header stays unchanged.
4. Repeat with largest accessibility text: details may scroll while Continue
   remains reachable. With VoiceOver, verify focus starts on the heading, the
   underlying tabs cannot be activated, and gains/totals read coherently.

This fixture uses synthetic HTTP-derived data and an in-memory claim/cache, with
no network or personal-account changes. Relaunch intentionally resets it to show
the card again. Remove the arguments for actual account persistence checks.

## Live-account flow after backend activation

First follow [backend upgrade and activation](../backend/LEVEL_BENEFITS.md).
Use the app built from this change against that backend.

1. Sign into an existing account. Refresh Profile. Recorded steps, currencies,
   and current level must be retained, with no historical level-up card. Check the
   displayed limits against the tier table in the backend document.
2. Sync enough newly accepted steps to cross the next level. XP needs
   `50 + 25*(currentLevel-1)` for the next level; 100 accepted steps give 1 XP.
   Expect one card once the sync and any entry recap finish. If a sheet, pack
   reveal, edit flow or other blocking child screen is open, return to ordinary
   browsing first. Backgrounding must not show a popup.
3. At 4 → 5, expect base 825 → 900 and owned capacity 50 → 60. At 9 → 10, expect
   base 1,140 → 1,200 and owned capacity 60 → 75. A crossing after 20 should show
   the level change without invented benefit rows.
   On a test account, also sync enough steps to cross several levels at once:
   expect one aggregate card (for example 1 → 5 shows offline +300 → 900 and
   plants +10 → 60), rather than a separate card for each intermediate level.
4. Continue, refresh again, relaunch, and sign in on a second device: the same
   completed level-up must not repeat. Both devices should show the earned limits.
   Repeating an already credited step sync must not create XP, gems or notices.
5. Check Garden info/Collect and My plants/pack opening use the new capacities.
   With an offline-capacity skill active, check Profile's effective value matches
   Garden info and is at most three times base. Planted and unopened-pack limits
   stay at their configured values (normally 20 and 50).
6. If activation leaves stored visitors above the new cap, all remain collectable.
   Accrual resumes after storage drops below capacity. Test ordinary planting,
   storing, visitor collection and pack opening afterwards; no transient refresh
   failure banner or viewport reset should be introduced by this feature.
7. Disconnect/reconnect around a real level-up. Earned benefits must persist even
   if the card is deferred. A recovered claim uses its original IDs; another
   device winning the claim suppresses the local card. The server and durable
   local marker prioritize at-most-once display; a crash just before rendering
   can skip the animation, without losing benefits.

No maturity XP, pack pricing/rates or extra Home rows are added by this change.
