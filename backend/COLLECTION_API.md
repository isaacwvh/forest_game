# B7 collection contract

The implemented slice is **visitor tokens → unopened packs → owned plants**.
Tickets are superseded. All test offers are immediately available. Permanent
unlocks, milestone rewards, pity, duplicate conversion and social features are
deferred. Exchange supports pack items only until another item type has defined
ownership/use semantics. Every pack awards one sprout to Storage.

## Setup

Apply Alembic `0005_species_draws` explicitly before starting the updated API. Run
`forest seed-dev` in the existing local/test environment to publish two fixture
offers without changing balances, growth, placements, enrolment or accounts:

| Offer | Token cost | Contents |
| --- | --- | --- |
| Woodland v2 | 5 | Common 100%; Oak/Moonwillow 50/50; then Oak 75/20/5 or Moonwillow 90/10 variants |
| Moonwillow | 8 | Common Moonwillow 100%; Standard 90%, Golden 10% |

These values are **unapproved development balance**. Both species are Common.
Oak retains its existing profiles; Moonwillow has dedicated neutral profiles and
a provisional 1.100-garden-unit clearance radius. The legacy variant-rarity field
is retained for schema-1 publication/history and is not used by schema 2. Repeating it never grants funds/packs, resets owned copies or reactivates
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
| `GET /v1/me/catalog-discovery` | Account-owned permanent variant/stage discoveries, catalog version and monotonic discovery version; sprouts are unconditionally visible |

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
   species have equal probability, then variant weights apply:
   `P(variant) = rarityWeight / rarityTotal / speciesCount × variantWeight / variantTotal`.
3. Increment the offer version to sell the revised pack or change its price.
4. Publish once. Existing packs retain their previous version and definitions.
5. To stop current sales, use `forest retire-offer woodland --version 2`. Old packs stay
   openable. Retiring removes the offer from the shop, not the catalogue plant.

New definitions use `schemaVersion: 2`: each rarity contains `species`, each
with `speciesId` and weighted `variants` containing `variantId`, `weight` and
pinned `profiles`. Species cannot carry weights or occur twice across tiers.
The sampler uses `secrets.randbelow`: rarity first, a species uniformly, then a
weighted variant in stable sorted order. Schema 1 retains its original flat
outcomes sampler; existing JSON contracts/receipts are never rewritten. Membership never changes rarity weight. No live enabled-plant query
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


## Grouped catalogue and rollout

GET /v1/catalog now exposes `rarity` on species. Variants retain deprecated legacy
rarity metadata for compatibility. The native catalogue uses one species row,
variant inspection within it, and current-offer probabilities labelled by pack
version. Old owned-pack probabilities remain available in Draws. F8.7 adds catalog
artwork discovery below; shared definitions and pack probabilities remain readable.

Run the migration before seeding. Install the matching updated iOS build before
testing newly published schema-2 offers; the earlier iOS build only understands
schema 1. The new build reads both. `forest seed-dev` publishes Woodland v2 and
retires Woodland v1/Blue Oak sales without migrating acquired packs or changing
existing owned-copy progress/currency. A repeat call never reactivates retired
offers. The catalogue version changes to development-woodland-v2 so old cached
placement rules are refreshed. No live game database is changed by automated tests.

## Catalog stage discovery — F8.7

Alembic `0009_catalog_discovery` adds `catalog_stage_discoveries` and
`catalog_discovery_state`. The discovery key is owner/species/variant/stage;
only seedling, young and adult require rows. All sprouts remain visible without
ownership. Standard and sibling variants never share later-stage unlocks.

The migration backfills every planted/stored copy using its pinned growth profile,
including intermediate stages and copies outside the first inventory page.
Duplicates union discoveries within the exact variant. Backfill timestamps record
the upgrade time, not an invented historical first-reached time. Invalid pinned
profiles abort the upgrade. A repeated backfill adds only missing discoveries and
never resets versions. Downgrade refuses to discard earned discoveries.

`GET /v1/me/catalog-discovery` authenticates the active owner and returns a complete,
sparse snapshot: `userId`, `catalogVersion`, `discoveryVersion`, and `entries`
containing `speciesId`, `variantId` and stage arrays in growth order. Missing entries
mean undiscovered only after a successful snapshot. No client unlock endpoint exists.

Activity sync inserts discoveries and advances the independent version once when
new stages are recorded, in the same transaction as saved growth. Replay and no-new-
discovery syncs do not mint versions. Typed workouts and all accepted daily metrics
use the same writer; the trusted adult fixture grant also reconciles discovery.
Pack opening still grants only a sprout; recap presentation/ack never grants discovery.

For an existing installation, pause old growth/grant writers, explicitly run
`alembic upgrade head` from the configured backend environment, deploy/restart the
matching backend, then install the matching iOS build. The application never applies
migrations or seeds on startup. No live/game database was upgraded by source tests.
Old iOS builds still show their old catalog previews; current builds conceal later
art if the endpoint is unavailable. Use `frontend/F8_ACCEPTANCE.md` for device checks.
