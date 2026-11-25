# Cloud Run release support

This repository supports a public FastAPI service, a separate private HTTP worker,
and explicit operator jobs against the existing Singapore Supabase database.
No database move, restore, seeding or publication happens on normal startup.
Provisioning Google resources and running a production release are separate actions.

## Important first-release change

This version adds Alembic `0023_cloud_runtime` after `0022_expedition_launch`.
It adds only a shared infrastructure-control row. Existing game data is retained.
The API readiness check requires the new revision. The old local images cannot
participate in the new transaction fence, so **stop the old API and both workers
before installing this migration**. Resolve pending iPhone operations first.

Do not restart the old API after migration: its exact-revision readiness check
will fail. A previous image is a rollback option only when its schema contract
is compatible. Prefer a corrective migration after an incompatible schema change.

## CI and source requirements

- Commit the reviewed source, including the new scripts, migration and Supabase
  permission tool. Build from a clean checkout of that commit.
- Backend deployment requires the passing `Backend gate`. Frontend acceptance may
  be performed manually on Mac, as selected for this first release; frontend CI
  is not a backend deployment prerequisite. Both validation workflows remain
  enabled and classify paths. Swift-only changes skip backend validation; shared
  contracts trigger the appropriate jobs.
- Backend CI uses disposable PostgreSQL 17, full regressions, four HTTP
  walkthroughs, image checks and a full application backup/restore rehearsal.
- Frontend CI verifies canonical working-tree/Git catalogue bytes, resources,
  the generated project, simulator tests, Release and InternalRelease builds.
- Production secrets never enter these tests. Hosted smoke checks are separate.
- Cloud publishing and GitHub Workload Identity Federation belong to the later
  production workflow; these validation workflows do not deploy automatically.

The journal catalogue JSON is pinned to LF. After intentional copy changes,
regenerate its byte count/hash in `assets/journal/v1/journal.json`, stage both,
and run `python tools/check_catalog_bytes.py`. The index check deliberately fails
if the staged bytes differ from the staged manifest.

## Service behavior

| Component | Command / settings |
| --- | --- |
| API | Existing image default; Uvicorn factory `forest_api.main:create_app` |
| Worker | Uvicorn factory `forest_api.worker_app:create_app` |
| Migration | `python scripts/cloud.py migrate --release COMMIT` |
| Control | `python scripts/cloud.py maintenance on\|off\|status --release COMMIT` |
| Configuration acceptance | `python scripts/cloud.py preflight [--allow-maintenance]` |
| Shop preparation during release | `python scripts/cloud.py prepare-shop` |

Both HTTP services listen on `0.0.0.0:8000`. Configure Cloud Run port 8000.
The worker exposes only `POST /tasks/history`, `POST /tasks/shop`, and
`GET /health/live`. Google IAM protects invocation; the application does not
treat Scheduler headers or Supabase tokens as Google authentication.

The worker performs one complete bounded pass before replying. Success and
intentional busy/maintenance skips return 200. Catch-up, reconciliation failure,
database failure and exhausted budget return 503. Responses/logs omit exception
details. Retries may repeat safely committed work; no exactly-once claim is made.

`FOREST_WORKER_BUDGET_SECONDS=40` is below the 60-second Cloud Run timeout.
The configured maximum is 45 seconds. Every database statement receives a timeout
bounded by remaining time, commits check the deadline, and history/shop loops
check it at safe boundaries. Failed transactions roll back; previous commits
remain valid. A pinned database connection holds a session advisory lock for the
whole pass, so overlapping worker revisions cannot execute passes together.

`FOREST_MAINTENANCE_GATE_ENABLED` defaults to true and cannot be disabled in
staging/production. Runtime sessions acquire a shared transaction advisory lock,
then read the control row. The privileged gate command acquires the exclusive
lock, drains those transactions, and publishes the closed state. Each subsequent
transaction checks it again. Unavailable/missing control state fails closed.
Gameplay gets the existing JSON error format, HTTP 503, `Retry-After: 30` and
`Cache-Control: no-store`. Health remains available. The iOS client displays the
message and retains its journals; it does not yet schedule retries from that header.

The operator credential alone can write `runtime_control` or Alembic state.
Backup, migration and control commands share an advisory lock to reject overlapping
operator executions. Cloud Run task parallelism alone does not serialize separate
job executions. Do not run unrelated direct SQL/publication commands during release.

## Google prerequisites

