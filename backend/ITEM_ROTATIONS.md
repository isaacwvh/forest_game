# Fifteen-item release and saved weekly shop

Source implementation: 17 November 2026. Migration head: `0020_item_rotations`.
This does not establish that a personal database was migrated or content activated.
Native Xcode tests, imported animation playback and physical-device performance
must be recorded separately from portable checks.

## Content and operation

The immutable release contains six Common, five Rare and four Epic definitions,
using the selected prices, descriptions, radii and eight skills from the item
planning workbook. All fifteen model/icon packages are bundled by the generated
Xcode project. Five packages declare skeletal loops. No item has base attraction,
plant growth stages or a contribution to plant-species counts.

Each UTC day has three distinct Commons. Three distinct dates per Monday week
receive a Rare, and two independently selected dates receive an Epic. Overlap is
allowed. Every week persists seven daily intervals, twenty-six slot outcomes,
prices, source catalogue, policy version, seed and repeat-adjustment information.
The bench joins the Common pool; legacy permanent offers are excluded and rejected
for new purchases once the rotation release takes effect. Existing receipts remain
recoverable. Commons have no purchase quota; featured offers allow one copy per
account and interval. Stored-copy selling never restores that allowance.

UTC midnight is 08:00 Singapore time. Activity days and Morning Rain instead use
the account's saved game timezone. PostgreSQL supplies runtime time after locks;
container uptime and device wall time do not determine stock. The app anchors the
countdown to server time and monotonic elapsed time, refreshes at reset and on
foreground/entry, and disables expired purchase confirmations.

The default Compose stack includes the `shop` runner. It prepares the current
week at startup and the following week from Sunday 00:00 UTC, retries every minute,
and restarts automatically. Reads recover missing weeks through the same locked
service. Recovery is chronological and bounded to eight weeks per transaction;
long outages advance durable batches and return retryable unavailability until
caught up. No owner command or running phone is required for weekly operation.

## Skills and daily settlement

Placed items emit pinned skills into the existing resolver. Plants remain the
only growth recipients and species-count inputs. Duplicate groups apply strongest
once, with existing activity/water/attraction/capacity ceilings. Workout selection
expands the supported canonical workout types. Active-energy water affects only
that metric. Borrowed Wisdom counts species at any stage and caps at five percent.

Gentle Hold gives new opportunities twenty percent more welcome time, within the
version-one shared +25% duration ceiling. Both issuance protocols and the scheduled
lease horizon use the saved effective duration. Existing issued opportunities
retain their saved expiry; no animation or local timer grants authority.

Morning Rain is a separate exact +2.5-water grant per eligible planted copy per
account-local midnight. Both harp and plant must be placed at that boundary.
Every membership edit settles the previous layout before mutation, and the durable
checkpoint proves the unchanged membership interval during downtime. Garden entry,
activity sync and visitor settlement recover missed boundaries before further
growth/membership changes. Duplicates, versions, retries and swapping harps do not
create another award. Flat water is not percentage-amplified and clamps at maturity.
Once all plants mature, remaining empty boundaries are skipped without daily loops.

Daily grants record recipient/date/family identity and source/profile/growth
provenance permanently. They update actual stage, discovery and lifetime maturity
once. They create no steps, XP, gems, workout evidence or activity-day credit.
Recent daily-water totals appear in Garden information; displaying them grants
nothing. Existing Growth maturity totals can therefore include actual adulthood
reached through Morning Rain, while activity-specific evidence remains unchanged.

## Safe local activation

First build the updated app with all item resources and back up the intended
database using the existing backup procedure. From the repository root:

```powershell
docker compose -f backend/compose.yaml stop api maintenance shop
docker compose -f backend/compose.yaml build api migrate maintenance shop
docker compose -f backend/compose.yaml up -d --wait db
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-item-catalogue
docker compose -f backend/compose.yaml run --rm --no-deps api forest publish-item-catalogue --apply
docker compose -f backend/compose.yaml up -d --wait
docker compose -f backend/compose.yaml logs --tail 10 shop
```

Check each exit code. Preview is the default. Publication grants no copies and
spends nothing. Migration alone publishes nothing. Do not seed or reset accounts.
Old benches retain their identity, placement and valuation. The new client sends
`X-Forest-Item-Rotations: 1`; incompatible clients receive update-required behavior.

An optional `forest preview-shop YYYY-MM-DD` reads a persisted Monday week.
`forest prepare-shop --apply` is troubleshooting tooling, not a required weekly
operation. Future authoring changes use a new `--release-version` and an ungenerated
`--effective-week`. Existing default gift valuations remain pinned independently
of future shop prices; old purchased copies never reprice. Referenced definitions,
assets, releases, offers, purchase receipts and allowances must remain available.

## Data retention

Item skill profiles/bindings and saved releases/weeks/days/windows are immutable
shared configuration. Allowances and daily positive grant facts are durable
recovery/accounting records; the daily checkpoint is current state. They are
classified in `storage_usage.py` and excluded from temporary-response/history
deletion. Daily grants have no `ActivityCredit` foreign key and cannot disappear
through activity trace compaction. A downgrade refuses once these facts exist.

See `frontend/ROTATING_SHOP_ACCEPTANCE.md` for native acceptance. Validation results
are recorded separately after execution; a syntax parse is not an Apple SDK build.
