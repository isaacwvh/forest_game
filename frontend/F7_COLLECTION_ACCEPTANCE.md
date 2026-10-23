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

Expected schema head: `0004_collection`, readiness `ready`. Existing balances,
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

## Main flow

1. Sign in with the working email account. Check the existing garden and tokens.
2. Open the leading menu. Confirm **Exchange**, **Catalog**, **Draws**.
3. Open Catalog and inspect oak variants. Check descriptions, rarity, all four
   stages, cumulative growth, attraction, clearance radius and step multiplier.
   Search and filter by rarity; back navigation must work.
4. Earn at least **5 tokens** by welcoming visitors or collecting stored visits.
   Opening the menu or a collection screen pauses active garden visitors.
5. Open Exchange → Woodland Pack → Contents and probabilities. Fixture odds are
   standard 75%, blue 20%, vined 5%; price is 5 tokens per pack.
6. Exchange quantity 1. Exactly 5 tokens are deducted. A pack appears in Draws;
   no new plant appears until opening. Insufficient quantities are disabled.
7. Close/reopen the app before opening. The unopened pack must still be there.
8. Open Draws → Open pack. One pack disappears and one sprout appears in the
   confirmed result/history. Opening spends no additional tokens.
9. Return to Garden → Storage. Find the new zero-growth sprout, place it and
   confirm it has its own identity. Repeat with Blue Oak (8 tokens) for a
   guaranteed duplicate; existing copies retain their progress.
10. Reopen again. Balances, pack inventory, plant inventory and history persist.

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
publisher described in `backend/COLLECTION_API.md`. Acquire v1, publish v2 with a
changed plant list but the same rarity weights, then acquire v2. Both pack
versions must show/open their own contents. An empty positive-weight rarity must
fail publication without changing current offers. Do not modify live fixture
data merely to force an outcome on an existing personal account.

Record the actual Mac/iPhone results in `VALIDATION.md`; unexecuted native tests
and device checks remain pending.
