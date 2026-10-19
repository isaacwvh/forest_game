# Movement Forest backend — B1/B2

Python 3.12, FastAPI, synchronous SQLAlchemy 2, psycopg 3, PostgreSQL 17 and Alembic.
This foundation implements accounts, catalogue/profile records, owned plants and
owner-only garden/storage reads. B3 placement mutations and later game mechanics
are not implemented.

## Start locally with Docker

From `backend/` in PowerShell, with Docker Desktop's Linux engine running:

```powershell
Copy-Item .env.example .env
# Edit .env: replace FOREST_DEV_AUTH_SECRET with a random secret (at least 32 chars).
docker compose up -d db
docker compose build
docker compose run --rm migrate
docker compose run --rm api forest seed-dev
docker compose up -d --wait --wait-timeout 90 api
Invoke-RestMethod http://127.0.0.1:8000/health/ready
```

Migrations are an explicit controlled command, not an API-startup side effect.
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

Placement rows are included as a persistence/read foundation. Composite foreign
keys enforce equality of plant owner and garden owner. Bounds, overlap, canonical
precision, optimistic edit versions and transactional placement writes arrive in
B3; direct database writes are not a supported editor.

## Managed authentication

No authentication provider has been selected or provisioned by this code. For a
provider issuing compatible access JWTs, configure:

```text
FOREST_ENVIRONMENT=staging
FOREST_AUTH_MODE=jwks
FOREST_AUTH_ISSUER=https://your-provider.example/
FOREST_AUTH_AUDIENCE=your-api-audience
FOREST_AUTH_JWKS_URL=https://your-provider.example/.well-known/jwks.json
FOREST_AUTH_ALGORITHM=RS256
```

`ES256` is also supported when explicitly configured. The verifier restricts the
algorithm and verifies signature, issuer, audience, expiry, subject and any not-before
claim. A single cached JWKS client is reused. Provider outages return retryable 503;
invalid credentials return 401. Identity uses `(issuer, subject)`, preventing collisions
between providers or development identities. The managed provider handles login;
this API neither stores passwords nor implements Sign in with Apple itself.

Development authentication requires a signing secret and is rejected at startup
outside `local`/`test`. There are no unsigned tokens, owner headers or production
fallback identities. Live provider/JWKS and native login validation remain pending
provider selection. Unit tests verify real RSA/EC signatures using test keys.

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
- B3 should centralise placement mutations. B6 must settle elapsed visitor time under
  the old context before changing membership/stages/skills, then publish the future
  context in the same transaction. No visitor accounting is claimed by this foundation.
- Log configuration uses SQLAlchemy `hide_parameters`; documented Uvicorn commands
  disable access logs. Do not add tokens, raw health inputs or request bodies to logs.

See `VALIDATION.md` for checks actually performed in this implementation session.
