# Milestone tracks — source implementation, 13 November 2026

Migration `0017_milestone_tracks` adds versioned milestone policies, permanent
earned entitlements, daily/event progress, species discovery credits and bonus-gem
grants. Migrating does **not** activate new rewards or schedule an event.

The initial policy `milestones-woodland-v1` contains 62 non-event quests. Steps and
Butterfly run through 5 million steps and 100,000 collected/welcomed butterflies;
Growth includes maturity through 500 copies and discovery endpoints of 10 Common,
10 Rare, 7 Epic and 3 Legendary species. All quests progress concurrently. No
cosmetic or Premium pack milestone reward is published. Pack rewards use the
immutable version-20 Standard/Enchanted contracts and remain unopened.

## Explicit release procedure

Back up the game database using the existing deployment process. Build/migrate
the server normally, then preview these commands against the intended deployment:

```powershell
forest backfill-progression
# If necessary, apply progression backfill in bounded batches first.
forest backfill-progression --apply
forest activate-milestones
```

Review the activation report and the rollout choices below before running
`forest activate-milestones --apply`. Activation validates the actual nonfixture
catalogue's 10/10/7/3 species and all three immutable version-20 pack contracts.
It refuses accounts whose step progression has not been initialized. Prices and
existing pack definitions are not changed.

After publication, preview/apply earned entitlements in bounded batches:

```powershell
forest backfill-milestones --limit 500
forest backfill-milestones --limit 500 --apply
```

Repeat while `hasMore` is true. Preview rolls back all writes. Backfill creates
earned/fulfilled records, never grants currency or packs. Each account is also
enrolled lazily under its owner lock, so it can safely use the feature before a
background backfill reaches it. Publication and backfill are repeat-safe.
The backfill report lists each examined owner and the exact earned reward bundles,
legacy mappings and supersession so preview can be reviewed before applying.

## Recorded rollout choices

These defaults make the implementation concrete and are visible in the activation
preview; no live activation was performed in the implementation session.

- The opening movement slot is Steps-only: 1,000 accepted lifetime steps.
- An activity day is 1,000 accepted steps OR 10 accepted supported workout minutes.
  Special daily/window/workout evidence starts at policy activation; lifetime
  accepted steps, hosted butterflies, earned maturity and permanent discovery are
  backfilled. Lower observations and device replacement do not repeat credit.
- The 5 km run and 60-active-minute workout are separate one-time pack quests.
  One workout can satisfy both. A first qualifying run already at 10 km fulfills
  the lower running tier through the Enchanted reward; the duration quest remains
  independent. If the 5 km tier was earned on an earlier accepted run, both running
  rewards remain earnable. Claim order cannot change this result. Growth caps do
  not invalidate an otherwise qualifying workout; overlaps, pauses, unsupported
  segments and baseline/window clipping still constrain eligibility.
- Existing claimed `first_movement`, `first_hosted`, `three_hosted`,
  `first_seedling`, and `first_maturity` fulfill `steps_1000`, `butterfly_1`,
  `butterfly_3`, `growth_first_seedling`, and `growth_mature_1`, respectively.
  Any legacy claim also fulfills New Beginnings. Existing funds/purchases/receipts
  remain intact; there are no automatic supplemental grants or clawbacks. An
  account without a legacy claim receives the new opening eligibility normally.
- Discovery rarity is frozen from the published policy's species map on the first
  milestone discovery credit; variants never add species credit. Already sold
  acquisitions survive through permanent catalogue-discovery records.
- Cosmetic components remain empty at Steps 1M/5M, Butterfly 100k and Maturity 500.
  A later release must decide prior-earner eligibility without reopening original
  pack/currency claims.

The finite initial reward budget, before any event or ordinary step/visitor income,
is shown below. Special's maximum assumes the lower run was earned on an earlier
workout, so both running tiers are legitimately earned. These totals do not model
time to maturity, pack draws, storage or collection completion:

