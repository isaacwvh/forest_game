# First Woodland catalog release

Source implementation: 13 November 2026. Activation is explicit; installing the
schema does not publish packs or alter personal accounts. No push is required.

## Release contents

`woodland-v1` contains 30 species, 47 variant sets, 188 animated USDZ models and
188 transparent 384×448 thumbnails. Catalog gameplay data is compiled into
`src/forest_api/data/woodland-v1.json`; no Excel reader is needed in the server.
The source is `outputs/plant-planning/Plant_Game_Data_Balanced_2026-11-10.xlsx`.
The workbook remains unchanged. `tools/build_woodland_release.py` reproduces
the compiled release, including the explicit Sleeping Dew override to 8%.

| Pack | Price | Common | Rare | Epic | Legendary |
| --- | --- | --- | --- | --- | --- |
| Standard Woodland | 1,200 tokens | 75% | 20% | 4.5% | 0.5% |
| Enchanted Woodland | 4,800 tokens | 10% | 60% | 27% | 3% |
| Premium Woodland | 5 gems | 1% | 4% | 75% | 20% |

All three version-20 packs contain all 30 species and identical conditional
variant weights. Rarity is drawn first, species uniformly within rarity, then
its weighted variant. Opening awards one zero-growth sprout into Storage.
The middle tier keeps internal ID `select-woodland` to reuse existing artwork.
The guaranteed Moonwillow offer is retired. All acquired historical packs and
their outcomes, probabilities, profiles and receipts remain unchanged.

The existing five introductory milestones remain available with their current
rewards and claim identities. The separate long-term milestone redesign is not
activated by this release.

## Compatibility and skills

- New plants use immutable schema-3 behavior profiles with pinned activity
  conversions. Existing plants retain their former conversions. Accepted daily
  quantities and caps are still credited once; conversions do not mint XP/gems.
- New starter Oaks use 0/15/75/150 cumulative water; normal Oaks use the workbook.
  Existing starters keep their existing growth and profiles.
- Placement radius is frozen per owned copy. Migration backfills existing radii;
  new pack outcomes pin workbook radii. Historical packs use their pre-release
  species radii. Both client placement and server validation read the copy radius.
- Existing skill-bearing Moonwillows receive a new behavior profile at explicit
  activation, changing only Sleeping Dew to 8%. Their growth and other coefficients
  remain unchanged. Old unopened packs retain their original behavior. Old 4% and
  new 8% Sleeping Dew share one strongest group and never add to 12%.
- Adult planted sources emit skills. Recipients/counts use the pre-credit snapshot;
  sources maturing in an upload activate on a subsequent upload. Copies share one
  strongest emitter per group. Different skills add within a layer, then existing
  caps apply. Conditional upgrades replace the base value.
- Forest Chorus counts distinct species. Gathering Dew and Golden Swirl count
  copies once. Stable tags select herbs, trees, flowering plants and understory.
- First Drops/Sapphire Stride split accepted daily step intervals at 2,000.
  Retries, device changes and planting never restart the interval. Actual capped
  step water is used, and exact fractional growth carries across uploads.
- Sweet Ascent uses newly accepted flights on the account's game date. Visitor
  accounting settles the prior context before applying the new bonus. Contexts
  expire at local midnight, even across an absence. Daily source facts retain only
  the reconciliation window; frozen visitor contexts preserve previous accounting.
- Afterglow has separate energy/capacity components; wildcard workout effects
  expand into the supported canonical workout types. The UI combines repeated
  components into one concise skill description.
- Gem spending is recorded in the immutable collection ledger. Reconciliation is
  earned gems plus spending equals wallet; spending does not alter step entitlement.
- Newly published cosmetic variants have neutral resale multipliers. Existing
  Blue/Vined Oak and Golden Moonwillow multipliers remain. Acquisition currency
  never changes resale. Existing valuation snapshots remain frozen.

Workbook names are mapped explicitly to shipped asset identities. `regular`
maps to `standard`, Lantern Birch `lantern` to `gold-glow`, Starcap `blue` to
`blue-gold`, and Berry Shrub's second variant to shipped `red-berry` artwork.
Its display name describes the actual red artwork; no nonexistent blue variant
is advertised. Hyphenated species and variant identifiers match asset manifests.

## App resources and storage

The app bundles the catalog once, shared by all packs and owned duplicates.
Manifest paths identify exact asset versions; safe paths and model hashes are
validated. PNGs supply collection images; placed plants and active previews load
animated USDZ hierarchies asynchronously. The model loader shares in-flight loads,
limits imports to three, retains at most 20 templates, clones entity hierarchies,
and clears unused caches on memory pressure. It never loads all 188 models at launch.

