# B1/B2 implementation verification

Verified 20 October 2026 on Windows with Python 3.12.5 and a project-local,
loopback-only PostgreSQL 17.11 runtime. Docker's engine was unavailable, so database
verification used native PostgreSQL binaries without installing a Windows service.
The portable runtime, databases, virtual environments and temporary files are ignored.

## Passed

- **60 tests passed** against real PostgreSQL, with warnings treated as errors.
- Initial Alembic upgrade, schema/model drift check, downgrade to base and re-upgrade.
- Readiness before/after migration; liveness independent of database readiness.
- Atomic user/garden/starter creation and rollback on catalogue/username failures.
- Concurrent onboarding of the same identity creates exactly one user, garden,
  starter plant and completed request receipt.
- Concurrent identities competing for a username cannot both provision accounts.
- Durable original-response replay, changed-payload rejection, profile update
  rollback and persistence across app recreation.
- Owner-only inventory/garden/plant reads, indistinguishable missing/foreign plant
  responses, and database rejection of either form of cross-owner placement.
- Independent duplicate growth, pinned profiles across default-version changes,
  variant override resolution, stored-versus-placed reads and keyset pagination.
- PostgreSQL profile immutability and invalid profile-definition rejection.
- All 12 oak stage/variant model and thumbnail references resolve to existing assets.
- Authentication requires valid signed JWTs; unsigned/malformed/wrong-key/expired,
  wrong-issuer/audience and not-yet-valid tokens are rejected.
- Managed-auth verifier checks actual RSA/EC signatures with test keys; rejects
  unexpected algorithms before JWKS lookup. Provider outage response is retryable.
- Development authentication and catalogue seeding fail closed outside local/test;
  fixture catalogue is refused in production reads.
- Ruff lint and formatting checks; Python compilation.
- Docker Compose configuration parses using `.env.example`.
- A second clean Python environment installed only `requirements.lock` and the
  application (`--no-deps`); `pip check` found no broken requirements.
- That clean installation applied migrations to a fresh disposable database,
  seeded twice safely and started a real Uvicorn HTTP server. Readiness, account
  creation/replay, catalogue, empty garden and stored starter inventory passed.
  Its HTTP server and disposable database were then removed/stopped.

## Pending external validation

- Initial verification used native PostgreSQL because Docker was unavailable at
  that time. Docker startup was subsequently verified as recorded below.
- Remote GitHub Actions execution: workflow added; no commit/push or dispatch made.
- Selected managed authentication provider, live JWKS connection and native login:
  verifier support is implemented and tested locally; no provider was provisioned.
- Approved production catalogue/balance values: the shipped oak game settings are
  labelled development fixtures and cannot be used in staging/production.

## Docker startup follow-up

The user successfully built the API/migration images and ran migrations/seeding.
Live inspection then confirmed successful Uvicorn startup and HTTP 200 responses
from both health endpoints. Immediate requests after `docker compose up -d api`
had previously failed; a startup timing race is the likely explanation, not a
confirmed application crash.

Added an API health check against `/health/ready` and changed the documented startup
command to `docker compose up -d --wait --wait-timeout 90 api`. Recreated the API
with this configuration and verified that Compose waited for it to become healthy,
then both `Invoke-RestMethod` health requests succeeded. The database volume was
preserved. The earlier 60-test result remains from native PostgreSQL verification;
the full Linux CI suite has not been claimed as executed.

## Scope boundary

B1/B2 source implementation and local verification are complete to the extent
above. Deployment/provider integration is not claimed complete. B3 edit endpoints,
geometry/concurrency validation, activity rewards, visitors, wallets, draws and
social features remain future milestones. Placement records currently support
schema ownership constraints and reads only.

Setup and test commands are in [README.md](README.md). Tests create/drop their own
random `forest_test_*` databases; they do not reset the configured admin database.
