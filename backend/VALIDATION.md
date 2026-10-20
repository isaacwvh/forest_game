# B1–B3 implementation verification

Verified 20 October 2026 on Windows with Python 3.12.5 and a project-local,
loopback-only PostgreSQL 17.11 runtime. Docker's engine was unavailable, so database
verification used native PostgreSQL binaries without installing a Windows service.
The portable runtime, databases, virtual environments and temporary files are ignored.

## B1/B2 baseline verification

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
- Remote GitHub Actions execution of B3: not claimed. B1/B2 was committed/pushed;
  the current B3 changes have not been committed or pushed in this session.
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

B1–B3 source implementation and local verification are complete to the extent
recorded here. Deployment/provider integration is not claimed complete. Activity
rewards, visitor accounting, wallets, draws, social features and the native editor
remain future milestones.

Setup and test commands are in [README.md](README.md). Tests create/drop their own
random `forest_test_*` databases; they do not reset the configured admin database.

## B3 verification — 20 October 2026

**132 tests passed** against PostgreSQL 17.11, including all 60 B1/B2 cases and
72 new B3 cases. Warnings are treated as errors. Ruff lint/format, Python
compilation and dependency consistency checks passed.

- Plant/move/rotate/store/replant preserve ownership, identity, pinned profiles,
  stages, growth, fractional state and maturity information.
- Exact board edges, tangent circles, just-overlapping/separated positions, unequal
  radii and diagonal examples match `spec_examples/placement-cases.json`.
- Raw JSON excess precision is rejected before float conversion or PostgreSQL
  rounding; strings/booleans/nulls, nonfinite values, huge exponents, malformed and
  duplicate JSON fields, excess precision and invalid yaw fail consistently.
- Swagger retains typed/discriminated action schemas and advertises numeric
  coordinates, allowed ranges and increments rather than accepting numeric strings.
- Batch swaps and store/replace operations validate the final layout. Duplicate
  plant actions, forged radius fields, oversized bodies and invalid batches fail
  without partial placements, version increments or successful receipts.
- Real edits advance both versions once. Valid no-ops preserve both versions.
  State-only updates do not invalidate a layout edit. Sixteen valid plants can be
  placed; no arbitrary 15-plant gameplay cap is introduced.
- Stale catalogue/layout errors are distinct and provide current-version details.
  Request receipts return the original response even after later membership,
  catalogue or application-instance changes; changed payloads/operations fail.
- Concurrent duplicate requests apply once. Competing edits and competing entries
  into the same space cannot both commit; concurrent same-ID/different-input
  requests yield one result and one conflict. Tests use independent SQLAlchemy
  sessions and real PostgreSQL locks.
- Garden reads hold a shared lock while constructing their snapshot; an edit waits
  until the reader has completed. Inventory and individual plant reads use the same
  garden lock convention. Foreign/missing plant IDs remain indistinguishable.
- Injected failures after placement writes and future accounting refresh failures
  roll back placements, versions and receipts. Before/after accounting callbacks
  see the old/new layout at one injected server-time boundary and never rerun on replay.
- Alembic upgrade/model-drift/downgrade/re-upgrade checks still pass. B3 introduces
  no database migration and does not alter approved production configuration.

A real Uvicorn server using the clean locked Python environment and a disposable
database also passed startup/readiness, Swagger schema inspection, plant/move/
rotate/store/replant, durable replay, exact precision, ownership rejection and
boundary rejection through HTTP. The temporary HTTP server/database were removed
after verification; no user garden or credentials were changed.

The Docker engine returned HTTP 500 during this B3 session. A B3 Docker image
rebuild/runtime check could not run; the prior B1/B2 Docker checks remain historical.
The full PostgreSQL suite and native HTTP check above passed independently of Docker.
CI is configured to run B3 tests and rebuild the image after a future push, including
when the shared geometry examples change. The default `PlacementAccounting`
implementation is explicitly disabled scaffolding for B6, not visitor settlement.
