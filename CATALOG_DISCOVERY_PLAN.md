# F8.7 — Catalog discovery implementation plan

Prepared 29 October 2026 against the V1 working specification and current
implementation. **F8.7 source implemented locally, 29 October 2026; native/device
acceptance pending.** Includes an explicit migration/backfill, transactional server
discovery and account-scoped catalog presentation/cache. No live game database is
automatically upgraded, no asset package changes are needed, and nothing is pushed.
The original implementation brief below remains the requirement/acceptance reference.
Executed results belong in backend/frontend VALIDATION.md; F8.6 remains accepted.

## 1. Findings and change in direction

- [The working specification](forest_game_v1_spec.md) establishes four stable
  stages, independent growth per owned copy, immutable pinned growth profiles,
  current-stage storage thumbnails and shared stage/variant artwork.
- [The implementation plan](IMPLEMENTATION_PLAN.md) previously proposed discovery
  per account/species/stage, shared when **any variant** reached a stage. This
  proposal supersedes that sharing rule: discovery belongs to the exact variant.
- `frontend/MovementForest/Features/CollectionScreen.swift` already groups the
  catalog into one row per species, uses a standard-or-first-variant sprout for
  its row portrait, and provides a variant selector inside species detail.
  Its stage disclosure currently renders every stage with `CatalogThumbnail`.
- `backend/src/forest_api/services.py::read_catalogue` returns shared metadata
  and all stage assets. There is no saved per-account stage-discovery state.
  `activity.py::sync` already serializes account/garden changes, snapshots
  pre-credit stages, evaluates pinned profiles and saves growth/recaps atomically.
- `CollectionCoordinator` is account-bound and already rejects updates after
  deactivation. `AccountDiskStore` provides server/user-scoped persistence.
  Reuse those boundaries; discovery is distinct from the collection mutation journal
  and F8.6's cosmetic effect history.

This is a small cross-stack progression feature within polish, with a database
and API addition. Hiding images solely from the current device's inventory cannot
preserve discoveries across devices, pagination or account upgrades.

## 2. Product behavior

The catalog remains browsable before ownership. The player discovers later-stage
appearances by growing their own copies of that exact species and variant.

| Surface / state | Required appearance | Unlock rule |
| --- | --- | --- |
| Species row portrait | Full-color sprout, always | None; retain standard variant, falling back to the first available variant |
| Selected variant's detail portrait | Full-color sprout of that variant, always | None; never replace it with the highest discovered stage |
| Sprout inside the stage list | Full-color sprout, always | None, including unowned species and variants |
| Seedling, young or adult not yet discovered | Solid silhouette with “Not discovered” and a lock indicator | Grow an owned copy of this exact variant to that stage |
| Seedling, young or adult discovered | Full-color artwork for that exact stage/variant | Permanent after the first confirmed unlock |

“Blanked out” means a flat silhouette that conceals the colored artwork and
internal visual detail, not an empty row. Sprout visibility is a free preview;
it does not mean the player owns the plant or has earned a discovery.

Rules:

1. The durable discovery key is **account + species + variant + stage**.
   Standard is an ordinary variant key, with no special sharing privileges.
2. Any duplicate copy of the same species/variant can unlock a stage. Copies
   still grow independently; discoveries do not grant growth to another copy.
3. A single credit that advances sprout → adult unlocks seedling, young and adult
   together for that variant. Threshold equality counts as reaching the stage.
4. Use each copy's **pinned growth profile**, including historical versions and
   variant overrides. A later edit to catalog defaults never relocks earned art.
5. Storing, moving, replanting, inactivity, logout, reinstall and switching devices
   never remove a server-saved discovery. Stored copies receive no new growth.
6. Viewing art, selecting a variant, inspecting packs, visiting another garden,
   opening a pack into a sprout or dismissing a recap does not unlock later stages.
7. Discovery does not gate names, rarity, descriptions, stage labels, growth and
   attraction values, activity multipliers, skills, pack odds or pack access.
   Those remain readable as today. Art visibility and ownership are separate.

Example after growing Standard Oak to adult and Vined Oak to young:

| Oak variant | Sprout / portrait | Seedling | Young | Adult |
| --- | --- | --- | --- | --- |
| Standard | Visible | Visible | Visible | Visible |
| Blue, never grown | Visible | Silhouette | Silhouette | Silhouette |
| Vined | Visible | Visible | Visible | Silhouette |

