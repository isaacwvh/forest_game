# Garden items — permanent shop, resale and mixed editing

Source implementation: 15 November 2026, through stage 5. Native Xcode/device
acceptance and personal-game activation remain separate. The shop is permanent:
no daily rotation, scheduling, item skills or event item-claim UI is introduced.

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
- The bench costs **550 tokens**. Resale is **25%, rounded down: 137 tokens**.
  A placed copy may read its quote; only a stored copy may be sold, after exact
  price confirmation. Sale removes that copy and frees one ownership slot.
- Purchases pin the unit price and resale policy per copy. Pre-commerce gifts
  adopt the immutable 550-token definition valuation at explicit publication;
  quote reads do not write or reprice them. Future offer prices cannot change
  existing copies' values. Replaying a sold copy's original grant cannot restore it.

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

Selling a stored copy makes room for a later claim. A failed or uncertain purchase
or sale retains its original account-scoped request for durable recovery.

## Database and maintenance

Migration `0018_garden_items` introduced ownership and placement. Current head
`0019_item_commerce` adds immutable valuation and sale facts and permanent offers:

| Table | Retention classification |
| --- | --- |
| `item_definitions` | Shared, immutable versioned configuration |
| `item_identities` | Permanent acquisition/recovery facts |
| `owned_items` | Current state |
| `item_placements` | Current state |
| `item_value_definitions` | Immutable shared default gift valuations |
| `item_valuations` | Durable, immutable per-copy valuation snapshots |
| `item_shop_offers` | Versioned shared configuration; only retirement is mutable |
| `item_sales` | Permanent positive sale accounting and receipts |

Composite foreign keys enforce owner equality for ownership and placement.
Definitions and acquisition identities are immutable. Migration does not publish
content, grant a bench, reset an account or modify existing plant/wallet data.
Downgrade refuses after acquisitions exist; restore a pre-item backup rather than
discarding permanent facts.

Mixed edits retain operation `garden_edits`, its existing seven-day response cache,
compact completion recovery and lock order. Empty `itemActions` is excluded from
request hashing to preserve historical plant-only hashes. No new periodic job,
high-volume history family is introduced. Purchases record negative token spending
in `collection_events`; sales record positive income in `item_sales`. Wallet
reconciliation includes both without counting sales as hosted butterflies.
`item_purchase` and `item_sell` use seven-day response compaction and recover exact
receipts from permanent financial records, including after a copy is sold.

## API and compatibility

- `GET /v1/me/items?limit=100&after=UUID`: owned copies, global item capacity and
  pagination. Both placed and stored copies appear in this owner-only read.
- Collection summaries add `itemOffers` and `itemCapacity` alongside existing packs.
- `POST /v1/me/item-purchases`: requestId, offerId, offerVersion and quantity 1–20.
- `GET /v1/me/items/{ownedItemId}/sale-quote`: read-only quote, even while placed.
- `POST /v1/me/items/{ownedItemId}/sell`: requestId, valuationVersion and expectedTokens.
- New commerce requests require `X-Forest-Item-Commerce: 1`; completed requests
  recover before current offer/capacity/client checks. Old item clients keep their
  read/edit compatibility. Native purchase and sale recovery share the existing
  collection journal, wallet-version guards and account isolation.
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
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-item-shop
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-item-shop --apply
docker compose -f backend/compose.yaml run --rm --no-deps api forest grant-bench YOUR_USERNAME
docker compose -f backend/compose.yaml run --rm --no-deps api forest grant-bench YOUR_USERNAME --apply
docker compose -f backend/compose.yaml up -d --wait
```

The shop publication command previews by default. `--apply` publishes the fixed
550-token offer and 25% resale policy without granting or spending anything.
Repeating publication does not re-enable a retired offer. Migration alone does not
publish the shop. Back up first and rebuild the migration and maintenance images.

The first grant command previews and rolls back. `--apply` publishes the bench
definition and grants one stored copy to that exact account. Repeating it returns
the same copy without resetting placement. Capacity applies to this command too.
Do not run seed/reset commands. Existing maintenance opt-in configuration remains
unchanged; rebuilding its image gives it the same metadata as the API.

In the updated app: **Edit → Storage → Items → Wooden Bench → Place**, move it to
valid clear ground, then Apply. Inventory → Items displays each owned copy and its
compact icon/description inspector with sale controls. All three Inventory tabs
share the Inventory title; the standalone Packs menu keeps its contextual title.
Shop retains packs first, then decorations. Items share plant card image sizes,
frames, selection popups, toolbar icons and position/rotation controls.

## Stages 1–4 validation (historical)

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

## Stage 5 validation — 15 November 2026

- Full isolated PostgreSQL suite: **694 passed, 3 skipped** in 668.66 seconds.
  The skips are existing opt-in physical-storage benchmarks.
- Final focused commerce suite: **18 passed** in 70.97 seconds, including a
  populated `0018` → `0019` upgrade preserving the existing placed bench and
  account state. This includes an additional migration test after the full run;
  the counts are not additive.
- Purchase/sale rollback, concurrent capacity/funds, immutable per-copy pricing,
  placed-sale rejection, receipt compaction/replay, source-grant replay after sale
  and wallet reconciliation pass. Activity, skills, visitors and launch HTTP smoke
  walkthroughs also pass.
- Ruff, item/HTTP asset contracts, generated frontend project validation and all
  100 Swift syntax parses pass. Native tests are added but require Xcode; follow
  [native acceptance](../frontend/ITEMS_ACCEPTANCE.md).
- Docker image validation remains unavailable: the engine returned HTTP 500.
  No personal database or running game service was changed for Stage 5.

Stage 6, random stock, schedules and item skills remain unimplemented. No push or
remote CI was requested or performed for Stage 5.