Use the attached deployment flow's project, billing controls, registry, APIs,
identities and WIF setup. Choose `asia-southeast1`. Keep separate API, worker,
migrator, Scheduler and deployer identities. Runtime identities access only the
runtime URL and CA secrets; migrator accesses only its URL and CA. Scheduler has
`roles/run.invoker` on the worker. The deployer may deploy resources, attach the
appropriate identities, and execute operator jobs with argument overrides.

Secret Manager values:

- `forest-runtime-database-url`: restricted `forest_runtime` session-pooler URL.
- `forest-migration-database-url`: privileged operator session-pooler URL.
- `forest-db-ca`: CA certificate, mounted at `/etc/forest-db/ca.crt`.

Both stored URLs use `postgresql+psycopg`, `sslmode=verify-full`, and
`sslrootcert=/etc/forest-db/ca.crt`. Use explicit numeric secret versions. Do not
copy a Windows certificate path into a container URL. Keep the Supabase Data API
off and client database grants revoked; the backend remains the gameplay boundary.

Starting resources: API 1 CPU/512 MiB, request billing, min 0, service max 1,
concurrency 4, timeout 30 seconds, pool 2/no overflow. Worker uses min 0/max 1,
concurrency 1, timeout 60 seconds, pool 1/no overflow. All three history families
are enabled with batch limit 500. Worker liveness is independent of the database;
API startup checks `/health/ready` and liveness checks `/health/live`.

Allow connection headroom for candidate/old revisions, probes and operator jobs.
Do not interpret the nominal 2+1 pools or Cloud Run maximum as an absolute
database-connection limit during rollout. Keep capacity low and measure it.

## Preparation and validation costs

The current preference is to keep backup archives on the operator computer and
build the release image locally. Preparation does not authorize an image upload,
Cloud Run deployment, cloud job execution, database migration or scheduled work.
The existing local API and workers were stopped at the preparation check.

CPU usage is billed by the provider running that CPU. Local tests, local Docker
builds and a restore into a temporary local PostgreSQL container use the computer's
CPU and disk, not Google Cloud compute. A Supabase export still reads the hosted
database and consumes Supabase resources/egress under that provider's plan.

| Activity | Where it runs | Cost implications |
| --- | --- | --- |
| Lint, unit/regression tests, disposable database tests | Operator computer, or GitHub Actions if explicitly triggered | Local execution has no Google compute charge. GitHub runner/artifact allowances and charges are separate from Google billing. |
| Build Linux amd64 release image | Local Docker | Uses local CPU/disk. Cloud Build is not needed; do not use source-based deployment or `gcloud builds submit` for this flow. |
| Google vulnerability scanning | Optional Artifact Analysis service | Separate per-image scan fee, not a local test or a Cloud Run CPU charge. The scanning APIs were not enabled during setup. Google's published standard price checked 2026-11-25 is US$0.26 per initial automatic scan of a distinct image digest; on-demand scans are also priced per scanned image. SGD billing uses Google's applicable local-currency SKU. |
| Local database backup and restore check | Supabase source, local PostgreSQL client/restore container | No GCS upload, storage or download. The archive and JSON receipt stay in ignored local storage. |
| Upload image later | Artifact Registry | Registry storage and applicable data transfer are separate from the Cloud Run cap. Keep the repository in Singapore; preserve production/rollback tags before cleanup. |
| Create operator job definitions later | Cloud Run control plane | A definition does not execute its workload. Running a job allocates billable CPU/memory, including validation jobs. |
| Migration, preflight, control and shop-preparation executions later | Cloud Run Jobs | Each uses 1 vCPU/512 MiB, one task, no automatic retries, 300-second timeout. Jobs have a one-minute billing minimum per started instance; repeated successful or failed executions consume resources. |
| API/worker startup, hosted health/auth checks and scheduled passes later | Cloud Run services | Startups, request handling and shutdowns consume billable resources under request billing. Minimum instances is zero. Scheduler's recurring worker calls are ongoing usage, not just a one-time deployment check. |

Cloud Run's free allowance can offset eligible usage, but the S$10 cap uses gross
estimated spend before credits/discounts. Local preparation does not consume this
cap. The project-wide S$15 budget is an alert, not a cap on supporting services.
Keep production acceptance bounded: configuration/permission reads, health checks,
real-token profile/catalogue/inventory reads, and one forced pass per scheduler.
Full regression tests and load tests belong on disposable local/CI databases.