Growing Blue to seedling changes only Blue's seedling cell. A new Standard
duplicate starts at sprout while Standard's catalog stages stay discovered.

## 3. Catalog presentation

Preserve the existing native list, search, rarity filter, species grouping,
variant selector, disclosures, typography and forest-green accent. Add the selected
variant's sprout portrait to its detail header. Keep the four stage rows in their
existing growth/attraction disclosure, with equal image frames for every state.
Do not introduce a new gallery layout, ownership gate or additional reveal ceremony.

Add one short explanation near the stage list: **“Grow this variant to discover
its later stages.”** Each locked row retains its stage name and displays **“Not
discovered”**. Its accessibility description can be “Blue Oak, Adult, not
discovered. Grow a Blue Oak to the adult stage.” Revealed rows identify the
variant/stage and their discovered state. Keep explanatory text accessible; do
not rely on color or the lock icon alone. The always-visible sprout is labelled
“Always visible” if status text is needed, rather than “Discovered”.

Create a catalog-specific image presentation path. For a locked stage, render
only the PNG's alpha silhouette in a single opaque neutral fill, with no original
colors, shading or texture. Desaturation, dimming or a translucent overlay alone
would still expose the art. Reuse the existing transparent PNGs; no Blender
exports, extra stage models or per-species silhouette files are needed.

Choose the visibility branch before displaying the image so a full-color frame
cannot flash during loading, variant changes or navigation. Do not offer an
enlarged/full-color or 3D catalog preview for locked stages. Missing artwork uses
a generic plant/question-mark fallback with the same true discovery status;
missing art is never described as an undiscovered stage. An unlocked image that
fails to load remains unlocked and uses an “Image unavailable” fallback.

Use a restrained immediate replacement when confirmed progress arrives; no new
animation is required. Reflow for Dynamic Type and retain 44-point controls,
VoiceOver reading order and Reduce Motion behavior. Keep the portrait/light
release baseline and mounted Garden/camera unchanged.

## 4. Persistent server state

Add one Alembic revision after the current `0008_scheduled_visitors` head; verify
the actual head at implementation time. Proposed logical records:

| Record | Fields and constraints |
| --- | --- |
| `catalog_stage_discoveries` | Composite primary key `(owner_id, species_id, variant_id, stage)`; owner FK; composite species/variant FK; stage restricted to `seedling`, `young`, `adult`; server `recorded_at` timestamp |
| `catalog_discovery_state` | `owner_id` PK/FK; nonnegative `version bigint`, initially 0, incremented once per transaction that inserts at least one discovery |

Sprouts require no rows: their visibility is unconditional. Rows record earned
visual access, not current growth, placement, ownership counts or reward balances.
Keep logical stage identity stable across catalog/profile/asset versions; those
versions are not part of the unlock key. Retiring a catalog entry must preserve
its discovery rows; unpublishing does not delete its shared definition. Account
deletion includes these records under the account's deletion workflow.

Use an idempotent helper that inserts missing stages through an owned copy's
confirmed reached stage, with conflict-safe uniqueness. It runs inside the
caller's transaction and never commits independently. All writers follow the
existing user → garden → catalog/owned-copy lock order; version updates occur
under the same account serialization. Repeated helper calls do not increment
the version when no row was inserted. No dependency on UI effects or recap ack.

### Growth integration

In `activity.py::sync`, after confirmed per-copy growth is computed, derive reached
stages with the existing stage calculation and each copy's pinned profile. Insert
new discovery rows before committing the growth, recap and resulting state.
Evaluate all plants changed by the accepted daily metrics and typed workouts,
including intermediate stages crossed across multiple day buckets in one sync.

Rollback must roll back growth and discovery together. Retried/replayed syncs
must neither duplicate discoveries nor mint versions. Preserve the existing
saved-response replay contract and visitor old-state settlement/future-context
ordering. Discovery itself never changes wallet, attraction, skills or layout.

New accounts create their version-0 discovery state during provisioning. Starters
and ordinary pack openings grant sprouts and insert no earned-stage discovery.
Audit trusted development/provisioning tools too: `skill_seed.py` can directly
mature a fixture copy. Any supported direct-growth tool must use the same helper
or an explicit reconciliation in its transaction; it cannot silently bypass the
ledger. Do not refactor the existing pack sampler or pinned-profile award path.

### Existing-account backfill

1. Inspect **all** owned copies, stored and planted, without using the paginated
   inventory endpoint. Resolve their pinned growth profiles and current water.
