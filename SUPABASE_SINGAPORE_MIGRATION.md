# Singapore Supabase Auth cutover

24 November 2026, Asia/Singapore. Auth moved from Tokyo
`kagtrtnjflgkqlvgrjnk` to Singapore `wqtzzjkyepawuuvsaijk`. The hosted Auth
database import contains three users with their original UUIDs, password hashes
and provider mappings. The game PostgreSQL database remains local.

## Local cutover evidence

- Backed up the game database to the ignored
  `backend/.local-backups/forest-before-singapore-auth-20261124.dump` and saved
  private before-state/environment snapshots beside it.
- Rebound three Tokyo game users whose subjects match the imported Auth UUIDs.
  The development-issuer account was unchanged. In-transaction fingerprints of
  all 94 game tables matched after excluding only `users.auth_issuer`.
- Updated the ignored backend environment, rebuilt/restarted the Compose
  services, and verified API readiness and Singapore ES256 JWKS retrieval.
- Singapore's public settings accept the supplied publishable key and report
  Google, email and anonymous users enabled, email confirmation required and
  signups allowed. SMTP delivery and manual linking still require device tests.
- Local auth/account/bootstrap/migration regression: **63 passed**. Backend Ruff
  lint/format and portable frontend project/resource checks pass. Native Xcode
  and real-provider/email acceptance were not run on this Windows host.

## Configuration

- `frontend/MovementForest/Configuration/Auth.xcconfig` contains Singapore's public
  URL and publishable key. They are intentionally assigned **after** the optional
  `Local.xcconfig` include so a Mac's older Tokyo entries cannot override them.
- Keep the Mac's existing `FOREST_GAME_API_URL`, callback scheme, bundle identifier,
  signing team and HealthKit settings. Google and guest entry remain enabled;
  Apple remains disabled. No SMTP password or Google secret belongs in the app.
- `backend/.env.supabase.example` contains the matching Singapore issuer, JWKS URL,
  `authenticated` audience and ES256 algorithm. The running backend uses its
  ignored `backend/.env`; changing the example alone does not reconfigure it.
- Auth sessions are stored by project hostname. This release requires a fresh
  Singapore login. It does not copy Tokyo credentials to the new Keychain scope.

## Existing game-account ownership

Game users are identified by `(auth_issuer, auth_subject)`. Run
`backend/scripts/migrate_supabase_issuer.sql` against the **game database**, after
the Auth import and before allowing Singapore game requests. The script locks
the users table, aborts on a same-subject destination collision, and updates only
the Tokyo issuer. It preserves internal user IDs, Supabase subjects, gardens,
inventory, balances, activity/reporting state and request receipts. Unrelated
issuers, including development-token users, are untouched. Rerunning is safe.

For another deployment, stop API writers, back up its game database and verify
that its Tokyo subjects exist in the imported Singapore Auth users before running
this PowerShell command from `backend`:

```powershell
Get-Content -Raw scripts/migrate_supabase_issuer.sql |
    docker compose exec -T db psql -U forest -d forest --single-transaction -v ON_ERROR_STOP=1
```

Update that backend's ignored `.env` from the Singapore Auth values in the example
without replacing its database or maintenance settings. Then recreate the API:

```powershell
docker compose up -d --wait api adminer shop maintenance
```

This is an explicit deployment data migration, not a new Alembic schema revision.
Keep Tokyo and the private backups during acceptance. A rollback must coordinate
the original mapped users' issuers, backend issuer/JWKS and app project config;
do not blindly reassign new Singapore users or discard post-cutover game writes.

## Mac and iPhone test flow

1. Pull this change on Mac with `git pull --ff-only`. Open the existing Xcode
   project. Keep its ignored `Local.xcconfig` and existing installed app.
2. Confirm the game backend is reachable. Build and run on the same iPhone.
   Singapore's tracked public config supersedes old local Tokyo URL/key entries;
   the private game API URL and callback scheme continue to come from Local.
3. Expect to sign in again. Choose **I already have a garden** / the existing-garden
   sign-in option, rather than Play / Start a new garden.
4. Sign in with the original email and password, then confirm **Open this garden**
   if offered. Verify the original profile, garden layout, plants, inventory,
   gems/tokens and progression. No new username/setup or starter should appear.
5. Relaunch the app. It should restore the same Singapore session and garden.
   Leave it long enough for access-token renewal and verify subsequent requests.
6. Sign out and sign in with Google using the previously linked Google account.
   Verify that account's original garden. If both methods belong to one migrated
   user, both must open that same garden; do not link two separate game accounts.
7. On the same installation, request password recovery for the email account.
   Check the Resend message and open its link on this iPhone. Set a different
   password, then sign in again and confirm the original garden remains intact.
8. Optionally create a **disposable new guest**. Link it with an unused email,
   enter the emailed verification code and set a password. Log out/in and check
   that it retains its garden. Exercise Google linking with an unused identity
   only; an identity already attached to the other account should report conflict.
9. Check the existing reporting-phone/Health consent state before activity sync.
   Login must not reset daily baselines, replay rewards or replace the reporting
   phone merely because the Supabase project changed.

In Singapore's Authentication users/logs, successful tests should use the imported
UUIDs. Resend's email log should show delivery. If an existing account asks for
new game setup or opens an empty garden, stop and inspect the issuer mapping;
do not create a replacement account. Native Xcode, provider-browser and real email
acceptance require the Mac/iPhone; portable checks do not prove those flows.
