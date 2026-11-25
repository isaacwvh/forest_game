# Cloud Run release support

This repository supports a public FastAPI service, a separate private HTTP worker,
and explicit operator jobs against the existing Singapore Supabase database.
No database move, restore, seeding or publication happens on normal startup.
Provisioning Google resources and running a production release are separate actions.

## Current hosted release — 26 November 2026

The performance release completed at **00:05 Asia/Singapore on 26 November
2026**. The API and worker are hosted on Cloud Run; the game database remains
in Singapore Supabase. Older local-bridge and first-cutover notes below describe
earlier stages of the deployment.

**This was a code-only release. No database schema migration was needed or
executed. Alembic remained at `0023_cloud_runtime`.** No database move, restore,
reseed or new content publication was part of this release. Updating the
`forest-migrate` job definition to the new image did **not** execute that job.
Maintenance control and ordinary gameplay/worker writes are separate from a
schema migration.

| Recorded release fact | Value |
| --- | --- |
| Google project / region | `movementforest` / `asia-southeast1` |
| Backend commit, full CI passed | `9cc8a74d33d1b7b113f4663ce7712cb11fe6bab2` |
| Frontend commit / branch | `7a8d926be877ef293bb2ffd2a8333f43c13bb941` / `codex/request-latency` |
| API revision | `forest-api-00003-gix` |
| Worker revision | `forest-worker-00003-rir` |
| Image digest | `sha256:1db967125adcedd4774aa0739c26a9ab6490c966ea7284aa29ad5d1492b482f0` |
| Schema before and after | `0023_cloud_runtime` |
| Backend validation | 856 passed; three opt-in storage benchmarks skipped; HTTP walkthroughs and image/runtime checks passed |
| Hosted acceptance | Authenticated profile/catalogue/inventory and new snapshot checks passed; private worker invocation enforced; both scheduled worker families succeeded |
| Traffic / schedules | Both services at 100% new revision; `forest-history` and `forest-shop` enabled |
| Budget controls | S$10 Cloud Run spend cap and S$15 project budget alert preserved |
| Registry cleanup | Previous image and two orphaned child manifests deleted after acceptance; new image tagged `production`; old image retained locally |
| Native iOS CI | Cancelled at the user's request because of the known stall; not a backend deployment gate |

The repository is `asia-southeast1-docker.pkg.dev/movementforest/forest-backend/api`.
The stable app API URL remains
`https://forest-api-482382863751.asia-southeast1.run.app`.
Full operator receipts, configuration and private acceptance credentials stay
in ignored `backend/.local-cloud/`; they are not repository dependencies or
credentials to commit. The completion receipt is
`backend/.local-cloud/performance-release/completed.json` on the deployment
computer, with the latest summary at `backend/.local-cloud/deployment-completed.json`.

Pull the frontend branch on the Mac, rebuild in Xcode and install over the existing
iPhone app to enable the reduced request sequence. Keep the stable API URL and
Supabase settings. Login, loading/saving, activity recap and relaunch/recovery
still require device acceptance. Hosted snapshot checks from the operator computer
took approximately 1.0–1.1 seconds; this release does not establish that every user
action is below one second. See [performance contracts and measurements](PERFORMANCE.md).

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

### Code-only release: the flow used for the performance deployment

Choose the release path before touching production:

| Change | Database migration? | Release steps |
| --- | --- | --- |
| Application logic, query batching, in-process caching, additive response/route handling with unchanged database schema | No | Publish image, then `jobs → pause → gate-on → deploy → prepare-shop → verify → promote → open → resume → acceptance → registry cleanup` |
| Tables, columns, constraints, indexes or another required schema change | Yes | Add/review an Alembic revision; insert verified `backup → migrate` after `gate-on` and before `deploy` |

For a code-only release, skip the migration-specific backup and `migrate` stages.
This does not replace the independent backup policy. Do not run `alembic upgrade`
or the `forest-migrate` execution merely because an application image changed.
Check the target schema in preflight and confirm compatibility with the previous
release before relying on rollback.

1. **Prepare and check costs.** Verify the Google login, project/region, Secret
   Manager version bindings, current service/job configuration, previous digest
   and traffic. Confirm the configured spend cap, project alert, resource limits
   and recent worker activity. Obtain a fresh real Supabase user session and verify
   its internal game user UUID **before maintenance starts**. A magic link must be
   unused and valid; keep it and the resulting token private. No new database
   password or Supabase service-role key is normally needed because the runtime
   and operator jobs already use Secret Manager.
