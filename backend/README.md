# Movement Forest backend — B1–B7 collection slice

The first B8 garden-skill/cap increment is implemented; see
[SKILLS_API.md](SKILLS_API.md) for the explicit existing-server upgrade, immutable
cap policy, Sleeping Dew publication, repeat-safe adult Moonwillow storage grant
and HTTP verification. Wider activity inputs and personal boosts remain separate
increments. Native acceptance: [B8 skills](../frontend/B8_SKILLS_ACCEPTANCE.md).

Python 3.12, FastAPI, synchronous SQLAlchemy 2, psycopg 3, PostgreSQL 17 and Alembic.
This foundation implements accounts, catalogue/profile records, owned plants,
owner-only garden/storage reads, atomic B3 placement edits, exact B4 growth/attraction
calculations, B5 steps synchronisation, B6 visitors and B7 token exchange/pack draws.
Wider inputs, collection unlocks/milestones and social work remain deferred.
See [COLLECTION_API.md](COLLECTION_API.md) and [F7 acceptance](../frontend/F7_COLLECTION_ACCEPTANCE.md). See [ACTIVITY_API.md](ACTIVITY_API.md)
for the F5 contract, enrolment/device policies, examples and verification commands.
The Supabase email/password iPhone/Xcode/Tailscale flow and configuration locations
are in [frontend/F5A_AUTH_ACCEPTANCE.md](../frontend/F5A_AUTH_ACCEPTANCE.md).
The original [F5 guide](../frontend/F5_ACCEPTANCE.md) remains for local token fixtures.

## Start locally with Docker

From `backend/` in PowerShell, with Docker Desktop's Linux engine running:

```powershell
Copy-Item .env.example .env
# Edit .env: replace FOREST_DEV_AUTH_SECRET with a random secret (at least 32 chars).
docker compose up -d db
docker compose build api migrate
docker compose run --rm migrate
docker compose run --rm api forest seed-dev
docker compose up -d --wait --wait-timeout 90 api
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

Migrations are an explicit controlled command, not an API-startup side effect.
The `migrate` service is in the `tools` profile and has its own image: always
name it in the build command above. Plain `docker compose build` can leave an
older migration image in place. To rebuild and run just the migration service,
use `docker compose run --rm --build migrate`.
Do not run migrations independently from every API replica. The named database
volume persists between restarts. `docker compose down` stops the services without
deleting its volume. Development ports bind to loopback only.

The API has a readiness health check. Use `--wait` so Compose waits for both the
database and API to be healthy before issuing HTTP requests. A container reported
as `Started` may still be importing the app and opening its listening socket.
If startup fails, inspect `docker compose ps -a` and `docker compose logs --tail 100 api db`.

Open [API docs](http://127.0.0.1:8000/docs). Liveness is `/health/live`; readiness
checks PostgreSQL and the expected Alembic revision at `/health/ready`.
The API image also runs the migration and development CLI commands.

## Inspect the local database with Adminer

Adminer uses the official `adminer:6.1.2-standalone` image and is available only on
this computer. From `backend/`, start it against the existing PostgreSQL database:

```powershell
docker compose up -d adminer
```

Normal `docker compose up` also starts Adminer. Open
[Adminer](http://localhost:8080) and enter:

| Login field | Value |
| --- | --- |
| System | PostgreSQL |
| Server | `db` |
| Username | `forest` |
| Password | `forest-local-only` |
| Database | `forest` |

Use `db`, not `localhost`, because Adminer connects from inside Docker. These are
the existing local development database credentials, not an API token. This login
has write permissions; for inspection, use **Select data**, not edit/delete actions.
Starting Adminer does not seed, reset or modify game records.

Choose the `public` schema if prompted. Useful tables:

| Table | Contents |
| --- | --- |
| `users` | Accounts; match `id` to plant/garden `owner_id`. |
| `owned_plants` | Individual copies, growth and pinned profile IDs/versions. |
| `gardens`, `garden_placements` | Garden settings, placed plant IDs, coordinates and rotations. |
| `plant_species`, `plant_variants`, `plant_stages` | Shared catalogue defaults, overrides and stage assets. |
| `growth_profiles` | Stage thresholds and maturity maximum. |
| `growth_rule_profiles` | Behaviour definitions, including activity multipliers. |
| `attraction_profiles` | Base attraction by growth stage. |

Growth/attraction micro-units use 1,000,000 units per display point. Stage and final
attraction are derived values, not independently editable plant stats. Profile
versions remain immutable. B6 visitor balances and production are implemented;
see [VISITOR_API.md](VISITOR_API.md) and the frontend F6 acceptance walkthrough.

If it does not load, run `docker compose ps` and
`docker compose logs --tail 50 adminer`. Stop just this interface with
`docker compose stop adminer`.

## Run Python on the host

Keep Docker PostgreSQL running. From `backend/`:

```powershell
python -m venv .venv
.venv/Scripts/python.exe -m pip install -r requirements.lock
.venv/Scripts/python.exe -m pip install --no-deps -e .
# Copy/edit .env as above. Its DATABASE_URL uses 127.0.0.1, not Docker's db hostname.
.venv/Scripts/alembic.exe upgrade head
.venv/Scripts/forest.exe seed-dev
.venv/Scripts/uvicorn.exe forest_api.main:create_app --factory --no-access-log
```

Settings load `FOREST_*` environment variables and the current working directory's
`.env`. Start host commands from `backend/`. PostgreSQL is required; SQLite is not
a supported development or test substitute. The application never calls
`metadata.create_all`.

`requirements.lock` pins the tested runtime and test tools. Install it before the
application (`--no-deps`) for reproducible local and CI dependencies. When updating
dependencies, resolve the Python 3.12 environment and regenerate the lock, then run
the suite. Do not copy the editable application line or machine paths into the lock.

## Try the B2 flow

From `backend/`, after starting the Docker API and seeding:

```powershell
$forestToken = docker compose run --rm -T api forest dev-token alice
$forestHeaders = @{ Authorization = "Bearer $forestToken" }
$forestRequest = @{
    requestId = [guid]::NewGuid().ToString()
    username = 'alice'
    displayName = 'Alice'
    gameTimezone = 'Asia/Singapore'
} | ConvertTo-Json
Invoke-RestMethod http://127.0.0.1:8000/v1/accounts -Method Post `
    -Headers $forestHeaders -ContentType application/json -Body $forestRequest
