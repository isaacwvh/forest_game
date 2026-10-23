# F7 collection acceptance

Keep the existing account, bundle ID, Health consent/baseline, API origin and
Mac `Local.xcconfig`/signing settings. No reinstall, new account or provider setup
is needed. Unlocks/milestones and social features are deferred; both test offers
are immediately available.

## Update the existing server

From `C:\Users\Isaac\forest_game\backend`, with Docker Desktop running:

```powershell
docker compose up -d db
$forestB7Backup = 'forest-before-b7-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + 'Z.dump'
New-Item -ItemType Directory -Force ..\outputs\backups | Out-Null
docker compose exec -T db pg_dump -U forest -d forest -Fc -f /tmp/forest-before-b7.dump
if ($LASTEXITCODE -ne 0) { throw 'Backup failed.' }
docker compose cp db:/tmp/forest-before-b7.dump "../outputs/backups/$forestB7Backup"
if ($LASTEXITCODE -ne 0) { throw 'Backup copy failed.' }
docker compose stop api
docker compose build api migrate
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
docker compose run --rm migrate
if ($LASTEXITCODE -ne 0) { throw 'Migration failed.' }
docker compose run --rm -T api forest seed-dev
if ($LASTEXITCODE -ne 0) { throw 'Fixture setup failed.' }
docker compose up -d --wait --wait-timeout 90 api
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

Expected schema head: `0005_species_draws`, readiness `ready`. Existing balances,
hosted counts, plants and placements are preserved. Never overwrite `.env` or
remove the database volume. For a host Uvicorn setup, stop that server, run
`alembic upgrade head` and `forest seed-dev` through the existing virtualenv from
`backend/`, then restart its existing command. Use one API process setup on port
8000. Reuse existing Tailscale HTTPS; confirm `/health/ready` from iPhone Safari.

These commands are instructions for updating your game server. Automated checks
use disposable databases and do not migrate/seed the existing game database.

## Update the Mac/iPhone app

Transfer the updated source, assets, project and Fixtures folder. Keep local
signing/configuration. Run `bash frontend/scripts/test-mac.sh` from the repository
root: Debug XCTest/UI tests and Release simulator build must pass. Then build
and run on the existing iPhone installation. Windows parsing does not substitute
for Apple SDK typechecking or these native runs.

## Main flow: species-first draws and grouped catalogue

Install the matching new iOS build before testing the new offers; the earlier
build only decodes schema-1 definitions. Existing owned schema-1 packs are still
supported by the new build. Keep the same account and installation.

1. Open Catalog. Expect exactly two species rows: Oak (three variants) and
   Moonwillow (two). Search “golden”: Moonwillow appears once. Both have Common
   fixture rarity. No stage-discovery masking is included in this update.
2. Open a species. Switch variants inside its detail, inspect all four stage
   images/stats and expand its pack-specific probabilities. There must be no
   separate top-level rows for Blue/Vined/Golden.
3. Earn at least 5 tokens. Exchange → Woodland Pack v2 → Contents: Common 100%;
   Oak 50%, Moonwillow 50%. Oak conditional variants: Standard 75%, Blue 20%,
   Vined 5%. Moonwillow: Standard 90%, Golden 10%. Overall odds are Oak Standard
   37.5%, Blue 10%, Vined 2.5%, Moonwillow Standard 45%, Golden 5%.
4. Exchange for one Woodland v2, then immediately open it in Draws. No restart
   is required. Expect one new zero-growth sprout and exactly one 5-token debit.
   Small samples need not produce an exact 50/50 split.
5. Earn 8 tokens and exchange for Moonwillow Pack. Opening must award Moonwillow
   (Standard or Golden). Return to Garden → Storage, place it away from the starter,
   sync new eligible steps and verify its independent growth/attraction updates.
   The provisional Moonwillow clearance radius is 1.100 garden units.
6. If you retained an unopened Woodland v1 or Blue Oak pack, inspect/open it.
   The legacy label and old odds remain, and prior results/plant IDs are unchanged.
7. Restart the app as an optional persistence test. Balances, packs, species
   catalogue, storage and opening history must persist; replay never rerolls.

## Recovery and regressions

- Start an exchange/opening, interrupt connectivity immediately, then reconnect
  and use **Retry saved request** or refresh. Whether the original request reached
  the server or not, there must be at most one debit/grant/opening. Do not create
  another purchase to recover an unknown outcome.
- Force-close during pending confirmation, relaunch and recover. The same result
  appears; there is no second plant for the consumed pack.
- Repeated taps during pending confirmation cannot submit extra mutations.
- Sign out/switch accounts while a request is pending. The other account must
  not show or send its packs/requests; returning to the original account recovers.
- Return from collection to Garden: correct token balance, stable camera and
  normal visitor resumption. Older reward receipts must not restore spent tokens.
- Check portrait/landscape, large Dynamic Type, Dark Mode, VoiceOver menu focus,
  button labels, scrollable stats and Reduce Motion. No reveal animation is
  required to receive a reward.

For pool updates, use a disposable test account/configuration with the trusted
publisher described in `backend/COLLECTION_API.md`. Acquire the current version, publish the next version with a
changed species/variant list but the same rarity weights, then acquire the new version. Both pack
versions must show/open their own contents. An empty positive-weight rarity must
fail publication without changing current offers. Do not modify live fixture
data merely to force an outcome on an existing personal account.

Record the actual Mac/iPhone results in `VALIDATION.md`; unexecuted native tests
and device checks remain pending.
