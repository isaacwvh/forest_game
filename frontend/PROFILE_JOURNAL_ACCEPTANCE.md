# Profile journal redesign

20 November 2026. Source implementation of the approved two-scroll-position
concept. This is a Profile presentation change; native compilation and visual
acceptance remain pending on a Mac/iPhone.

## Scope

- The same Standard Oak sprout portrait appears for every account, with the real
  display name and username. Existing bundle resources provide all illustrations;
  no new artwork, manifests, asset packages or project membership are required.
- Profile-only level progress shows the existing exact XP ratio within its bar.
  Its VoiceOver value preserves current XP, destination level and lifetime XP.
  The shared Home progress controls are untouched.
- Wallet retains available tokens/gems and initialized next-gem progress. Lifetime
  retains recorded steps, confirmed hosted visits and copies grown to adulthood,
  followed by the existing expandable supporting statistics. Capacity follows
  Lifetime and is shown only when the confirmed summary supplies benefits.
- Capacity means the effective stored-visit limit and total owned-plant limit,
  not current occupancy. Level details retains base capacity, the optional next
  increase and the optional next plant tier. Account details retains joined date,
  game timezone and last activity sync. Account and sign-in keeps its route.
- Native disclosures initially stay collapsed, as before. Long values and larger
  text use vertical layouts. Artwork is decorative for VoiceOver. The XP label
  uses paper over green fill and ink over sage, including empty/full boundaries.
- All values still use the same summary fields and formatters. Loading, preparing,
  real zero, saved/offline, uncached failure, Retry, refresh, section anchors,
  account switching and the existing Profile/visitor lifecycle are unchanged.

## Executed local checks

- `python frontend/scripts/validate_frontend.py`: project freshness, bundle
  resources, asset checksums/alpha/budgets, game/API fixture contracts and palette
  contrast pass. Added coverage resolves all nine Profile illustration references
  against bundled alpha PNGs and checks the in-bar XP foreground contrast.
- `python frontend/scripts/check_swift_syntax.py`: all 109 Swift files parse.
- Account/progression/level-benefit and native wire-contract regressions:
  **55 passed** against the dedicated local PostgreSQL test cluster using only
  randomized disposable databases. The runner stops that cluster afterward.
  A first sandboxed attempt could not connect to localhost; the unrestricted
  local rerun passed without application changes.
- The scoped design detector reports no findings. This is a static source check,
  not an iPhone rendering check.
- Scoped whitespace validation passes. SHA-256 comparison confirms that all
  831 captured assets, backend source/migrations, native models/services,
  configuration/fixtures, other feature views and the Xcode project are unchanged.

## Native coverage and pending acceptance

Added hosted checks cover bundled Profile artwork/decode bounds, narrow long-name
layouts, the largest Dynamic Type size, and long wallet/record values. New UI
tests cover confirmed capacity/next-tier details, expansion/collapse, real zero
progress at the largest text size and reachable Account navigation. Existing
shared-progress, gem-anchor, cached-failure and uncached-failure tests remain.

These hosted tests have been syntax-parsed, **not executed on Windows**. Run
`frontend/scripts/test-mac.sh` locally on a Mac for XCTest/UI tests and the
Debug/Release/InternalRelease Apple SDK checks; no push or CI is needed.

On the smallest supported portrait iPhone and a current iPhone:

1. Launch `--fixture-health --fixture-garden --fixture-progression`. Compare the
   profile header, in-bar ratio, wallet band and illustrated records with the
   approved concept. Confirm all record values against Home/Diagnostics.
2. Enter through Profile, Home XP and Home gems. Gem entry must still scroll to
   Wallet; dismissing Profile must return to the same garden/camera or tab.
3. Expand/collapse every disclosure, then open Account and sign-in and return.
   Use `--fixture-level-up` to check actual capacity and optional next-tier rows.
4. Repeat with `--fixture-account-fresh`, `--fixture-account-offline` and
   `--fixture-account-failed`. Verify real zeros, retained cached values and Retry;
   an uncached failure must show no invented wallet/profile values. An
   uninitialized wallet must retain Preparing and omit the next-gem track.
5. Check long names/usernames, full large integers and timezone/date strings;
   repeat at the largest Dynamic Type size with VoiceOver, Increase Contrast,
   Reduce Transparency and Reduce Motion. Values must wrap/stack without clipping,
   all controls must stay reachable, and the bar ratio must remain legible at
   zero, partial and nearly complete progress.

No backend/gameplay change, live save migration, push or remote CI is included.