2. **Validate, build and publish.** Use an isolated clean checkout of the exact
   backend commit with passing full backend CI. Build Linux amd64 locally with
   `FOREST_RELEASE_COMMIT` set to that SHA, verify the image label/architecture,
   and push once to the existing Singapore registry. Record its immutable digest.
   Image publication does not deploy it. Keep the previous image until acceptance.
3. **Update operator definitions (`jobs`).** Point all four job definitions at
   the same new digest. Definitions alone do not execute workloads; this includes
   the migration definition, which remains unused for this release path.
4. **Pause and drain (`pause`, `gate-on`).** Pause both Scheduler jobs, close the
   global gameplay gate and allow its transaction fence to drain active writers.
   Verify the actual gate and schedule states. Health endpoints remain available.
5. **Create candidates (`deploy`).** Deploy API and worker with `--no-traffic`,
   using the existing identities, secrets, request billing and limits. Do not use
   `--first-deploy` for a subsequent release. Leave the stable app URL unchanged.
6. **Check candidates (`prepare-shop`, `verify`).** Run bounded shop preparation
   and production preflight, then check candidate health and gated responses.
   These stages do not substitute for a schema migration or seed development data.
7. **Promote and open (`promote`, `open`).** Preflight again, route both services
   to the accepted revisions, then open the gate and run real-token hosted smoke.
   `open` requires `FOREST_SMOKE_ACCESS_TOKEN` and `--expected-user-id` for the
   internal game UUID. Failed acceptance must leave/reclose maintenance and pause
   schedules; inspect the state before proceeding.
8. **Resume and accept (`resume`).** Preflight with maintenance off, resume the
   two schedules and force one attempt per family. Scheduler dispatch is
   asynchronous: confirm successful new-revision history and shop results in
   Cloud Logging, private worker IAM, enabled schedules, traffic, limits and the
   spend cap. Use only bounded production contract checks; keep load/regression
   tests on disposable databases. Snapshot reads can perform legitimate settlement.
9. **Clean the previous registry release.** Only after acceptance, confirm API,
   worker and all operator job definitions use the new digest. Move the
   `production` registry tag to it. Remove the previous release's service tag URLs,
   then delete the old image index and orphaned child manifests after verifying
   that no retained image index references them. Let Artifact Registry manage
   shared layers. Preserve the current image/provenance and the recorded/local
   rollback image. Removing one tag alone does not delete an old image, and
   deleting an index alone can leave child manifests. Report observed storage
   separately from successful artifact deletion.
10. **Record and hand off.** Save commit, digest, schema, revisions, acceptance,
    cost-control and cleanup evidence privately. Rebuild/install iOS when the
    release includes client changes; do not uninstall or reset the existing save
    as a deployment step. Do not restart native iOS CI while its known stall
    applies; use manual Mac/iPhone acceptance. The workflow files remain enabled:
    if a necessary code push starts native CI automatically, cancel that run and
    leave applicable backend CI running. Documentation-only commits can use
    `[skip ci]` to avoid unnecessary runs. No push is required merely to deploy
    an already-pushed, tested commit.

Use the common arguments from **Configure and review a release**, with a unique
`--record` path per stage. Review a stage without `--execute` first, then execute
one stage at a time. Check the native command exit status and stop on failure;
do not paste a chain that continues after a failed command. In PowerShell, a
typical individual stage is:

```powershell
& $taskPython backend/deploy/cloud_run.py jobs @taskCommon --execute --record <private-receipt-path>
if ($LASTEXITCODE -ne 0) { throw 'Release stage failed; inspect state before continuing.' }
```

Change `jobs` to the next stage only after its prerequisite succeeds. For `open`,
also supply `--expected-user-id <verified-internal-game-user-uuid>` and the private
token environment variable. Migration-only options (`--bootstrap-stopped`,
`--backup-receipt`, `--allow-local-backup`) do not belong in this code-only flow.

**If a future change needs a migration:** the migration file is packaged in the
new image, and an explicit `forest-migrate` Cloud Run Job execution applies it to
the hosted Supabase database through the privileged operator secret. The release
tool also applies the required runtime grants/RLS. Running `migrate` against a
local Docker database updates that local database only; it does not propagate
schema changes to Supabase. See **Backups** and the migration stage above.

Preserve the S$10 Cloud Run cap, S$15 project alert, minimum zero instances,
maximum one instance per service, 1 CPU/512 MiB, API/worker concurrency 4/1 and
database pools 2/1 with no overflow unless a separate capacity change is approved.
If abnormal execution growth, retries, durations or spending appear, stop
starting deployment work, pause schedules and cancel identified runaway job
executions. Inspect the cause and verify the cap; do not increase limits to get
a failing release through. The project budget alert is not a project-wide hard
cap, and the Cloud Run cap does not cover registry or other provider charges.

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
