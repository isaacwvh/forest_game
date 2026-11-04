# Plant capacity and selling

Source implementation, 5 November 2026. Requires explicit migration to
`0012_inventory_management`; the personal game database is not upgraded by tests.
Native Xcode/device validation is separate from Windows portable validation.

## Rules

- Maximum **50 live owned plants**, including the original starter and all
  planted/stored duplicates. There is no additional storage-only limit.
- Maximum **20 planted copies**, also subject to the existing geometry rules.
  Existing over-limit layouts can move/rotate/store/swap; they cannot increase
  the over-limit count. Existing owned plants are never discarded at upgrade.
- Maximum **50 unopened packs**. Exchange checks the entire requested quantity
  before spending. Existing packs remain usable after offer retirement.
- At full plant capacity, opening is blocked before selecting an outcome or
  consuming a pack. Completed-opening retries recover before checking capacity.
- Pack purchases can proceed with full plant capacity if pack space remains.
- All gameplay writers serialize on the account lock. Internal awards use the
  same ownership guard. Account ownership and existing geometry remain enforced.
- The settings are `FOREST_PLANT_CAPACITY`, `FOREST_PLANTED_CAPACITY` and
  `FOREST_PACK_CAPACITY`; default values are 50/20/50, also exposed by Compose.

## Selling and valuation

My plants inspection offers sale for stored copies only, with an explicit
confirmation and exact token amount. Store a planted copy using the existing
membership/activity/visitor settlement path first. The original starter cannot
be sold. Discovery, lifetime progression and awarded milestones remain permanent.

`plant-resale-v1` defines Common/Rare/Epic/Legendary bases of **240/480/720/960**.
Standard variants use 10000 basis points (1.0); Blue Oak 12500; Vined Oak and
Golden Moonwillow 15000. Other nonstandard variants need an explicit valuation
publication before sale is available. Species rarity is frozen at acquisition,
never inferred from deprecated variant-rarity metadata or a pack's odds.

```
p = clamp(saved growth / pinned adult threshold, 0, 1)
tokens = floor(rarity base * variant multiplier * (0.25 + 0.25*p))
```

The integer implementation performs one final floor, including fractional water
micro-units. A 400-water Golden Moonwillow with an adult threshold of 1000 earns
378 tokens; its adult value is 540. Water cannot raise resale beyond adulthood.

Backfill snapshots existing species rarity and explicit variant multipliers.
Historical development-unbalanced Oak/Moonwillow map explicitly to Common/Epic;
an already valid species rarity is respected. Old pack receipts remain unchanged.
Price changes require a new immutable valuation policy; v1 receipts and identity
snapshots cannot be edited. Publishing future packs/rewards must review resale
economics, including legacy grants. All v1 maximum payouts are below the current
1200-token Woodland price; this is recycling, with growth now an indirect token
source. It does not increment hosted-visitor counters or pay a milestone again.

## API and recovery

- `GET /v1/me/capacity`: global owned/planted/stored counts, unopened packs and limits.
- `GET /v1/me/inventory`: adds the same capacity snapshot, independent of pagination.
- `GET /v1/me/collection`: adds capacity alongside the versioned wallet and offers.
- `GET /v1/me/plants/{id}/sale-quote`: read-only amount and valuation breakdown.
- `POST /v1/me/plants/{id}/sell`: requestId, valuationVersion, expectedTokens and
  expectedGrowthMicroUnits. Expected amounts are digit strings. Server values
  determine payout; mismatches reject with `stale_sale_quote`.

Sale locks account, garden and copy, verifies stored status, credits the wallet,
increments economy/state versions, removes live state and saves a compact sale
fact in one transaction. Wallet overflow or any other failure rolls it all back.
The native journal saves the exact request before sending; uncertain results
reuse that UUID across relaunches and account/server scopes.

Sale responses use the existing seven-day ordinary cache and durable completion
protocol. Exact sale facts recover even after response cleanup, without needing
the live plant. Original pack openings still replay their historical result after
sale; they never restore or re-award the copy. The native wallet accepts only newer
economy versions. A recovered sale refreshes current inventory without replaying
the pack-opening ceremony.

## Data and maintenance

`plant_identities` holds the original UUID, owner, unique acquisition identity and
small pinned valuation. An insert trigger creates it for every live copy, including
trusted direct grants. Historical pack openings, recent growth credits and compact
growth summaries reference this identity instead of `owned_plants`.

`plant_sales` is immutable positive sale accounting, with one sale per copy and
one owner/request identity. Sales are included in maintenance reconciliation:
visitor/milestone/conversion credits + sale credits + collection spending = wallet.
Sale facts are separate from visitor earning facts and collection spending, whose
existing constraints are preserved. A sold UUID cannot be inserted as a live copy
again, and acquisition uniqueness survives removal of its live state.

Existing seven-day response, 30-day growth and pending-recap protections continue.
No historic accounting, discovery or pending recap is cascade-deleted on sale.
The 50-copy cap bounds live state, not lifetime identity/receipt/summary storage;
new tables are classified as durable recovery in the usage report.

The migration backfills before changing foreign keys. Downgrade is permitted
before any sale; after a sale it refuses before DDL, because the old schema cannot
represent a retired copy without resurrection or loss of accounting. Restore a
pre-sale backup for an operational rollback across that boundary.

## Local upgrade and acceptance

Back up the game database, then use the existing documented source-upgrade flow:

```powershell
docker compose build api migrate maintenance
docker compose run --rm migrate
docker compose up -d --wait --wait-timeout 90
```

These commands are instructions, not evidence that the personal database was
upgraded. Run them from `backend/` when deploying the new source. Native acceptance:

1. Verify serif Plants/Planted/Stored counts on sage parchment, section count
   badges, no dot separators, VoiceOver and accessibility-size vertical reflow.
2. Check global counts with paginated/filtered inventories and cached-data notices.
3. Fill plants: opening is disabled with a reason; owned packs remain safe. Fill
   packs: purchase is disabled, and quantity cannot exceed remaining space.
4. Sell a stored copy after reviewing price and confirmation. Check wallet, counts,
   removal, permanent discovery and original starter protection.
5. Interrupt before/after confirmation, kill/relaunch, lose network, retry and
   switch accounts. Confirm one sale/payout, retained uncertain request and no
   effects or old wallet balances applied to another account.
6. Store a skill source first; verify the existing settlement/skill behavior. Sell
   a copy referenced in a pending recap and verify it is never watered/recreated.

Automated execution evidence is recorded in `VALIDATION.md` after validation.
