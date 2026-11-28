# Go backend retirement checklist

## Current checkpoint

- Go serves all 46 FastAPI API routes, plus the compact Home endpoint. The Shop and History workers run in Go.
- Local PostgreSQL integration, Go race and vet checks, Docker Desktop smoke, 860 Python reference tests, and three reference backup/restore benchmarks passed.
- Portable frontend checks passed, including 26 Swift tests and five compacted Go HTTP receipts decoded by the app's Swift models. Native Xcode, HealthKit and physical iPhone acceptance are open.
- Two local 30-minute player days measured 1.937–1.959 MB of PostgreSQL downstream traffic, including 0.306 MB of shared idle worker traffic. Hosted Supabase Shared Pooler measurements are open.

## First iPhone test

Use the Go Docker stack on the Windows desktop and reach the API privately over Tailscale HTTPS. This uses a development identity and a garden in the local Go database. Both the hosted game data and hosted Supabase Auth stay outside this first pass.

### Get the test branch on the Mac

From your existing checkout, create a separate worktree so your current Mac files stay available.

```bash
git fetch origin
git worktree add --track -b codex/go-iphone-test ../forest_game_go_test origin/codex/go-iphone-test
cd ../forest_game_go_test
open frontend/MovementForest.xcodeproj
```

The full checkout provides the Xcode project and its sibling assets. Use your existing signing team and a distinct test bundle identifier if you want the test build installed alongside your normal app.

### Start the private Go API

On the Windows desktop, from the repository root of this branch:

```powershell
docker compose -f backend-go/compose.yaml up --build --wait
Invoke-RestMethod http://127.0.0.1:18000/health/ready
tailscale serve status
tailscale serve --bg --https=8443 http://127.0.0.1:18000
docker compose -f backend-go/compose.yaml exec -T api /forest dev-token iphone-go-test
```

Use port 8443 if it is free in Tailscale Serve. Connect the desktop and iPhone to the same tailnet and keep the desktop awake. In iPhone Safari, open the HTTPS origin printed by Serve followed by `/health/ready` and check for `{"status":"ready"}`. Use the printed origin, including its port, in the app. The worker and database stay private to the host. [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)

### Build and connect

1. Select the **MovementForest** scheme and your physical iPhone in Xcode.
2. Choose **Product → Scheme → Edit Scheme → Run**. Set the build configuration to **Debug**. Under **Arguments → Environment Variables**, add and enable `FOREST_DISABLE_AUTH=1`. Clear any HealthKit fixture launch arguments for a real HealthKit pass.
3. In the ignored `frontend/MovementForest/Configuration/Local.xcconfig`, set `FOREST_GAME_API_URL = https:/$()/YOUR-TAILSCALE-HOST:8443`, using the actual host and port from Serve. This keeps this build's game API on Go if it launches outside Xcode.
4. Press **Cmd-R**. In the app, open **Settings → Developer tools → Garden connection** and enter the HTTPS origin and development token. Allow local-network access if prompted. Relaunch from Xcode for this pass so the app receives `FOREST_DISABLE_AUTH` again.
5. Create a local username and starter garden when the app prompts you. Reuse `iphone-go-test` as the token subject to return to that garden. The token expires after 30 minutes. The local Docker volume persists across normal stops.
6. Exercise app launch and reconnect, Home, planting/moving/storing, activity enrolment and sync, visitors and rewards, Shop, collection, and recovery after interrupting a save. Check milestones and expeditions where the test database has the relevant catalogue and active schedule. Capture client symptoms and request IDs from failures.

To stop this test session, turn off the proxy for port 8443 with `tailscale serve --https=8443 off` if you created it, then run `docker compose -f backend-go/compose.yaml stop`.

### Test real Supabase sign-in separately

The app points to the shared Supabase Auth project by default. For a managed-auth test with that project, use a dedicated test login, remove the Debug auth override, set `FOREST_GAME_API_URL` in the ignored `frontend/MovementForest/Configuration/Local.xcconfig` to the private HTTPS origin, and run Go in JWKS mode against an isolated local or staging game database. Set the issuer, JWKS URL, audience, and algorithm to match the Supabase project. A normal Supabase login can identify the same person to both backends. The profile, garden and progress come from each API's game database, so an existing login with no matching local profile will go through local game account setup. A separate Supabase project needs a corresponding client Auth configuration for its URL and publishable key. [Supabase JWT verification](https://supabase.com/docs/guides/auth/jwts)

## Remaining work before retirement

- [ ] Complete the private iPhone run above and the separate managed Supabase sign-in run. Verify HealthKit enrolment, upload and reconnect, and replay after app relaunch. Test the actual release build configuration before promotion.
- [ ] Port operator commands for catalogue and rule publication, pack and offer changes, Shop plan preview, milestone and expedition publication, feature activation, progression and milestone backfills, and storage reporting. Keep publication validation, dry runs and idempotent apply behavior.
- [ ] Finish the History operator CLI, including dry runs and backlog diagnostics. Verify per-family scheduling and worker reporting with realistic retained data.
- [ ] Rehearse schema adoption on a restored copy of the current Supabase game database. Compare its actual schema and migration history with the Go baseline before recording a migration version. Verify roles, grants, preserved account mappings, data and receipts, and a tested rollback. A destructive reset, if selected for any environment, needs a separate decision.
- [ ] Validate the Go API and private workers in staging. Check JWT verification, worker invocation and scheduling, connection settings, release startup, and observability. Measure comparable 30-minute days through the Supabase Shared Pooler, including worker traffic and retained-state load, against the 1–2 MB target.
- [ ] Rehearse traffic promotion and rollback with the maintenance gate and schedules. Retire the FastAPI services and Python operator runtime after the replacement tools and hosted acceptance are complete.
