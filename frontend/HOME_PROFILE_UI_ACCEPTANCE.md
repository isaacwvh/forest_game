# Compact Home and Profile

Implemented 7 November 2026. This is a presentation-only update based on the
approved Home concept. No live account/backend changes. Local validation and
pending native checks are recorded below.

## Home

- One browsing row contains menu, compact XP, Profile and Settings. It replaces
  the native browsing title row. XP still opens the existing Profile sheet.
- One parchment balance row shows tokens, gems, attraction and stored visits.
  Narrow/large-value layouts can use two columns or a vertical fallback; larger
  accessibility text uses a vertical arrangement. Exact values remain unchanged.
- Garden info and Collect retain their existing callbacks, availability and labels
  as two 44-point corner controls. Their middle has no full-width backing and no
  visitor-accessibility exclusion. Token feedback remains owned by its existing
  counter/coordinator and retains its scaled clearance.
- The bottom bar keeps the same four destinations and height. Parchment extends
  through both system safe areas; the selected tab uses green ink and an underline.
- The garden remains mounted. Focused Edit retains its native Done toolbar and
  dedicated controls; the recovery Account destination explicitly retains native
  navigation. Other pages keep their existing toolbars.

## Profile

- Identity and current level/XP form one group. Wallet keeps token/gem balances and
  one next-gem progress bar with the actual number of steps remaining.
- Capacity shows the effective stored-visit limit and total plant limit. Base and
  next-upgrade details are behind Level details.
- Lifetime shows recorded steps, visitors hosted and plants grown to adulthood.
  More statistics retains active/offline counts, lifetime gems and total XP.
- Joined date, game timezone and last sync live in Account details. Account and
  sign-in remains a separate native destination.
- Removed the step-to-XP and step-to-gem earning explanations, mature-garden
  explanation, repeated progress wording and plant-capacity explanation.
- Loading, initialized zero, preparing, saved/offline, genuine failure and Retry
  remain distinct. Data refresh, account scoping and modal/visitor guards are reused.

## Local validation

Executed on Windows:

- `python frontend/scripts/validate_frontend.py`: passes project freshness, resource
  membership, assets, palettes, game/API fixtures and presentation contracts.
- `python frontend/scripts/check_swift_syntax.py`: all 92 Swift files parse.
- `git diff --check` on the changed UI/test/document paths: passes.
- SHA-256 comparison confirms all 120 existing backend source/migration and native
  model/service/rendering/fixture files match their pre-task contents. Root
  eligibility/navigation guards, visitor collection callbacks and lifecycle
  handlers are also reviewed against the original source.

Native coverage updated in AccountPresentationTests and ForestUITests: the two
compact full-width rows, clear corner-control gap, aligned toolbar actions,
menu/Settings/Profile routes and expandable Profile details. Existing recovery,
zero-account, shared-progress and stable-scene tests remain.

These XCTest/UI tests have **not run here**. Windows has no Xcode/Apple SDK or iPhone
simulator; syntax parsing does not establish compilation or device appearance.

## Native acceptance

Use the existing `frontend/scripts/test-mac.sh` locally on a Mac when ready; no CI
or push is required. For the presentation fixtures, launch Debug with
`--fixture-health --fixture-garden --fixture-progression`.

1. Check the smallest supported portrait width and a current iPhone: all four top
   controls share one row, XP remains legible, balances align, and neither system
   safe area introduces a white seam. Bottom labels and all touch targets remain.
2. Open/close menu, Settings and Profile, including the XP/gem entry points. Keep
   the same scene/camera after dismissal. Enter/leave Edit and check Done, Storage
   and existing edit actions. Check the recovery Account push/back route.
3. Rotate/pan/zoom through the clear gap between the corner tools. Welcome a
   butterfly there; verify actual opaque controls still exclude visitor targets.
   Collect remains disabled at zero/pending/unavailable and confirms rewards once.
4. Check token +N feedback without shifting the scene or overlapping controls.
5. Profile shows the same confirmed values as Home/Diagnostics. Expand/collapse
   each details group, open Account and sign-in and return. Gem entry scrolls to
   Wallet. Rule/explanatory paragraphs remain absent.
6. Repeat with `--fixture-account-offline`, `--fixture-account-failed`,
   `--fixture-account-fresh` and `--fixture-level-up`. Preserve Retry, preparing,
   missing and genuine-zero behavior; level benefits remain server-derived.
7. Check large balances/levels, long names, largest Dynamic Type, VoiceOver,
   Increase Contrast and Reduce Motion. Tall overlay content remains bounded and
   scrollable, clear scenery passes gestures, and no control sits under system UI.