Measured source resources (decimal MB): plants 249.84, including models 226.97,
thumbnails 22.65 and manifests 0.22. The selected plants, pack artwork, garden,
butterfly and shared UI resources total approximately 274.52 MB. Compiled app
code and platform packaging are additional. Planning estimate: 300–350 MB installed,
with a 400 MB allowance including bounded local data. A generic compression probe
suggested approximately 140 MB for resource download data; it is not an IPA report.
Measure actual Release download/install sizes with Xcode's App Thinning Size Report.
Native RAM, animation, startup and frame-rate acceptance require an iPhone.

Only runtime packages are referenced. Authoring scenes, production renders,
archives and source workbooks remain outside the app bundle.

Run from the repository root:

```text
python tools/validate_woodland_release.py
python frontend/scripts/validate_frontend.py
python frontend/scripts/check_swift_syntax.py
```

The release validator checks all model hashes, asset matrices, pack images and
weights, and calculates variant-weighted duplicate resale expectations. At current
rules those are 78.643/157.287 tokens for Standard, 133.880/267.759 for Enchanted,
and 188.501/377.002 for Premium (sprout/adult if every result is sold). Actual
duplicate-only sales depend on ownership. Growth, slots, storage saturation and
future milestone grants must be included when interpreting economy forecasts.

## Existing local game activation

Install/build the updated app with all 30 packages before publishing. Old clients
are blocked from new-release registration, purchases and openings with an explicit
update-required response. Existing completed requests still replay their receipts.

Back up the game database. From the repository root, use the existing Docker
configuration without resetting volumes or changing authentication:

```text
docker compose -f backend/compose.yaml stop api maintenance
docker compose -f backend/compose.yaml build api migrate maintenance
docker compose -f backend/compose.yaml up -d --wait db
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-woodland
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-woodland --apply
docker compose -f backend/compose.yaml up -d --wait
```

Check each command succeeds before continuing. Migration head must be
`0015_woodland_release`. Publication requires the existing `launch-visitors-v2`
economy. Do not run seed/reset commands. Preview makes no publication changes;
apply locks existing accounts/gardens, settles visitor time and publishes the
catalog and offers in one transaction. Repeating apply returns `alreadyPublished`
and never re-enables retired offers or upgrades copies again. Registration shares
the publication advisory lock so new accounts cannot slip through the cutover.

After publication/gem spending, schema downgrade refuses. Restore the pre-release
backup for a rollback across that boundary. No activation against the personal
game database is implied by automated tests.

## Device test flow

1. Sign in to an existing account. Verify plants, positions, growth, tokens, gems,
   stored visitors and old unopened packs survived. Existing layouts still edit.
2. Open Catalog: 30 species, correct rarities, variants, four stages and concise
   skill descriptions. Locked discovery art stays masked; sprouts remain visible.
3. Open Exchange: all three pack designs, correct currency icons/prices and odds.
   Check insufficient currency, quantity totals and pack-capacity behavior.
4. Buy/open Standard, Enchanted and Premium when funded. Each gives one stored
   sprout. Premium spends gems once and updates Home/Profile/Exchange balances.
5. Interrupt a purchase/opening, relaunch and retry. Confirm one spend, one pack
   or plant, and the same confirmed result. Open an old pack and verify old contents.
6. Plant new species, rotate/store/replant, grow through stages and verify each
   model/thumbnail, wind, anchor, clearance and discovery. Test a 20-plant garden
   where geometry permits, including duplicate and tree-heavy arrangements.
7. Place an adult Moonwillow: 8% water, no duplicate stacking. Store it and verify
   the bonus stops. Check companion skills and both Afterglow components.
8. Cross 2,000 accepted daily steps with First Drops/Mirror Leaf. Sync several
   times and retry uploads. Confirm exact bonuses and no repeated credit.
9. With adult Boughrunner, sync flights, verify attraction, then cross local
   midnight and verify the bonus resets. Capacity skills change storage, not rate.
10. Sell stored new variants; check payout, capacity, permanent discovery and
    unchanged visitor/maturity counts. Confirm original starter sale protection.
11. Test offline/cached browsing, account switching, large text, VoiceOver,
    Reduce Motion and memory pressure. Archive Release and record app sizes.

Mac validation: `bash frontend/scripts/test-mac.sh` executes XCTest and the
Release/InternalRelease simulator builds. Portable Windows syntax parsing and
resource checks do not establish Apple SDK typechecking or native test results.