Pricing references: [Artifact Analysis](https://cloud.google.com/artifact-analysis/pricing),
[Cloud Run](https://cloud.google.com/run/pricing),
[Cloud Build](https://cloud.google.com/build/pricing),
[GitHub Actions](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
[spend caps](https://docs.cloud.google.com/billing/docs/how-to/budgets-spend-caps).

## Configure and review a release

From the repository root, copy `backend/deploy/production.example.json` to
ignored `backend/.local-cloud/production.json`. Replace the example project,
account addresses and secret versions. The release helper rejects mutable image
tags, `latest` secret versions, shared identities and mixed database secrets.

Build/publish the tested commit once to Artifact Registry, using Linux amd64
and `--build-arg FOREST_RELEASE_COMMIT=<tested SHA>`. The Dockerfile records
that SHA in the OCI revision label. The release helper pulls the immutable image
and verifies its Linux amd64 architecture and revision label before executing
any cloud stage. Record the immutable registry digest. Do not deploy the local validation tag.
Then, in PowerShell:

```powershell
$taskPython = 'backend/.venv/Scripts/python.exe'
$taskCommit = '<full tested 40-character commit SHA>'
$taskImage = 'asia-southeast1-docker.pkg.dev/<project>/<repository>/<image>@sha256:<digest>'
$taskCommon = @('--config', 'backend/.local-cloud/production.json', '--image', $taskImage, '--commit', $taskCommit)
& $taskPython backend/deploy/cloud_run.py jobs @taskCommon
```

Without `--execute`, every stage prints a reviewable plan and makes no cloud
changes. Run `jobs ... --execute` to create/update four jobs with that digest:
`forest-migrate`, `forest-control`, `forest-preflight`, `forest-prepare-shop`.
They use one task, parallelism one, no automatic retry, and a 300-second timeout.
The preflight job uses the runtime identity/credential; the other jobs are explicit
privileged operations. No job runs merely because its definition is deployed.

## Backups

`backend/scripts/backup.py` uses a patched PostgreSQL 17.12 client container, not the API
image. Run it on a trusted operator machine with Docker, the backend Python
environment and gcloud. Supply the operator URL privately through
`FOREST_DATABASE_URL`; its `sslrootcert` must be an absolute path readable on
that machine. The dump client mounts the CA read-only and requires verify-full.
Use this patched client for both dump and restore verification. The previously
cached 17.11 client cannot restore the internal column-version metadata emitted
from the patched hosted database. See the [PostgreSQL 17.12 release notes](https://www.postgresql.org/docs/17/release-17-12.html).

For an optional off-site copy, provision a dedicated private bucket with public access prevention, uniform
bucket access, versioning disabled and bounded retention. An example 14-day
lifecycle is in `deploy/backup-lifecycle.json`. Grant the backup operator bucket
metadata read and object create/read access. The script checks enforced public
access prevention and an unconditional age-based delete rule within 90 days.
Google-managed encryption protects stored objects; keep the local copies private
as well. The initial release will instead use `--local-only`, with no bucket
argument or Google Storage calls. The empty existing bucket can remain unused.
Local backups protect against a failed database migration but do not protect
against loss of the computer or its disk. Application backups contain private
game data; keep the ignored backup directory private.

```powershell
& $taskPython backend/scripts/backup.py --output backend/.local-cloud/backups --release $taskCommit --local-only --bootstrap-stopped
```

Backup requires the gate closed for that release. Only the first pre-control
backup uses `--bootstrap-stopped` after stopping all old writers. It checks exact
application table coverage, takes a public-schema custom-format dump without
ownership/ACL commands, and checks source fingerprints before/after export.
Auth, Storage and other Supabase schemas are outside this backup's scope.

It restores into a newly generated local container with an empty public schema,
then compares every table's row count and deterministic SHA-256 row fingerprints.
With `--bucket`, it additionally uploads and downloads the archive to check its
SHA-256 again. Local-only mode skips those cloud operations and writes a verified
JSON receipt after the same local restore check. No retention deletion is performed by this script.
The release helper requires a matching receipt and archive less than six hours
old, for the exact release commit, with successful restore. Off-site verification
remains the default requirement; the selected local-only policy must be explicit:

```powershell
& $taskPython backend/deploy/cloud_run.py migrate @taskCommon --bootstrap-stopped --backup-receipt <local-receipt.json> --allow-local-backup
```

This prints a plan only. Adding `--execute` later would run the cloud migration
job; do not add it during preparation. The local option preserves the release,
freshness, verified-restore and on-disk checksum checks. A migration record includes
whether the accepted backup was local-only or in GCS. A preparation backup uses a
preparation identifier and does not replace the fresh exact-commit release backup.
Rehearse restores periodically; a manual backup is not an ongoing backup schedule.

## First Cloud Run cutover

Run each step only after the previous succeeds. These stages are deliberately
separate so a failure leaves a reviewable stopped/maintenance state.

1. Pass backend CI on the committed candidate. Frontend validation may be done
   manually on Mac. Provision Google prerequisites,
   publish its image, and run the `jobs` stage with `--execute`.
2. Resolve the iPhone's pending activity/purchase/edit requests through the old API.
   Stop the old API, shop and maintenance containers. Keep them stopped.
3. Take the first backup with `--bootstrap-stopped --local-only`, verify its local
   restore receipt. Keep all writers stopped through migration. No backup is uploaded.
4. Run `migrate` with `--bootstrap-stopped --backup-receipt <receipt>
   --allow-local-backup --execute`.
   It upgrades Alembic, commits maintenance ON, then applies runtime grants/RLS.
   A permissions failure leaves the new gate closed and can be retried.
5. Run `deploy --first-deploy --execute`. New services initially receive traffic,
   but gameplay is gated. Later releases use `deploy` without `--first-deploy`,
   creating tagged candidates with no production traffic.
6. Run `prepare-shop --execute`, then `verify --execute`. Verification runs
   production content/permission acceptance and checks candidate health/maintenance.
   It rejects active development fixtures; it never republishes content automatically.
7. Create both Scheduler jobs while maintenance is still closed, then pause them.
   Use POST, worker URL plus `/tasks/history` or `/tasks/shop`, UTC cron
   `* * * * *` and `*/15 * * * *`, OIDC from the Scheduler account, audience the
   worker base URL, an HTTP attempt deadline above 60 seconds, and retry count 0
   initially. Ensure unauthenticated worker invocation is rejected by Google IAM.
8. Run `promote --execute`; both tagged revisions receive 100% traffic. This stage
   runs production preflight again before changing traffic.
9. Supply a real Supabase access token in `FOREST_SMOKE_ACCESS_TOKEN` and the
   **internal game user UUID** as `--expected-user-id`. Run `open --execute`.
   It preflights, opens the gate, and checks real-token profile/catalogue/inventory
   reads through the stable API URL. Failure closes the gate and pauses schedules.
10. Run `resume --execute`. It requires a preflight with maintenance OFF, resumes
    both schedules, and force-runs them. Scheduler dispatch is asynchronous: verify
    both request outcomes and structured worker results in Cloud Logging before
    treating hosted maintenance as accepted. Failed/skipped work needs inspection.
11. Update `FOREST_GAME_API_URL` to the stable service URL, rebuild/install iOS,
    and accept login, sync, purchases, placement and lost-response recovery.

Each helper invocation uses `@taskCommon`; add `--record` with a new ignored JSON
path to retain its commit/digest/schema and observed service revisions. Do not use
a candidate tag URL as the permanent iPhone server address.

## Subsequent releases and failure handling

For initial operation, use a short maintenance window for backend releases:
`jobs → pause → gate-on → [backup → migrate for schema changes] → deploy →
prepare-shop → verify → promote → open → resume`. Use the same commit/digest
arguments throughout. A schema release requires the backup receipt; a code-only
release skips backup/migrate. The migration job rejects an open gate or a different
release identifier. Releasing without a maintenance window can be added later for
proven schema-compatible changes.

If a stage fails, inspect it before proceeding. Migration/deployment/verification
failure never automatically reopens gameplay or resumes schedules. The helper
attempts to close/preserve the gate and pause schedules on failure. If Google
control operations themselves fail, verify the actual state explicitly; no script
can guarantee a successful control-plane change during a Google outage.

Hosted smoke supports `--mode maintenance` and `--mode unauthenticated` for narrow
checks. Normal authenticated mode requires a real token and expected game user UUID;
optional `FOREST_SMOKE_SECOND_ACCESS_TOKEN` plus `--second-user-id` checks another
account's isolation. Tokens come only from environment variables, redirects are
refused, and no write route or identity injection is used. Avoid garden reads in
this smoke: some GET handlers legitimately settle game state.

After cutover, local development uses a separate disposable/development database.
Do not run CI tests, fixtures or experimental local writers against production.

Provider references: [container contract](https://docs.cloud.google.com/run/docs/container-contract),
[timeouts](https://docs.cloud.google.com/run/docs/configuring/request-timeout),
[gcloud deploy](https://docs.cloud.google.com/sdk/gcloud/reference/run/deploy),
[jobs](https://docs.cloud.google.com/sdk/gcloud/reference/run/jobs/deploy),
[Scheduler auth](https://docs.cloud.google.com/scheduler/docs/http-target-auth),
[duplicate delivery](https://docs.cloud.google.com/scheduler/docs/configuring/deduplicate-job-requests),
[required workflow filtering](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax).
