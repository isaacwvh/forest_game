# F6: existing account visitor test over Tailscale

Use your existing **Isaac Test** Supabase account and the same iPhone installation,
bundle ID and API origin. Its partially grown plant and activity baseline are
preserved. No new account, starter, Health enrolment or cloud migration is needed.
SMTP and Google/Apple can remain deferred; use your working email sign-in.

## 1. Update the Windows computer server

Start Docker Desktop first. From `C:\Users\Isaac\forest_game\backend`:

```powershell
docker compose up -d db

# Binary database backup written inside the container, then copied to the host.
# Do not pipe a binary pg_dump through PowerShell text redirection.
$forestBackupName = 'forest-before-b6-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + 'Z.dump'
New-Item -ItemType Directory -Force ..\outputs\backups | Out-Null
docker compose exec -T db pg_dump -U forest -d forest -Fc -f /tmp/forest-before-b6.dump
if ($LASTEXITCODE -ne 0) { throw 'Backup failed; stop before migrating.' }
docker compose cp db:/tmp/forest-before-b6.dump "../outputs/backups/$forestBackupName"
if ($LASTEXITCODE -ne 0) { throw 'Backup copy failed; stop before migrating.' }

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

Expected: `status: ready`; Alembic head is `0003_visitors`. `seed-dev` is repeat-safe
and adds visitor rules to an already seeded catalogue. Keep `FOREST_ENVIRONMENT=local`
and your existing JWKS settings. Do not overwrite `.env`, remove the database volume,
use `docker compose down -v`, or run downgrade commands against your game database.

If running host Uvicorn instead of Docker API, stop that process; use the existing
host virtualenv to run `alembic upgrade head`, `forest seed-dev`, then restart the
same Uvicorn command from `backend/`. Do not run Docker API and host Uvicorn on
port 8000 together. The game DB URL remains the one already used by that server.

Reuse your existing private HTTPS Tailscale Serve origin. On iPhone Safari open
`https://YOUR_EXISTING_TAILSCALE_HOST/health/ready`; expect `{"status":"ready"}`.
No new public port, auth project or callback URL is required.

## 2. Update and validate the iPhone build on the Mac

1. Transfer/pull the updated repository, including root assets, new Swift sources,
   checked-in Xcode project and `visitor-contract.json` fixture.
2. Preserve the Mac's ignored `Local.xcconfig`, signing team and **existing bundle
   ID**. If Xcode reverts signing choices when loading the updated project, restore
   those same choices. Do not uninstall the app or change its bundle ID.
3. From the repo root run `bash frontend/scripts/test-mac.sh` for Debug native
   unit/UI tests and a Release simulator build. The new `VisitorTests` consume
   actual synthetic HTTP responses, not personal account data.
4. Build/run on the same physical iPhone, with real Auth enabled and without
   `--fixture-health`, `--empty-health`, `--failed-health` or `FOREST_DISABLE_AUTH`.
   Keep your working private API origin and email-only provider flags.
5. Resume/sign in to **Isaac Test**. If it unexpectedly requests game-account
   creation, check that you used the same Supabase project/account; do not create
   another account to work around it.

## 3. First connected walkthrough

| Action | Expected |
| --- | --- |
| Open your garden | Same partially grown plant, placement and progress. A visitor summary shows tokens, stored count/capacity and a provisional-rate note under “How visitors work”. |
| First activation | Zero historical visitor grant. Current placed stages begin contributing prospectively. |
| Stay in the normal owner garden | A butterfly arrives, flies/lingers and can be tapped. With continuous polling the fixture protects gaps after three eligible 30-second slots; allow around 90 seconds plus network delay. |
| Tap the butterfly or “Welcome visitor” | Pending confirmation, then +1 token and +1 active/total hosted. Repeated taps grant no extra token. |
| Ignore an arrival | It departs after its server expiry. No automatic token or stored visit is granted. |
| Open Edit, Plants, Settings, plant details, another tab, or background | Active visitors pause/end and disappear. Eligible subsequent inactive time starts stored production. |
| Stay away for five minutes, then return | A starter should have at least one whole stored visit. The fixture starter rate is one visit per four inactive minutes; a grown plant can be faster. A lost end request can leave up to 45 seconds of active lease coverage first. |
| Tap “Collect stored visits” once | All whole stored visits become tokens/hosted progress together; fractional progress remains. No per-visit tapping. |
| Force-close and reopen | Same garden, tokens and counters. No new starter or repeated reward. |