Invoke-RestMethod http://127.0.0.1:8000/v1/me/garden -Headers $forestHeaders
Invoke-RestMethod http://127.0.0.1:8000/v1/me/inventory -Headers $forestHeaders
```

For the host Python setup, obtain the token using
`.venv/Scripts/forest.exe dev-token alice` instead. Development tokens expire after
30 minutes. They are credentials: do not commit them or log request headers.

| Route | Behaviour |
| --- | --- |
| `POST /v1/accounts` | Atomically create profile, one garden and one stored starter sprout. All ownership comes from the verified token. Retries are repeat-safe. |
| `GET /v1/me` | Own public-facing profile fields; excludes auth issuer/subject. |
| `PATCH /v1/me` | Own username/display name only; requires a request UUID. Timezone changes need the later activity-accounting policy. |
| `GET /v1/catalog` | Authenticated shared catalogue with profiles and stage assets, separate from player state. Available before onboarding. |
| `GET /v1/me/garden` | Own garden and placed plants. A new account's garden is empty until B3. |
| `GET /v1/me/inventory?limit=30&after=UUID` | Own stored plants only, UUID keyset pagination; limit 1–100. |
| `GET /v1/me/plants/{plantId}` | Own stored or placed copy; foreign/missing IDs both return 404. |
| `POST /v1/me/garden/edits` | Atomic batch plant/move/rotate/store using a request UUID, catalogue version and expected layout version. |

Each mutation accepts `requestId` in its body. Reusing it with different canonical
input or a different operation returns 409. Completed results are stored durably
with the state change; repeating a completed request returns its original result,
even after later profile edits. A new onboarding request for an existing subject
returns that account without changing profile fields or issuing another starter.
Use `PATCH /v1/me` to change supported profile fields.

Numeric geometry is returned as JSON numbers; authoritative growth/attraction
micro-unit bigint values are decimal strings. Stages are derived from individual
growth and the copy's pinned profile. Presence of a placement row determines
location; no duplicate storage flag exists. No endpoint accepts client-owned
growth, profile, radius or reward values.

## Catalogue fixtures and profiles

`forest seed-dev` is explicit and repeat-safe, and is refused outside local/test.
It references the existing oak standard/blue/vined assets and all four stages.
Radius, thresholds, attraction, rarity and board settings are **unapproved test
fixtures**. Both catalogue and species output label this. No economy configuration,
wallets, visitor opportunities or growth rewards are created.

No approved production catalogue is bundled. Fixture catalogue reads and initial
awards fail closed in staging/production. A production catalogue publishing workflow
is future work; editing the planning workbook does not publish configuration.

Growth, behaviour and attraction profile versions have composite foreign keys and
database triggers rejecting updates/deletes. Insert a new version for a new rule;
existing owned copies retain the versions resolved when awarded. Variant overrides
are resolved before pinning. Supported B2 behaviour configuration has explicit
metric multipliers and empty effects; omitted metrics mean zero. Enabling effects
requires B8 handlers, validation and a migration of the supported schema contract.

Composite foreign keys enforce equality of plant owner and garden owner. B3
validates canonical precision, full circular bounds and pairwise clearance under
garden/account locks. Direct database writes are not a supported editor.

## B3 placement and Swagger checks

Open `/docs`, authorise with a development token and create an account as above.
Read `/v1/me/garden` for `layoutVersion`/`catalogVersion`, and obtain an existing
stored plant ID from `/v1/me/inventory`. Use those real values below:

```json
{
  "requestId": "d53d5f76-0682-49cb-a4f5-3777b5bd9493",
  "expectedLayoutVersion": 0,
  "catalogVersion": "development-oak-v1",
  "actions": [
    {
      "action": "plant",
      "plantId": "REPLACE_WITH_YOUR_STORED_PLANT_UUID",
      "x": 2,
      "y": 2,
      "rotationDegrees": 0
    }
  ]
}
```

POST this body to `/v1/me/garden/edits`. It returns 200 with `requestId`, the complete
confirmed `garden`, and `updatedPlants` for the requested copies. A first placement
increments both garden versions to 1. That plant then appears in the garden and
no longer in stored inventory. Repeating the exact request returns its original
result without advancing versions again. Reusing its ID for changed input returns
409 `idempotency_conflict`, including if that ID was used by another mutation.

For each new edit, generate a fresh request UUID (PowerShell `[guid]::NewGuid()`),
use the latest layout/catalogue versions and replace the action as follows:

| Action | Fields besides `action` and `plantId` | Preconditions |
| --- | --- | --- |
| `plant` | `x`, `y`, `rotationDegrees` | Copy is stored and enabled for planting. |
| `move` | `x`, `y`; optional `rotationDegrees` | Copy is placed. Omitting rotation preserves it; explicit null is invalid. |
| `rotate` | `rotationDegrees` | Copy is placed. |
| `store` | None | Copy is placed. It returns to inventory with identity, profiles and growth preserved. |

- Every batch has 1–100 actions, with at most one per plant. The request-size bound
  is 64 KiB. These technical limits do not impose a 15-plant gameplay cap.
- X/Y use at most three significant fractional places; rotation uses two and must
  satisfy `0 <= rotationDegrees < 360`. Numeric strings, booleans, nulls, nonfinite
  values and noncanonical precision are rejected. Equivalent representations such
  as `2`/`2.000` and negative zero are canonicalised without moving the plant.
- The endpoint parses JSON numeric tokens as exact decimals before validation.
  The database must not silently round an invalid request into a valid position.
- Full circles must fit: `radius <= x <= width-radius`, similarly for Y. Tangency
  is valid; penetration is not. Sprouts/adults/variants share the species radius.
  Rotation and visible foliage overhang do not alter this rule.
- A batch validates its final layout, allowing swaps and storing one copy while
  planting another in the freed position. One invalid action rolls back everything.
- Errors are 422 `invalid_request`, `out_of_bounds` or `clearance_overlap`; 404
  `plant_not_found` for either missing or foreign IDs; and 409 for stale versions,
  request-ID conflicts, `plant_already_placed`, `plant_not_placed` or disabled planting.
  Conflict/geometry errors include owner-safe details. Refresh after a stale-version
  response and send the revised edit with a new UUID.
- A real batch increments layout/state versions once each; a valid no-op move or
  rotation records a successful receipt without incrementing either. A replay returns
  the original snapshot even if newer edits or catalogue changes have since occurred.
  GET the garden for its newest state after replaying an old operation.
- Existing placed copies can be moved/rotated/stored if their species is later
  disabled for new planting. Geometry changes still require explicit compatibility
  review, revalidation and a new catalogue version, never silent invalidation.

Shared exact examples for F4 previews are in `spec_examples/placement-cases.json`.
Automated tests create additional owned copies through internal fixtures for swaps
and overlap cases; no public plant-grant endpoint is introduced.

## Managed authentication

Supabase Auth is selected; the iOS SDK/UI integration is implemented. Creating the
hosted project and validating real credentials on iPhone remain operator/device
steps. Copy `.env.supabase.example` into the local `.env` workflow, preserving
your existing game database configuration. Docker Compose forwards these settings:

```text
FOREST_ENVIRONMENT=local
FOREST_AUTH_MODE=jwks
FOREST_AUTH_ISSUER=https://YOUR_PROJECT_REF.supabase.co/auth/v1
FOREST_AUTH_AUDIENCE=authenticated
FOREST_AUTH_JWKS_URL=https://YOUR_PROJECT_REF.supabase.co/auth/v1/.well-known/jwks.json
FOREST_AUTH_ALGORITHM=ES256
```

Match the algorithm to the project's active asymmetric key (`ES256` or `RS256`).
The verifier restricts the
algorithm and verifies signature, issuer, audience, expiry, subject and any not-before
claim. A single cached JWKS client is reused. Provider outages return retryable 503;
invalid credentials return 401. Identity uses `(issuer, subject)`, preventing collisions
between providers or development identities. The managed provider handles login;
this API neither stores passwords nor implements Sign in with Apple itself.

Development authentication requires a signing secret and is rejected at startup
outside `local`/`test`. There are no unsigned tokens, owner headers or production
fallback identities. Live project/JWKS and native login validation remain pending
configuration/device acceptance. Unit/integration tests verify actual RSA/EC
signatures using local keys, including Supabase-shaped claims, stable linked
subjects, signing-key changes, ownership and activity replay. Provider linking
itself must still be exercised against the hosted project.

## Tests and CI

Tests create and drop **randomly named `forest_test_*` databases** using an explicit
admin connection with CREATEDB privileges. They never truncate the configured admin
database or a developer garden. Isolated test databases are reset between cases.
They are created using migrations, not ORM table auto-creation.

From the repository root, with local Docker PostgreSQL running:

```powershell
$env:FOREST_TEST_DATABASE_URL = 'postgresql+psycopg://forest:forest-local-only@127.0.0.1:5432/postgres'
backend/.venv/Scripts/python.exe -m pytest backend/tests -q
backend/.venv/Scripts/ruff.exe check backend
backend/.venv/Scripts/ruff.exe format --check backend
```

Missing PostgreSQL configuration fails integration tests explicitly. Pure auth tests
can run independently with `python -m pytest backend/tests/test_auth.py`.
`.github/workflows/backend.yml` runs locked dependency installation, lint/format,
PostgreSQL tests (including migration rollback/re-upgrade and concurrent provisioning)
and an application-image build. Remote CI runs after a push or manual dispatch.

## Transactions and future integration

- Request-scoped sessions close/roll back automatically. Application use cases own
  explicit transactions and finish commits before returning successful DTOs.
- Account creation first takes an identity advisory transaction lock, then a user
  row lock if it exists. Unique identity/username/starter constraints provide durable
  protection across requests and API processes. Profile mutations lock the user row
  before reading their idempotency receipt.
- Future combined mutations must use a common order: account/user → garden accounting
  → owned plants ordered by UUID → wallets ordered by currency. Onboarding's advisory
  identity lock precedes this order. Do not acquire these locks in reverse order.
- B3 centralises writes in `placement.edit_garden`: user → garden → shared catalogue
  lock → relevant owned plants in UUID order. Garden/inventory/plant reads hold a
  shared garden lock while assembling their DTOs, preventing mixed layout/version
  snapshots. Garden responses reuse the same transaction-owned presenter.
- `PlacementAccounting.before_change`/`after_change` define a B6 integration seam
  at one server-time boundary captured after locks. They run in the edit transaction
  around actual layout changes, and do not rerun on replays/no-ops. The default is
  explicitly disabled: no visitor time, attraction or rewards are implemented here.
  B6 must replace it and prove old-context settlement before enabling visitor income.
- Log configuration uses SQLAlchemy `hide_parameters`; documented Uvicorn commands
  disable access logs. Do not add tokens, raw health inputs or request bodies to logs.

See `VALIDATION.md` for checks actually performed in this implementation session.
