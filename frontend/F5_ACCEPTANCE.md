# F5: iPhone, Xcode, Tailscale and backend walkthrough

For the current Supabase email/password flow, use **[F5A_AUTH_ACCEPTANCE.md](F5A_AUTH_ACCEPTANCE.md)**.
This guide preserves the earlier **Debug development-token fixture flow**, which
requires an unconfigured Supabase app and a development-auth backend. It
tests everything through F5; visitors, tokens, tickets and draws are not enabled.
Do not reset the database or uninstall the app for retry tests.

## 1. Update the backend on Windows

Get the updated repository onto Windows and the Mac, including untracked/new
files if transferring without Git. Copy the whole repository: the Xcode project
references sibling `assets/` and `spec_examples/` directories. The supplied project
already includes the new Swift files and synthetic activity fixture.

In PowerShell on Windows:

```powershell
cd C:\Users\Isaac\forest_game\backend
# Preserve an existing .env and its signing secret.
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
# For a new installation, edit .env and set a random FOREST_DEV_AUTH_SECRET
# of at least 32 characters. Keep that secret on the backend computer.
docker compose up -d db
docker compose build api migrate
docker compose run --rm migrate
docker compose run --rm -T api forest seed-dev
docker compose up -d --wait --wait-timeout 90 api
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

Expected readiness: `status = ready`. The migration must reach `0002_b4_b5`.
`seed-dev` is repeat-safe and adds development calculation rules to an existing
catalogue. Neither operation resets accounts, placements or growth. No new F5
database migration is needed beyond B4/B5; rebuild the API for the new resolved
`growthProgress` response fields.

If Docker fails, inspect `docker compose ps -a` and
`docker compose logs --tail 100 api db`. The host-Python alternative is documented
in `backend/README.md`; run its commands from `backend/`, use the same migrated
PostgreSQL database, and keep Uvicorn bound to `127.0.0.1:8000`.

## 2. Reach the Windows API privately through Tailscale

Sign Windows and the iPhone into the same authorised tailnet and connect both.
Connect the Mac too if you want Safari or Simulator to reach this private API.
Keep Windows awake and the backend running.

In Windows PowerShell (use Tailscale's installed executable path if it is not on PATH):

```powershell
tailscale status
tailscale serve status
tailscale serve --bg http://127.0.0.1:8000
tailscale serve status
```

Use the HTTPS address printed by Serve, for example
`https://your-windows-pc.your-tailnet.ts.net`. Use your actual address. If prompted,
enable tailnet HTTPS using Tailscale's setup link. If this machine already serves
another application at `/`, inspect its configuration before replacing that route.

On the iPhone, open Safari and visit:

```text
https://YOUR-TAILSCALE-HOST/health/ready
```