2. For each copy, insert seedling/young/adult up to the reached stage. Union
   duplicates within the same account/species/variant; never union variants.
3. Initialize every account's state, including accounts with no later-stage
   discoveries. Give accounts with inserted discoveries a positive version.
4. Mark timestamps as when the backfill **recorded** the discovery; do not invent
   an exact historical first-reached time from today's progress.
5. Verify reruns are no-ops and keep existing identities, profiles, water,
   transforms, wallets, packs, receipts and recaps unchanged. Invalid/missing
   pinned profiles fail with an actionable report instead of revealing all art.

Previously being able to browse every stage is not an earned unlock. Existing
players keep stages supported by their actual saved copies. Growth is monotonic
and storage preserves it in the current contract; current saved progress is
sufficient for that backfill. Any externally removed legacy copies would need
verified historical evidence before additional unlocks are granted.

## 5. Read API and client state

Keep shared `GET /v1/catalog` definitions unchanged and add an authenticated,
owner-only **`GET /v1/me/catalog-discovery`**. No client unlock/write endpoint.
Proposed response:

```json
{
  "userId": "<authenticated-internal-game-user-uuid>",
  "catalogVersion": "<current-shared-catalog-version>",
  "discoveryVersion": 2,
  "entries": [
    {"speciesId": "oak", "variantId": "standard", "stages": ["seedling", "young", "adult"]},
    {"speciesId": "oak", "variantId": "blue", "stages": ["seedling"]}
  ]
}
```

Return a complete sparse snapshot with deterministic ordering and only the
authenticated account's entries. Absence means locked **only after a successful,
valid snapshot**; `entries: []` is a valid new-account result. Read version and
entries consistently under the account lock used by writers. Catalog version
identifies metadata compatibility; discovery version orders account progress.
Retired/unknown IDs may be retained in the snapshot but are not rendered as new
catalog entries. For the scoped collection size, a complete snapshot avoids
pagination ambiguity; it is not built by scanning client inventory.

Shared asset files remain bundled/public shared art. Discovery controls catalog
presentation; introducing private per-player asset delivery is outside this batch.

Add typed discovery DTOs and a dedicated account-bound discovery store/repository,
using `AccountDiskStore` under a distinct cache kind. Keep it separate from pending
pack/exchange journals. Bind requests and cached data to API environment, verified
identity and internal user; discard responses after detach/account changes.
Apply newer discovery versions only; older responses cannot overwrite later
unlocks. Equal-version inconsistent snapshots are invalid data, not a reset.

Refresh on first catalog entry, explicit catalog refresh, a new foreground catalog
session and after a confirmed activity sync that may have advanced stages. Wire
an explicit completion/invalidation path through `GardenConnection` and
`ActivitySyncCoordinator`; do not use generic `objectWillChange` or add a Health
read. If the catalog is open, coalesce one discovery fetch after the current sync;
otherwise mark it dirty for the next entry. This also covers growth on another
device when the catalog next refreshes. A failed discovery fetch must not block
activity confirmation, entry recap, reward effects or collection recovery.

| Discovery data state | Client behavior |
| --- | --- |
| Loading, no valid cache | Sprouts visible; later stages use neutral concealed placeholders and “Checking discovery…” |
| Confirmed complete snapshot | Apply exact variant-stage visibility; absent later stages say “Not discovered” |
| Cached snapshot, offline or refreshing | Keep previously confirmed art/status, label “Last confirmed”; no optimistic unlocks |
| Failed read, no cache | Sprouts visible; later artwork concealed with “Discovery unavailable” and Retry, not a false locked claim |
| Unsupported endpoint/backend | Same unavailable state; never fall back to showing every stage |
| Account switch/sign-out | Detach old state immediately; never show account A's progress for account B |

New catalog definitions/variants default to no earned later-stage rows until a
matching snapshot is available. Sprouts always remain visible. An asset/profile
update for a previously discovered logical variant/stage does not erase its unlock.

## 6. Implementation sequence and likely files