Storage capacity is 30 visits in the development configuration. At full capacity
visits remain until collected; excess production is discarded. Attraction and
stored-visit capacity are not token-wallet caps. There is no token exchange or
seed draw in this increment (B7/F7).

## 4. Recovery and lifecycle checks

- [ ] Tap welcome/claim and immediately disable the private network. Reconnect and
  use **Retry visitors**. A request with an unknown result stays saved and confirms
  once with its original UUID/body. A missed active arrival cannot be collected
  retroactively if its welcome never committed before expiry.
- [ ] Background/lock the phone while a request is in flight. Return after the
  lease expires. No active interval is also paid as stored visits, and old visitors
  do not replay in a burst.
- [ ] Switch tabs repeatedly and enter/leave Edit/Settings/details while an arrival
  is visible. No visitor remains tappable in obstructed views.
- [ ] Force-close during pending confirmation, reopen and recover. Token and hosted
  totals increment once. Repeat after restarting the computer API (keep the DB).
- [ ] If another test account is available, switch A -> B with A's request pending.
  B sees only its own visitor state. Return as A to recover A's request. Skip rather
  than create unrelated accounts if only Isaac Test is currently available.
- [ ] If another installation/device is available, start it while the first lease
  is live. It reports the session conflict and cannot reroll the current slot.
- [ ] Walk/sync your existing steps. Growth changes attraction prospectively and
  never directly changes tokens. Store/replant preserves plant identity/progress;
  an empty garden generates no new visits, while previous storage stays claimable.
- [ ] Enable Reduce Motion: the butterfly becomes stationary with no wing/flight
  animation. VoiceOver can activate **Welcome visitor** without locating the model.
- [ ] Test portrait/landscape, large Dynamic Type, foliage overlap and camera
  orbit/pan/zoom. Touch targets stay reachable. Run a 15–30 minute session and record
  frame time, memory, missed arrivals and successful taps on the device.

The visible butterfly is a shared native overlay above the scene, so plant foliage
and camera transforms cannot occlude its tap target. Its animation/countdown is
presentation; every reward is confirmed by the server. Pending receipts cannot
overwrite a newer visitor balance/version.

## 5. Optional computer verification (read-only)

Use your existing local Adminer with the configured local database credentials.
The following queries contain no raw Health observations:

```sql
SELECT u.display_name, u.id AS user_id, g.id AS garden_id,
       p.id AS plant_id, p.growth_micro_units
FROM users u JOIN gardens g ON g.owner_id = u.id
JOIN owned_plants p ON p.owner_id = u.id
WHERE u.display_name = 'Isaac Test';

SELECT u.display_name, w.tokens, w.hosted_active, w.hosted_offline,
       COALESCE(SUM(e.amount), 0) AS ledger_tokens
FROM users u JOIN visitor_wallets w ON w.owner_id = u.id
LEFT JOIN visitor_wallet_entries e ON e.owner_id = u.id
WHERE u.display_name = 'Isaac Test'
GROUP BY u.display_name, w.tokens, w.hosted_active, w.hosted_offline;
```

`tokens` must equal `ledger_tokens` in B6, where no token spending exists yet.
`hosted_active + hosted_offline` is total hosted. Merely reading storage never
changes these balances. `garden_visitor_state`, `visitor_storage_lots`,
`visitor_sessions`, `visitor_opportunities`, `visitor_settlements` and
`visitor_reward_events` explain the timeline and receipts. Do not manually edit them.

## Acceptance record

Record the commit/files tested, Mac/Xcode/iOS versions, Debug tests, Release build,
physical-device cases above and observed capture rate. Windows portable checks
and synthetic PostgreSQL/HTTP tests cannot certify Apple SDK typechecking or
physical interaction/performance. See backend/frontend `VALIDATION.md` for the
checks actually executed during implementation.
