# Floating Home — implementation and acceptance

Follow-up, 20 November: shortcut gaps are 12 points, with bounded single-line
labels at ordinary text sizes and wrapping at accessibility sizes. The drawer
is removed. Inventory, Activity and collection root pages now provide Back to
Garden; returning preserves the mounted scene. Native route coverage checks the
back control and absence of the old menu. Backend quest resale values are covered
separately in backend/EXPEDITIONS.md.

Follow-up checks passed locally: 107 expedition/item backend regression tests,
all 113 Swift syntax parses, portable project/resource/contract validation, backend
lint, scoped layout detector and whitespace checks. Native Xcode/UI execution
still requires a Mac. Tests used a separate disposable PostgreSQL cluster.

20 November 2026. Implements the approved v3 concept. No backend, earning rules,
claim mutation paths, editor save behavior, deployment or CI changes.

## Implemented

- Full-display Garden viewport with safe-area-aware overlays; the existing scene,
  render session and camera stay mounted across browsing/Edit and navigation.
- Independent native material segments for level/XP, Profile, Settings and metrics.
  Compact icons/type; intrinsic metric fallback rows and Dynamic Type remain.
- Five unframed botanical shortcuts with small overlapping text: Shop, Catalog,
  Packs, Milestones, Expedition. Content pages have a Back to Garden control.
- Four floating bottom controls. Lists/detail pages still reserve their bottom
  navigation row, preserving the earlier page-overlap fix.
- Collect above Garden info, aligned four points from the right edge.
- Shared exclamation artwork. Confirmed milestone/expedition entitlement reasons,
  unopened packs, stored visits and the existing draft warning drive attention.
  Confirmed claim/opening receipts suppress stale snapshots; viewing alone does
  not acknowledge a reward. Shop/Catalog have no invented event badges.
- One shared reward read on foreground/connection and confirmed progression or
  hosted-visit revisions. No icon timer/poll loop or new backend endpoint.
- Individual visitor/camera exclusion frames, measured popup/navigation clearance,
  bounded shortcut scrolling only on overflow, and opaque/contrast fallbacks.
- Approved image masters/prompts retained in output/concepts/home-floating-v3;
  five RGBA 128px runtime icons total 91,127 bytes. Bundle coverage, byte budgets,
  PNG dimensions and checksums are validated.

## Local checks

- Portable project/resources/assets/contracts/contrast validator.
- Swift syntax parsing for the complete application and test sources.
- Real Swift Home attention policy plus real domain records/wire decoder and
  synthetic fixtures: 20 shared behavioral assertions. Only presentation numeric
  and error interfaces are substituted for the Foundation-only runner. The same
  assertions run through HomeAttentionTests on the native target.
- Scoped layout detector and diff whitespace checks.

The actual results are recorded in VALIDATION.md. Passing syntax/portable checks
does not establish an Apple SDK build or native visual acceptance. This Windows
host cannot execute Xcode, UIKit/SwiftUI XCTest, RealityKit or an iPhone simulator.
The PNGs in the proposal folder remain design concepts, not build screenshots.

## Mac/iPhone acceptance still required

Run `bash frontend/scripts/test-mac.sh` on a Mac. Exercise Debug with
`--fixture-health --fixture-garden --fixture-progression`, then a connected account.

1. Check small/current portrait phones: scenery reaches every display edge while
   controls avoid the status bar, Dynamic Island, corners and home indicator.
   There is no continuous top/bottom panel or left background strip.
2. Open every shortcut; return using Back to Garden. Check Inventory and Activity
   have the same back action and no drawer. Open/close
   Profile/Settings, selected plants/items and focused Edit. Camera and selection
   ownership must remain stable. Edit retains Save/Discard and draft warning.
3. Pan, orbit, pinch and welcome butterflies through clear gaps and below the last
   shortcut. Actual controls block underlying targets. Selected-copy popups stay
   above the floating bottom navigation, including long content.
4. Confirm milestone, expedition, pack and stored-visit indicators. Successful
   claims/openings remove the corresponding reason even if the next read fails.
   Full storage/offline and pending requests retain their existing action guards.
   No badge grants a reward or changes when a page is merely opened.
5. Reconcile new steps/growth/visitors without reopening Milestones: confirmed
   earning revisions refresh attention. Foreground after month rollover; test no
   current expedition, missing snapshots, sign-out and account/server changes.
6. Repeat with long balances, largest Dynamic Type, VoiceOver, Reduce Transparency,
   Increase Contrast and Reduce Motion. Shortcuts scroll when necessary; labels
   wrap without reducing tap targets. Retry and genuine-zero states remain clear.
7. Check last-row visibility on Inventory, Activity and every collection page.
   Native regression coverage includes the updated direct routes, right action
   order, icon bundle presence, safe-area scene bounds and visitor exclusion gaps.

No push or remote CI run is part of this work.