| Order | Work package | Main files / completion evidence |
| --- | --- | --- |
| 1 | Database and upgrade | `backend/src/forest_api/models.py`, new discovery service module, Alembic revision, `routes.py::SCHEMA_REVISION`; constraints and repeat-safe pinned-profile backfill verified against PostgreSQL |
| 2 | Authoritative writes and read API | `activity.py`, account provisioning in `services.py`, trusted direct-growth tools, discovery DTOs/routes; transactional growth, intermediate stages, versioning, ownership and replay tests pass |
| 3 | Native data flow | New typed discovery models/repository/store, `AccountDiskStore.swift`, `GardenConnection.swift`, `ActivitySyncCoordinator.swift`; coalesced refresh, durable scoped cache, response ordering and account isolation tests pass |
| 4 | Catalog presentation | `CollectionScreen.swift`, catalog-specific thumbnail presentation using the existing asset resolver; fixed sprout portraits, silhouettes, exact variant switching and all data states verified |
| 5 | Integration and handoff | Shared API fixtures, backend/native tests, `frontend/scripts/validate_frontend.py` expectations, acceptance guide, collection API documentation and `frontend/DESIGN.md`; record executed checks separately from planned/device checks |

Do not change `PlantThumbnail` globally: My plants, owned-copy details, Storage,
Garden, placement/adult preview, pack results and recap retain their current
owned-state behavior. This batch governs catalog artwork. Existing acceptance
guides saying all stages are visible describe the old implementation; update
them with the implementation, rather than recording planned behavior as delivered.

## 7. Acceptance checks

Backend checks on isolated PostgreSQL:

- Fresh accounts: all sprouts available through presentation rules, zero earned
  later-stage rows; read returns version 0 with a complete empty snapshot.
- Exact thresholds and just-below thresholds; one-stage and sprout → adult jumps;
  all supported activity inputs reach the same discovery writer.
- Standard adult leaves Blue/Vined locked; growing a variant never unlocks its
  siblings or the standard. Another species with the same variant ID is isolated.
- Multiple copies of one variant union unlocks without merging individual growth.
  Concurrent syncs, repeated requests and lost-response replay do not duplicate rows
  or version increments; a forced transaction failure leaves no partial unlock.
- Upgrade includes stored adults and copies beyond the first inventory page,
  honors different historical pinned profiles/overrides, and has no-op reruns.
  Changing defaults, retiring offers or storing/replanting cannot relock art.
- Migration preservation checks and readiness revision agree; API authentication,
  cross-account isolation and consistent snapshot/version reads pass. Starter,
  exchange/opening, visitor settlement and recap acknowledgement retain their
  existing economic/replay behavior.

Native automated and iPhone acceptance:

- Every unowned species/variant has a visible sprout. Catalog row and selected
  variant header remain sprouts after all later stages unlock.
- Locked artwork is a solid silhouette, without a full-color flash, for cold load,
  rapid variant switches, navigation return and cached/failed refreshes. Unlocked
  rows display the correct stage/variant image; missing images keep truthful status.
- Confirmed multi-stage growth reveals all earned stages; opening another sprout
  reveals none. Relaunch, another device and store/replant preserve server progress.
- Test delayed/out-of-order responses, empty snapshots, network failure with/without
  cache, unsupported endpoint, corruption and account/server switching. Discovery
  errors cannot prevent a pack result, pending-operation recovery or entry recap.
- VoiceOver announces stage/variant/status and the unlock instruction; Dynamic
  Type reflows, contrast remains readable and Reduce Motion needs no special effect.
  Browse catalog and return with the Garden renderer/camera and visitor lifecycle
  preserved. Owned-copy screens and adult placement previews keep current art.

During implementation run the affected PostgreSQL suite plus existing growth,
collection, migration and visitor-boundary regressions. Run portable frontend
validation, Swift syntax checks and diff whitespace checks. On Mac run
`bash frontend/scripts/test-mac.sh` for native tests and Release build, then the
device checks above. Record executed results in backend/frontend VALIDATION.md;
source parsing does not establish native build or device acceptance.

## 8. Rollout and completion boundary

Use an explicit database upgrade and existing-account backfill; never migrate,
reseed or award from application startup. For the current controlled environment,
pause growth/direct-award writers during upgrade/backfill, deploy the backend
that maintains discovery, then resume writes and verify snapshots before enabling
the native presentation. A live rolling deployment would need a reconciled
backfill after all old writers stop; do not leave a gap in recorded stages.

The additive endpoint supports the current client during rollout, but old clients
will continue their existing all-stage previews. If discovery must apply to every
device immediately, require the updated native build before declaring rollout
complete. This does not require changing old pack definitions or saved sync receipts.

Done means variant-isolated discovery survives growth, backfill, caching and
account/device transitions, with the specified catalog images and recorded server,
native and device evidence. No new milestone rewards, pack locks, economy values,
species publication, general UI redesign, asset hosting, swarm/effect expansion,
Dark Mode or landscape work is included.
