# B7 collection contract

The implemented slice is **visitor tokens → unopened packs → owned plants**.
Tickets are superseded. All test offers are immediately available. Permanent
unlocks, milestone rewards, pity, duplicate conversion and social features are
deferred. Exchange supports pack items only until another item type has defined
ownership/use semantics. Every pack awards one sprout to Storage.

## Setup

Apply Alembic `0004_collection` explicitly before starting the updated API. Run
`forest seed-dev` in the existing local/test environment to publish two fixture
offers without changing balances, growth, placements, enrolment or accounts:

| Offer | Token cost | Contents |
| --- | --- | --- |
| Woodland | 5 | Common standard oak 75%; Rare blue oak 20%; Legendary vined oak 5% |
| Blue Oak | 8 | Blue oak 100% |

These values are **unapproved development balance**. The seeder labels oak
variants with the corresponding provisional rarity and retains existing profile
values. Repeating it never grants funds/packs, resets owned copies or reactivates
a retired offer. Assets remain bundled; new artwork needs an iOS asset release.

## HTTP routes

All routes require the current authenticated game account.

| Route | Contract |
| --- | --- |
| `GET /v1/me/collection` | `tokenBalance` string, `economyVersion` integer, current `offers` including exact pack contracts |
| `POST /v1/me/exchanges` | `{requestId, offerId, offerVersion, quantity}`; quantity is a strict integer 1–20 |
| `GET /v1/me/packs` | Unopened `packs` and `nextCursor`; `limit` 1–100, optional `after` UUID |
| `GET /v1/pack-definitions/{id}/versions/{version}` | Exact immutable contents, integer rarity weights and their total |
| `POST /v1/me/packs/{ownedPackId}/open` | `{requestId}`; returns the committed opening and owned `plant` |
| `GET /v1/me/pack-openings` | Newest-first `openings` and `nextCursor`; same pagination limits |
| `GET /v1/catalog` | Published plant metadata, four stage assets, profile definitions and placement geometry |

Exchange receipts retain accepted offer/version, total spent and every acquired
pack ID. Opening receipts retain pack/version, selected rarity, plant and profile
IDs, token balance and economy version. `ownedPackId` identifies one purchased
unit; `packId` identifies its shared definition. All bigint amounts use strings.

Errors include `invalid_request` (422), `insufficient_tokens`, `stale_offer`,
`amount_overflow`, `idempotency_conflict` (409), owner-safe `pack_not_found` (404),
`invalid_cursor` (400), `invalid_pack` (409), `pack_unavailable` (503), and the
existing authentication/account/rate-limit errors.

## Transactions and retries

Writers serialize on user → garden → catalogue, consistent with B6. The database
clock is read after those locks. Pack spending does not change visitor production,
so exchange/open do not introduce a visitor-context boundary or activate B6.

Exchange atomically debits `visitor_wallets.tokens`, appends one negative
`collection_events.token_delta`, creates the requested `owned_packs` and saves
the receipt/API request. Opening atomically records one `pack_openings` row and
creates one zero-growth, unplaced `owned_plants` row. Pinned profiles come from
the purchased pack contract, not current species defaults. Duplicates remain
independent copies. A full garden does not block opening.

Completed requests replay before current offer/configuration/quota checks.
Reusing a UUID for changed input fails. Opening an already opened owner pack with
another UUID returns its original receipt and plant, including the original
request ID. Unique pack/plant/event constraints prevent duplicate grants.
Original collection-event receipts survive deletion of generic request-cache
rows. Generic API request rows must be retained for cross-operation UUID history;
no receipt-cleanup process is introduced by B7.

Reconciliation is `visitor earning entries + collection event token deltas =
current token balance`. Hosted counters change only through B6 rewards. Every
confirmed visitor reward, exchange and first opening increments
`visitor_wallets.economy_version`. Replay does not increment it. The native wallet
accepts only newer economy versions, so older receipts cannot rewind balances.
The visitor timeline version remains separate.

## Editing packs and offers

Use trusted CLI `forest publish-pack path/to/publication.json`; there is no
client-accessible authoring route. See `spec_examples/pack-publication.example.json`.
The publisher validates strict weights, nonempty positive-weight rarity pools,
unique species/variant outcomes, rarity agreement, profile references, fixture
policy and all four stage records before committing. Each outcome carries the
resolved immutable growth/behaviour/attraction profile references.

1. Edit explicit outcome membership and increment the pack version.
2. Keep rarity weights unchanged to preserve rarity rates. Within each rarity,
   outcomes have equal probability: `rarity weight / total / outcome count`.
3. Increment the offer version to sell the revised pack or change its price.
4. Publish once. Existing packs retain their previous version and definitions.
5. To stop sales, use `forest retire-offer woodland --version 1`. Old packs stay
   openable. Retiring removes the offer from the shop, not the catalogue plant.

The sampler uses `secrets.randbelow`: rarity first, then one outcome in a stable
sorted pool. Membership never changes rarity weight. No live enabled-plant query
defines an acquired pack. Empty tiers cannot silently redistribute probability.
Publication is immutable; changing catalogue defaults does not alter old pack
profiles. Relational member references retain variants/profiles, and database
triggers protect published stage assets and manifest references. Remove a plant
from **new pack versions** to retire it from draws; do not delete its historical
definition/assets or disable its planting support. Disabled plants retain old
pack award eligibility, while existing general planting-disable policy remains.

## Native recovery and validation

The collection journal is scoped to server/game user. Exact request bytes and
UUID are atomically persisted before send. Unknown outcomes retain the pending
operation; definitive rejections clear it; idempotency conflicts retain it for
inspection. A committed result is persisted with pending removal in one write.
The latest result survives relaunch; history recovers other committed openings.
Authentication refresh reuses the same bytes. Detached account responses cannot
reach another account. The garden refreshes Storage after an award.

`test_collection.py` covers exact rarity boundaries/pool edits, strict inputs,
reference validation, overspending, distinct-request opening races, ledger/hosted
reconciliation, rollback, receipts, retirement, profile pinning and pagination.
Migration checks cover existing B6 state and full downgrade/reupgrade parity.
`smoke_visitors.py` completes the real HTTP visitor → earned tokens → exchange →
opening loop and restarts Uvicorn before replaying receipts. Its export flag
produces synthetic native fixtures. Mac tests and iPhone acceptance are separate
from Windows syntax/resource checks; use `frontend/F7_COLLECTION_ACCEPTANCE.md`.