| Track | Tokens | Bonus gems | Standard packs | Enchanted packs |
| --- | ---: | ---: | ---: | ---: |
| Steps | 16,500 | 101 | 2 | 6 |
| Butterfly | 21,150 | 33 | 1 | 0 |
| Growth (maturity + discovery) | 34,950 | 78 | 2 | 3 |
| Special | 1,500 | 15 | 3 | 2 |
| Total | 74,100 | 227 | 8 | 11 |

At the existing 5-gem Premium price, those 227 one-time bonus gems could fund 45
Premium purchases with 2 gems remaining, independently of step-earned gems.
The implementation preserves the requested tables; review this purchasing power
and combined garden/collection pacing before live activation.

## Claims, accounting and compatibility

The existing endpoint remains `POST /v1/me/milestones/{id}/claim`. Updated clients
send `X-Forest-Milestones: 1`; older clients receive no new milestone definitions
and cannot initiate new bundle claims. Existing legacy receipts still replay.

Summaries add track/category, scope, threshold, exact progress, reward packs/gems,
earning policy, eligibility, supersession, legacy fulfillment and event dates.
Definitions/earned reward bundles are immutable. Claims serialize on the existing
owner → garden → catalogue lock order and atomically issue every component.
Full pack storage grants nothing and retains the entitlement; opening a pack makes
room for retry, including with the original request ID. No reward opens or places
a plant automatically. Concurrent requests and alias UUIDs cannot duplicate a
claim. New alias receipts acknowledge their request UUID while retaining the same
awarded pack/event identities. Response compaction retains complete small milestone
receipts, and permanent claims remain authoritative.

`visitor_wallets.step_gems_earned` is the step-entitlement high-water mark.
`lifetime_gems_earned` now includes step plus milestone bonus grants. Reconciliation
checks each source and gem spending separately. Account responses expose
`stepGemsEarned` and `bonusGemsEarned`; the native validator accepts their sum rather
than incorrectly equating all gems to steps. The schema migration backfills the
step field from pre-existing lifetime earnings. An activated downgrade is refused
to preserve reward/accounting facts.

## Events

No event is automatically scheduled. `forest schedule-milestone-event file.json`
previews an immutable event; add `--apply` only after reviewing it. The JSON uses:

```json
{
  "event_id": "woodland_week_01",
  "name": "Woodland Week",
  "starts_at": "2026-12-01T00:00:00+08:00",
  "ends_at": "2026-12-08T00:00:00+08:00",
  "claim_until": "2026-12-15T00:00:00+08:00",
  "attribution": "collection_time"
}
```

These dates are an example, not a scheduled event. All four quests are available
at start: accepted growth on a planted sprout, 50 butterflies, 3 activity days and
5 activity days. Event days use their own accepted progress, independent of an
activity-day tier already completed before the event. Earning uses the half-open
start/end interval; claims must precede the separate claim deadline. Earned but
unclaimed entitlements remain stored/visible after that deadline with an unavailable
state, rather than being deleted. Recovery of expired entitlements requires a
deliberate future administrative policy; the initial release does not silently
reissue them.

The explicit `collection_time` choice counts actual welcomes/offline collections
during the event, including previously stored visitors. The authoring report calls
this out. No generation-time attribution is inferred from storage lots that lack
individual visitor timestamps. Overlapping events each count eligible actions;
their combined rewards must be budgeted before scheduling. Events are limited to
90 earning days. Inactive Event shows an empty state without a fictional timer.

## Validation

Run the full backend suite with `FOREST_TEST_DATABASE_URL` pointed at an isolated
PostgreSQL test admin connection. Tests only create/drop randomized `forest_test_*`
databases. Run `python scripts/validate_milestones_local.py --write-contract` from
the backend environment to regenerate the synthetic native fixture; omitting the
flag runs the same HTTP/accounting/recovery walkthrough without writing it.

Portable native checks are `python frontend/scripts/validate_frontend.py` and
`python frontend/scripts/check_swift_syntax.py` from the repository root. New native
contract tests cover bundles, source-aware gems, discovery endpoints and journal
state. Apple SDK compilation, XCTest, simulator screenshots, Dynamic Type,
VoiceOver and physical HealthKit acceptance still require `frontend/scripts/test-mac.sh`
and a Mac/iPhone. Windows parsing is not evidence that those checks passed.
