# Garden items — ownership, bench and mixed editing

Source implementation: 15 November 2026, stages 1–4. Native Xcode/device acceptance
and activation against the personal game remain separate. No shop, daily rotation,
item skills, event item-claim UI or item resale is activated by this increment.

## Rules

- Each copy has its own UUID and placed/stored state. Models/icons are shared.
- Item capacity is 50 total placed plus stored copies, configured independently by
  `FOREST_ITEM_CAPACITY`. Items do not consume plant or pack capacity. No additional
  placed-item limit is introduced; mixed clearance and garden boundaries apply.
- The Wooden Bench description is exactly: "a basic bench, allows weary travelers
  to find rest in your garden". It is Common, has radius 0.900 garden units and
  contributes no attraction, growth, plant counts or skills.
- Its existing Y-up USDZ and 384×448 icon are bundled. The 1.6×0.62 metre solid
  footprint fits within the reserved circle at every yaw.

## Capacity and future rewards

All grants use `items.grant` inside the enclosing reward transaction. It locks the
account and garden, checks the entire quantity before creating copies, and uses a
permanent source/reference/ordinal identity to prevent duplicate grants.

At capacity, grant raises `item_capacity_full`. The enclosing transaction must roll
back all components and must not mark the event reward claimed. The entitlement
remains available for collection after space is available. Nothing is discarded,
queued as a hidden owned copy, or granted beyond the limit. Event-specific item
claims are future work; the shared grant guard and whole-transaction rollback are
implemented and tested now. Replaying an already-completed grant returns the same
identities before checking current capacity.

The current lifecycle slice does not yet provide item selling. The proposed resale
contract remains later work; no token valuation or payout has been invented for the
bench grant.

## Database and maintenance

Migration `0018_garden_items` adds only:

| Table | Retention classification |
| --- | --- |
| `item_definitions` | Shared, immutable versioned configuration |
| `item_identities` | Permanent acquisition/recovery facts |
| `owned_items` | Current state |
| `item_placements` | Current state |

Composite foreign keys enforce owner equality for ownership and placement.
Definitions and acquisition identities are immutable. Migration does not publish
content, grant a bench, reset an account or modify existing plant/wallet data.
Downgrade refuses after acquisitions exist; restore a pre-item backup rather than
discarding permanent facts.

Mixed edits retain operation `garden_edits`, its existing seven-day response cache,
compact completion recovery and lock order. Empty `itemActions` is excluded from
request hashing to preserve historical plant-only hashes. No new periodic job,
wallet entry or high-volume history family is introduced. Existing maintenance
compaction preserves item ownership and recovers completed edits; tests exercise it.

## API and compatibility

- `GET /v1/me/items?limit=100&after=UUID`: owned copies, global item capacity and
  pagination. Both placed and stored copies appear in this owner-only read.
- Garden reads/receipts add `items`; plant collections and skill calculations
  remain plant-only.
- Existing garden edit requests retain `actions` for plants and may add
  `itemActions` for items. An item action contains `itemId` (the owned-copy UUID)
  and `place`, `move`, `rotate` or `store`. Place/move require coordinates; place
  and rotate require yaw. Numeric precision and strict JSON rules match plants.
- The complete final mixed layout is validated and committed atomically under
  one layout version. Failed edits leave placements, versions and receipts intact.
- Updated clients send `X-Forest-Items: 1`. Completed requests replay first.
  Otherwise older clients cannot submit item actions or edit gardens containing
  placed items they cannot display; they receive an update-required response.
- Optional native fields keep old receipts/caches readable. Pending edit bodies
  and UUIDs are retained unchanged across retries/relaunches.

## Local activation and first bench

The local Docker engine returned HTTP 500 during implementation, so no personal
database migration, content publication or named-account bench grant was performed.
All executed database validation used disposable `forest_test_*` databases.

Build the updated iOS app with the bench resources. Back up the intended game
database using the existing backup procedure. Once Docker is healthy, run these
from the repository root, checking each exit code and stopping on failure:

```powershell
docker compose -f backend/compose.yaml stop api maintenance
docker compose -f backend/compose.yaml build api migrate maintenance
docker compose -f backend/compose.yaml up -d --wait db
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml run --rm --no-deps api forest grant-bench YOUR_USERNAME
docker compose -f backend/compose.yaml run --rm --no-deps api forest grant-bench YOUR_USERNAME --apply
docker compose -f backend/compose.yaml up -d --wait
```

The first grant command previews and rolls back. `--apply` publishes the bench
definition and grants one stored copy to that exact account. Repeating it returns
the same copy without resetting placement. Capacity applies to this command too.
Do not run seed/reset commands. Existing maintenance opt-in configuration remains
unchanged; rebuilding its image gives it the same metadata as the API.

In the updated app: **Edit → Storage → Items → Wooden Bench → Place**, move it to
valid clear ground, then Apply. Inventory → Items displays each owned copy and its
simple icon/description inspector. Plants and Packs remain accessible from the
Inventory selector; the existing Packs menu also remains available.

## Executed validation

- Isolated PostgreSQL full suite: 666 passed, three opt-in storage benchmarks
  skipped. This run included the initial item tests and all migration regressions.
- Additional item tests cover HTTP contracts, account isolation, grant identity,
  full-capacity/whole-reward rollback, concurrent grants, mixed swaps, old-client
  gating, maintenance compaction and malformed coordinates. See the final recorded
  item-suite result in backend/VALIDATION.md.
- Ruff lint/format, dependency consistency, portable frontend validation, all Swift
  syntax parsing, Woodland resource regression and `tools/validate_items.py` pass.
- The expanded item suite passes all 16 cases. Existing activity, skill, visitor
  and launch HTTP smoke walkthroughs pass; a Windows startup-probe reset required
  a readiness retry fix in the launch smoke helper.
- Native `ItemTests` adds HTTP decoding, pending-request relaunch/replay, preview
  collision rejection and real bench import/clone checks. These require Xcode and
  have not been run on Windows. See [native acceptance](../frontend/ITEMS_ACCEPTANCE.md).

No push or remote CI run is part of this increment.
