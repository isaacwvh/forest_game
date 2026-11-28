# Go operations and managed-auth rehearsal

The [release playtest](RELEASE_PLAYTEST.md) uses the development token account in
the release database. The managed-auth rehearsal below uses a separate PostgreSQL
volume and HTTPS route. Use the [Cloud Run release record](../backend/CLOUD_RUN.md)
for the currently hosted FastAPI release.

## Operator commands

Run the Go binary with the local operator database connection in
`FOREST_DATABASE_URL`. `FOREST_ENVIRONMENT` must be `local` or `test`. The
release and operator CLI accepts loopback and the local Compose database host.
With the [release Compose configuration](compose.release.yaml), the
`release` service has the local database operator login. Use the restricted
runtime login for the Go API and workers.

| Command | Result |
| --- | --- |
| `publish-release` | Rehearse the current bundled Woodland, items, milestones, Observatory, and Shop publication. |
| `publish-pack --file FILE` | Validate pack odds, catalogue assets and pinned profiles, then publish a new version and offer. |
| `retire-offer --offer ID --version N` | Stop new purchases of the offer version. Existing packs retain their pinned definition. |
| `publish-visitor-rules --version ID --effective-at TIME --file FILE` | Validate an immutable visitor rule and schedule a future boundary. TIME is RFC3339 with an offset. |
| `schedule-milestone-event --file FILE` | Publish the Woodland event quests using explicit collection-time attribution. |
| `backfill-progression --limit 500` | Initialize bounded batches of uninitialized step entitlement and post earned gems using the existing ledger path. |
| `backfill-milestones --limit 500` | Create earned entitlements for unenrolled accounts. Players still claim the rewards themselves. |
| `activate-level-benefits` | Settle existing gardens at one boundary and initialize levels without issuing retrospective notices. |
| `storage-report` | Report PostgreSQL relation, index and TOAST sizes. `--exact` scans every table to count rows. |
| `history-backlog` | Report aged rows and receipt candidates. These counts precede the worker's recovery and reconciliation checks. |
| `maintain-history --responses --visitors --growth --limit 500` | Run one bounded History pass through the same worker lock and reconciliation. Select the families needed. |
| `compact-requests --limit 500` | Run the request receipt family alone. |

Write commands preview by default and roll back their transaction. Review the
preview against the same database before adding `--apply`. Repeat a bounded
backfill until `hasMore` is false. The read-only reports do not accept
`--apply`. After a committed release, preserve the original rows when retiring
an offer or publishing a successor. Rehearse restoring a backup before using a
production operator role.

Pack files use the collection manifest fields `packId`, `version`,
`isFixture`, `definition`, `offerId`, `offerVersion`, `tokenCost` and
`currency`. Visitor rules use the existing rule definition document with a
30-second grid and references to a published skill-cap policy. Milestone event
files use `event_id`, `name`, `starts_at`, `ends_at`, `claim_until` and
`attribution`. Use RFC3339 timestamps with offsets and set attribution to
`collection_time` to include previously stored visits collected during an
active event.

## Managed iPhone sign-in

After the operator approves the Auth project, configure its issuer and active
asymmetric signing algorithm on the Windows host. Ordinary game requests use
public JWKS and an app user access token. The API does not require a Supabase
service-role key to verify a token.

```powershell
$env:FOREST_STAGING_AUTH_ISSUER = 'https://<project-ref>.supabase.co/auth/v1'
$env:FOREST_STAGING_AUTH_ALGORITHM = 'ES256'
docker --context desktop-linux compose -f backend-go/compose.yaml -f backend-go/compose.release.yaml -f backend-go/compose.managed-auth.yaml up --build --wait api
Invoke-RestMethod http://127.0.0.1:18200/health/ready
```

Use a private HTTPS route to the local port. In the Mac test checkout's
`Local.xcconfig`, point `FOREST_GAME_API_URL` at that route, and remove a
`FOREST_DEBUG_MANUAL_CONNECTION = YES` override if present. Remove
`FOREST_DISABLE_AUTH` from the Xcode Run environment if present. Use a
separate test bundle identifier, automatic signing, and a team configured for
the Release app target. Check Build Settings for per-configuration overrides.
Run on the iPhone with the **Release** build configuration. A Debug build with
managed auth enabled can verify sign-in separately while signing is resolved.

Sign in on the device with the approved test account. Record whether the fresh
garden opens, whether one saved edit survives force-quit and relaunch with the
same account, and whether logout and account switching isolate the game state.
For the HealthKit check, enrol the phone, record activity, and verify a sync and
its retry apply growth once. Existing hosted progress is verified separately
against a restored game database in the next stage.

On 29 November 2026 the signed Release build opened a fresh garden with the
dedicated Singapore Auth login. The same garden reopened after a force-quit and
after signing out and back in. The isolated Go database confirmed one profile
and garden under the approved issuer, plus a HealthKit device enrolment with a
steps baseline. The on-device check for a subsequent activity upload and retry
was subsequently reported as passing. Switching to a second managed test
account remains a separate device check.

## Hosted data and rollback rehearsal

On 29 November 2026 a read-only PostgreSQL snapshot captured the hosted
application database while FastAPI served production. The archive and
source metadata were kept in an ignored local directory. Its isolated restore
matched every row fingerprint across 95 application tables, covering 27,477
rows and five gardens. Four profiles were linked to Supabase Auth. Auth
accounts and provider schemas were outside the game backup.

The restored schema matched the Go baseline after normalizing function line
endings and accounting for the hosted RLS helper. The rehearsal retained that
helper, the existing RLS policies and Alembic `0023_cloud_runtime`. After
verifying the application structure, it initialized the Go ledger at version
1 and applied the incremental request-history index to reach version 2. All
original table fingerprints still matched. The runtime role received SELECT
only on the new ledger. Both Go worker tasks ran as the restricted role.

The recorded hosted FastAPI image created a synthetic account in the restore.
Go recovered the same account-setup receipt, saved a garden placement,
awarded a milestone pack and opened it. After switching back, FastAPI read the
same garden, plant and wallet, replayed all three Go requests without
duplicating their effects, and accepted a new layout edit.

Use a fresh gated backup at production cutover. The next rehearsal runs the
API and worker on Cloud Run against isolated staging data and measures
Supabase pooler egress before a traffic decision.
