# Profile and Home progression — stages 3 and 4

Implemented locally, 6 November 2026. Uses the existing stage-1/2 account summary;
there is no new migration, endpoint, earning rule, pack or level benefit.

## What is implemented

- Profile appears beside Settings on the existing browsing toolbars. The four
  bottom destinations remain. Home's level and gem actions open that same Profile
  page, with the gem action scrolling to currencies.
- The parchment journal shows display name, username, level, current/required XP,
  total XP, tokens, available gems and next-gem steps. Lifetime rows show recorded
  steps, hosted visitors, active welcomes, collected stored visits, grown-adult
  copies and gems earned. Joined date, game timezone, last activity sync and the
  existing Account and sign-in route follow.
- Home keeps a slim XP strip above one icon/value row for tokens, gems, attraction
  and stored visits, followed by Garden info and Collect. The detailed next-gem
  bar stays in Profile, reached by tapping the gem balance. Metrics reflow when
  they cannot fit; confirmed visitor token feedback keeps its existing ownership.
  Exchange and Packs include gems in their summary.
- Shared views read server-confirmed values from AccountSummaryStore. Loading,
  cached/offline, failed, preparing and initialized-zero states are distinct.
  Retry/pull-to-refresh only reads the account summary; it never requests Health
  access or uploads activity.
- Profile shares the Settings sheet coordinator, pauses active visitor interaction,
  blocks automatic entry recaps and closes on account changes. Settings retains
  its existing sign-in flow. The mounted garden scene, camera and edit controls
  retain their ownership and viewport.
- The approved 128px emerald and XP-star PNGs use the existing quantity-image cache.
  Their exact prompts and runtime checksums are in
  `assets/quantity-icons-v1/progression-icons.json`. Masters remain outside the app.
- Badges await the stage-5 earned-badge source. New provider linking, gem spending,
  pack changes, level-dependent stats and reward ceremonies remain deferred.

## Verification in this Windows workspace

Passed: portable frontend project/assets/contracts validation, all 88 Swift syntax
parses, generated project freshness, Python script compilation and diff whitespace
checks. PNG checks include dimensions, RGBA, budgets, approved-file checksums and
prompt provenance. The actual 128px icons were visually inspected.

Added eight AccountPresentationTests covering exact large-number formatting,
backend-derived progress ratios, real zero and preparing wallets, gem/XP boundary
remainders, bundled artwork, a 150-point normal-text compact-header budget and
large-text overlay clipping without scene resizing. Four UI tests cover Home/
Profile/navigation consistency, cached offline Retry, uncached failure without
invented balances and My plants swipe-refresh. GardenEditorTests adds regressions
for canceled swipe callers, quiet transport cancellation, genuine error recovery
and account deactivation/queued editing during a read. Existing native suites remain.

These XCTest/UI tests are included in the generated project and syntax-parse;
they have **not been executed here**. Windows has no Xcode, Apple SDK or iPhone
Simulator. Native builds, tests, screenshots and on-device appearance remain
pending. No CI run or native visual approval is claimed.

## Mac validation

From the repository root on a Mac:

```bash
bash frontend/scripts/test-mac.sh
```

This runs the portable validator, Debug XCTest/UI tests, Release build and internal
Release build. Native tests require an available iPhone simulator.

For a deterministic UI walkthrough without account/Health/network writes, launch
the Debug app with:

```text
--fixture-health --fixture-garden --fixture-progression
```

This uses the real synthetic backend summary: level 5, 22/150 XP, 372 lifetime XP,
3 gems, 7,250/10,000 steps and 2,750 remaining. Optional fixture arguments:
`--fixture-account-fresh`, `--fixture-account-offline`, `--fixture-account-failed`.
These fixtures are Debug-only and keep summary state in memory.

## On-device acceptance flow

1. Open a connected Garden. Check XP is first, then one compact row of tokens,
   gems, attraction and stored visits, with Garden info and Collect underneath.
   The Home next-gem bar is absent; tapping gems opens that progress in Profile.
2. Tap the level strip or Profile icon beside Settings. Verify your identity,
   level, XP, currencies, lifetime rows and account information against Diagnostics.
   Tap gems on Home and verify the Profile opens at Your currencies.
3. Close Profile from Garden, My plants, Activity and a collection destination.
   Confirm the previous destination and garden camera are retained. Edit should
   keep its dedicated controls without the progression HUD.
4. Sync real new steps through Activity. Check Home and Profile agree with the
   accepted summary, including a 10,000-step gem boundary and an XP level boundary.
   Replay/refresh does not add another grant or replay a new reward ceremony.
5. Welcome a visitor, collect stored visits and purchase a current token pack.
   Confirm token feedback and collection eligibility remain correct. Hosted
   lifetime counters update; current Stored visits still shows uncollected visits.
   Exchange/Packs show gems without changing any prices or purchase actions.
6. Reopen offline with a cached summary: values remain and are identified as saved.
   Retry preserves the values on failure. A missing summary shows recovery, never
   made-up zero balances. A legitimate new account shows level 1 and actual zeros.
7. Open Profile while activity reconciles, then close it. It must pause visitor
   interaction and prevent a competing entry recap. Sign out or switch accounts:
   Profile closes and the former account's values cannot appear for the new user.
8. Inspect small portrait and landscape phones, largest Dynamic Type, VoiceOver,
   Increase Contrast and Reduce Motion. Tall headers scroll within their existing
   bounded overlay; controls remain accessible above navigation. Visible HUD areas
   exclude visitor hit/accessibility targets, and the 3D scene does not resize.
   VoiceOver includes lifetime XP, units, progress and remaining-step counts.
9. Open Account and sign-in from Profile and test existing reconnect/sign-out/back
   navigation. No new Apple/Google linking is enabled by these stages.
10. Pull down to refresh My plants several times while connected. The refresh
    completes without a stuck connection/cancellation message. Genuine offline
    failures remain visible and clear after a successful refresh.
