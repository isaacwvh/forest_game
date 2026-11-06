# Progression foundation acceptance — stages 1 and 2

Requires backend schema `0013_account_progression`; follow
[the backend upgrade/backfill](../backend/PROGRESSION_API.md). Current capacity,
pack offers, authentication and garden rendering continue using their existing
rules. Profile and Home bars are covered in
[the stage-3/4 acceptance flow](PROFILE_HOME_ACCEPTANCE.md); badge awards remain
a later stage.

## Status: stages 1 and 2 complete and user accepted

On 6 November 2026, the user confirmed that Diagnostics displays the current
account's progression and pressing Sync produces a new Progression diagnostic
entry. This confirms the on-device account-summary and sync-refresh integration.
The user accepted these two foundation stages as complete.

This manual evidence accompanies the recorded 559 passing backend tests and
portable frontend checks. Native automated test results remain separately
recorded; the checklist below remains a regression reference for future changes.

## Shared-state behavior

`GardenConnection.accountSummary` owns one `AccountSummaryStore` per verified
account/server. It uses the existing protected, backup-excluded account cache.
Managed cold-offline restoration can expose that cached read-only snapshot;
remote summary requests wait until game identity is verified. Sign-out/account
switching clears published state and rejects late responses.

The store coalesces reads and tracks invalidation during a request. Activity
status/sync results feed the store, including compacted completion recovery.
Wallet-version changes invalidate it without a new polling timer. Progression
and wallet versions merge independently so historical receipts cannot rewind
confirmed values. Confirmed token values feed the existing wallet bridge.
Summary/cache failures never lock activity, visitor or collection journals.

## On-device flow (Debug or InternalRelease)

1. Build/install the updated app over the existing installation. Keep the same
   game account and Apple Health consent. Complete the backend migration/backfill.
2. Open Settings -> Developer tools -> Diagnostics. In Recent events select the
   `Progression` category after the account connects. The confirmed record shows
   `steps`, `gems`, `level`, current/required `xp`, and `nextGem` progress. No new
   public Profile or header is expected in these stages.
3. Open Activity and use the existing sync action after walking. Confirm the
   Progression record follows accepted lifetime steps. Every 100 steps advances
   XP; crossing a 10,000-step boundary adds one gem and resets its remainder.
4. Sync again without new activity; gem/XP values stay the same. There may be a
   fresh confirmation record, but no additional currency is granted.
5. Repeat with mature plants, or a garden with all plants stored. Steps still
   advance gems and XP. Growing/storing/selling plants preserves earned totals.
6. Welcome/collect visitors and make an ordinary token-pack purchase. Existing
   token behavior remains correct and the account summary reflects the hosted
   counters/token balance. Current packs do not consume gems.
7. Background/terminate/reopen, then temporarily go offline and reopen. Cached
   summary remains associated with the same account. Reconnection refreshes it;
   uncertain existing requests recover using their saved UUIDs.
8. Sign out, sign into another account, then return. Progression/currency from
   the former account must never appear in the new account's shared state.

For deterministic threshold checks without walking or modifying personal game
state, run the disposable HTTP smoke script described in the backend guide.

## Native automated checks

Run `frontend/scripts/test-mac.sh` on a Mac. `AccountSummaryTests` covers the
HTTP-derived fixture, cache/offline restoration, cached-only identity setup,
wrong-account rejection, older receipts/reads, legacy missing fields, coalescing
and invalidation during a fetch, late responses after detach, cache-write failure
and malformed progression. Existing activity/visitor/collection/lifecycle suites
remain required. Windows syntax parsing does not execute these XCTest cases or
provide Apple SDK typechecking; native/device acceptance must be recorded separately.