Expected: `{"status":"ready"}`. This checks private network and database access,
not authentication. Use the hostname HTTPS origin in the app, without `/docs`,
`/v1`, port `8000`, query strings or credentials. Keep the database and Adminer
bound to loopback. Tailscale Serve is private to the tailnet; no Funnel or router
port-forwarding is required. See the official
[Serve command](https://tailscale.com/docs/reference/tailscale-cli/serve) and
[Serve examples](https://tailscale.com/docs/reference/examples/serve).

## 3. Generate a development login token

From `backend/` on Windows:

```powershell
$forestToken = (docker compose run --rm -T --no-deps api forest dev-token isaac_f5).Trim()
$forestHeaders = @{ Authorization = "Bearer $forestToken" }
# Display only when ready to copy it into the phone's secure token field:
$forestToken
```

Use the **same subject**, `isaac_f5`, whenever replacing this account's token.
Tokens expire after 30 minutes. Changing the subject selects a different identity
and may require a new account. The signing secret must never be pasted into the app.
For an existing account, use its original token subject instead of `isaac_f5`.

## 4. Build on the Mac

Follow `XCODE_SETUP.md` for first-time pairing and signing. With the updated full
repository on the Mac:

1. Open `frontend/MovementForest.xcodeproj`; choose **MovementForest**.
2. App target → Signing & Capabilities → your Personal Team, automatic signing,
   and your existing unique bundle ID. Preserve the same bundle ID to keep the
   installed app's cache, installation ID and pending requests.
3. Keep HealthKit enabled. Background Delivery is not required by this increment.
4. Select **Debug** in Scheme → Edit Scheme → Run. Remove `--fixture-health`,
   `--empty-health` and `--failed-health` for real iPhone testing.
5. Choose the paired iPhone as destination, unlock it, **Cmd-B**, then **Cmd-R**.

Use Xcode compatible with the phone's installed iOS. Before manual testing, run
the native suite on an installed iPhone Simulator, either **Cmd-U** or:

```bash
cd /path/to/forest_game
bash frontend/scripts/test-mac.sh
```

This runs native Debug unit/UI tests and a Release build. Release retains the
sample experience because development login is intentionally unavailable there.
Windows syntax/resource checks do not establish that this native step passed.

## 5. Connect and place the starter

1. In the phone app open **Settings → Garden connection**.
2. Enter the HTTPS Tailscale origin and development bearer token; tap
   **Connect and load garden**.
3. If this identity has no account, fill **Username** and **Display name**, then
   **Create account and starter**. A username is 3–32 ASCII letters, digits or
   underscores and must be unique. This sets the account game timezone from the
   phone and awards one stored sprout. An existing identity loads its account.
4. Dismiss Settings. Expect your connected garden, often initially empty.
5. **Edit → Storage → starter**. Use drag/tap or **Position…**. A useful fixture
   position is X `3.201`, Y `4.609`, rotation `35.12` degrees. Apply.
6. Select the plant → **Plant details**. Verify Sprout, zero total water, progress
   to the next stage and base attraction.

Normal view hides clearance guides. Moving, rotating, storing and replanting
preserve the owned plant ID. Your sample garden is separate and never grows.

## 6. Enable step sync and establish the baseline

1. Open **Activity → Sync steps with my garden**.
2. Read the upload explanation and choose **Enable step sync**.
3. If Health access has not previously been requested, choose your read access.
   Steps are the growth input; workout diagnostics are optional.
4. Inspect **Game timezone**, **Activity baseline**, **Last confirmed sync** and
   **Saved requests awaiting confirmation**.

The first readable current-day total establishes the baseline and awards **zero
historical growth**. Immediately repeated syncs should not grow the starter.
If today's steps are unavailable, the baseline remains pending, without treating
missing data as zero. Readable data appearing later establishes that day's fresh
baseline; only subsequent increases earn growth.

Health diagnostics can be opened through **Health activity on this iPhone**.
An empty query does not prove permission denial. Workouts remain local and earn
no workout growth at this stage. The existing manual-workout-entry exclusion is
preserved.

## 7. Walk, sync and verify growth

Carry the iPhone and walk enough for Health to register additional steps. Allow
Health to update, then use **Activity → Sync now** or background/foreground the app.

Expected:

- New eligible steps grow each planted copy independently.
- The garden and selected plant show server-confirmed growth and attraction.
- Reaching a stage threshold changes the matching model/thumbnail at the same
  position and rotation. Same-stage progress does not reload its model.
- **Activity → Confirmed growth** shows saved per-plant water and stage changes.
- **Done / skip recap** acknowledges presentation; growth was already committed.
- Repeating unchanged totals creates no further award or new recap.
- There are no visitor tokens, tickets or draw rewards from activity.

Development oak fixtures currently use 10 water per 1,000 eligible steps and
cumulative thresholds 100 / 400 / 1,000 water. These are unapproved test values;
read `growthProgress` for the owned copy rather than assuming production balance.
Step availability, aggregation and update delay must be checked on the real phone.

## 8. Inspect backend evidence

Use the existing `$forestHeaders` while the token is valid:

```powershell
$forestOrigin = 'http://127.0.0.1:8000'
$forestProfile = Invoke-RestMethod "$forestOrigin/v1/me" -Headers $forestHeaders
$forestActivity = Invoke-RestMethod "$forestOrigin/v1/me/activity" -Headers $forestHeaders
$forestGarden = Invoke-RestMethod "$forestOrigin/v1/me/garden" -Headers $forestHeaders
$forestInventory = Invoke-RestMethod "$forestOrigin/v1/me/inventory" -Headers $forestHeaders
$forestRecaps = Invoke-RestMethod "$forestOrigin/v1/me/reward-recaps" -Headers $forestHeaders
$forestProfile
$forestActivity
$forestGarden | ConvertTo-Json -Depth 12
```

These reads do not enrol another device or change rewards. Keep their private
activity output local. Match the app's plant UUID against `plants[].plantId`.

| Event | Expected evidence |
| --- | --- |
| First enrolment | `device.baselineSteps` records today's snapshot; growth stays unchanged |
| New steps | Increased plant `growthMicroUnits`, current `growthStage`, resolved `growthProgress` |
| Growth only | `stateVersion` advances; `layoutVersion` and X/Y/yaw stay unchanged |
| Stored plant | Appears in inventory with preserved growth; later sync does not grow it |
| Unchanged totals | No additional eligible quantity, growth credit or recap |
| Recap dismissal | Recap disappears from pending list; plant growth does not change |

For database inspection:

```powershell
docker compose up -d adminer
```

Open `http://localhost:8080` on Windows: PostgreSQL, server `db`, user `forest`,
local development password from `backend/README.md`, database `forest`.
Use **Select data**, not row editing. Relevant tables:

| Table | What to inspect |
| --- | --- |
| `activity_devices` | Installation/device epoch, baseline and revocation |
| `activity_days` | Observed totals versus nondecreasing credited steps |
| `activity_credits`, `plant_growth_credits` | Newly accepted input and per-copy growth |
| `owned_plants`, `garden_placements`, `gardens` | Growth, unchanged transforms and versions |
| `player_progress` | Eligible lifetime steps, first maturities and sync timestamp |
| `api_requests` | Stable request IDs and completed receipts |
| `reward_events`, `reward_recaps` | Saved growth summaries and acknowledgement |

Do not simulate higher step totals through the API on the phone's real test
account: that can advance its watermark beyond actual Health data. For a separate
synthetic backend check, use `backend/scripts/smoke_activity.py` with an explicitly
configured test admin URL; it creates and removes its own disposable database.

## 9. Exercise storage and recovery

| Test | Expected result |
| --- | --- |
| Store, walk, sync | Available activity is synced before storage; the stored copy then stops growing |
| Replant | Same plant ID, accumulated growth and stage; no old activity redistributed |
| Turn off Tailscale, walk, open Activity → Sync now | Offline message; an observation is saved after a ready baseline exists; no invented local growth |
| Force-close, reopen with Tailscale off | Cached confirmed forest remains viewable; pending activity remains queued; editing waits for recovery |
| Restore Tailscale → Sync now | Exact saved requests resolve, then current totals reconcile; growth is not duplicated |
| Cut connectivity during a save/sync | Unknown outcome retains request ID/body; retry confirms the original result |
| Stop/restart the API | PostgreSQL state survives; reconnect reconciles without duplicate awards |
| Let token expire | Re-enter a fresh token for the same subject and HTTPS origin; pending requests resume |
| Disable sync with queued uploads | Uploads pause and stay saved; re-enable to resolve them before editing |
| Reopen after recap dismissal | No new celebration without newly confirmed growth |
| Connect a different account | That account never receives the first account's queued requests or cached garden |

Offline captures require a previously confirmed, ready baseline and stored game
policy. Enrolment cannot be invented offline. New observations cover at most
seven game dates; unresolved captures have a server-enforced 30-day grace.
Completed requests remain replayable beyond that grace. The local queue is bounded
to 256 operations and never silently drops old unresolved requests.

For device replacement, use a second iPhone if available. The app explains that
another installation is active; enable sync and explicitly choose **Use this
iPhone for activity**. Sync the old phone first. Replacing creates a fresh baseline
and revokes its old reporting epoch; confirmed growth remains. Reinstalling also
creates a new installation, so avoid uninstalling merely to test relaunch.

## Acceptance record

Record Xcode, macOS and iOS versions, date, and pass/fail evidence here or in
`MAC_TEST_CHECKLIST.md`. Keep tokens and personal Health screenshots out of Git.

- [ ] Native Debug XCTest/UI tests and Release build.
- [ ] iPhone Safari readiness and authenticated private connection.
- [ ] Existing-account login, new account/starter, token replacement.
- [ ] Consent off means no step upload; opt-in baseline awards zero history.
- [ ] Real steps grow planted copies; repeat totals grant nothing extra.
- [ ] Fractional HealthKit daily totals upload as floored whole cumulative steps
      for both baseline and sync. Repeated reads within the same whole-step
      interval add no reward; queued request bytes survive interruption unchanged.
- [ ] Stage advance preserves transform and camera; attraction matches API.
- [ ] Store/replant preserves identity/progress and storage stops growth.
- [ ] Cached cold offline viewing, interrupted request and relaunch recovery.
- [ ] Recap recovery and dismissal do not change rewards.
- [ ] Optional second-device replacement and cross-account isolation.
- [ ] Unavailable Health, midnight/game timezone, delayed records.
- [ ] VoiceOver, Dynamic Type, portrait/landscape and Reduce Motion.

Background Health observer delivery and cosmetic watering animations remain
deferred. Launch, foreground, manual sync and membership preflights are the current
triggers. Device acceptance remains required before treating F5 as native-validated.
