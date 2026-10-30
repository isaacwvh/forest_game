# B1–B6 implementation verification

## F8.7 catalog discovery — 30 October 2026

**473 backend tests passed** on the dedicated local PostgreSQL 17 validation
cluster, including 19 new catalog-discovery cases. All four real HTTP walkthroughs
also passed: activity, visitor/collection, Sleeping Dew and launch/rescale. The
launch walkthrough now verifies variant-stage discovery through a server restart
and sync replay. Tests created/dropped only random `forest_test_*` databases and
stopped the validation cluster afterward.

Coverage includes exact/just-below thresholds, multi-stage unlocks, duplicate and
variant/account isolation, storage permanence, concurrent/no-change syncs, atomic
rollback/retry, optional distance/energy/flights and typed workouts, shared native
wire fixtures, invalid stage/variant database constraints, full-schema parity,
readiness and existing-account preservation. Migration `0009_catalog_discovery`
backfills all stored/planted pinned copies beyond inventory pagination, ignores
new defaults, supports no-op reruns and refuses to downgrade away earned discovery.

Ruff lint/format, Python compilation and installed dependency checks pass. No live
game/Supabase database, account, balance, pack, asset package or `.env` was migrated,
reset or seeded. Apply the explicit upgrade in COLLECTION_API.md before deploying
the matching backend/native build. No commit/push or remote CI run was performed.
Native XCTest/Release and iPhone acceptance remain separate platform gates.

## B6/F6 implementation — 23 October 2026

**287 backend tests passed** on isolated PostgreSQL 17.11 with Python 3.12, including
all earlier 242 checks and 45 new cases. The dedicated loopback validation cluster
created/dropped only random `forest_test_*` databases and was stopped after each
run. No developer game database, existing account, `.env`, volume or live service
was migrated, reset or reseeded during this implementation.

Executed and passed:

- Complete PostgreSQL suite, including schema/model drift, upgrade/downgrade/
  re-upgrade and upgrade from a pre-B6 account with a partially grown placed plant.
  User, garden, plant, growth and transform rows match before/after the B6 upgrade.
- Exact inactive accrual, reconciliation-frequency invariance, fractional carry,
  cap overflow without hidden backlog, preservation above a lowered capacity and
  whole-visit payout lots across effective-time rule changes.
- Single-session ownership, second-device rejection, stable slots/no reconnect
  reroll, bounded lease expiry, no active/offline overlap, expiry/foreign welcome
  rejection and backwards-clock protection.
- Durable welcome/claim receipts through expiry and process recreation, distinct-
  UUID concurrent welcomes, concurrent claims, per-account request UUID scope,
  wrong-target/operation conflicts, failure rollback and ledger/lot reconciliation.
- Actual B3 storage and B5 late stage advancement settle old visitor contexts;
  growth still awards no currency. Future-rule publication, backdate rejection,
  invalid/unfair timing configuration and durable polling limits are covered.
- Real hidden Uvicorn activity walkthrough using runtime DB time, and visitor
  walkthrough using a strictly test-only injected-clock factory: activation,
  heartbeat/arrival, welcome, end, inactive claim/fraction and original receipt
  replay after stopping/restarting the API process. Temporary processes/databases
  were cleaned up. Synthetic visitor responses were explicitly exported for iOS.
- Reproducible 100,000-slot development simulation for empty/starter/adult/15-adult/
  dense stress cases: at assumed 50% capture, active successful welcomes exceed
  inactive production. Starter approximately 34.11 active versus 15 stored/hour;
  adult approximately 44.38 versus 21.82. These are fixture simulations, not measured
  human performance or approved production balance. New skills remain B8.
- Ruff lint/format, Python compilation, installed dependency consistency and diff
  whitespace checks. Backend CI includes both visitor HTTP and pacing scripts.

Docker engine queries, including an unsandboxed availability check, returned HTTP
500. A B6 container build/run could not be verified; no live Docker service was
changed. Native PostgreSQL/HTTP verification passed. Remote CI was configured but
not invoked. F6 Xcode/native tests/Release build and physical iPhone acceptance
cannot run on this Windows host and remain required. See `VISITOR_API.md` and
`frontend/F6_VISITOR_ACCEPTANCE.md` for the delivered contract and safe rollout.

Earlier milestone records below remain historical. The user accepts testing
through B5/F5/F5a except SMTP/Google/Apple setup and their dependent live checks.

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

## B4/B5 verification — 22 October 2026

Implemented and verified against an isolated, loopback-only PostgreSQL 17.11
cluster. The configured developer garden/database was not migrated or reset.
The full suite creates/drops only its randomly named disposable databases.

- **218 backend tests passed**, including all prior ownership/placement/auth tests.
- Alembic `0002_b4_b5` upgrade, schema/model drift check, downgrade to base and
  re-upgrade pass. New accounting/configuration/recap records and partial unique
  active-device index match the application models.
- Pure exact calculations cover metric normalisation, omitted coefficients,
  independent inputs, fractional carry/chunking invariance, cumulative stages,
  terminal maturity clamp and bounded neutral visitor curve/capacity fixtures.
- Steps HTTP/API tests cover enrolment without historical grants, unavailable
  observations, fresh first-available baselines, atomic device replacement and
  preservation of the original baseline/watermark across re-enrolment/retries.
- Cumulative increases, downward corrections, stale observations, late queued
  captures, seven-date reconciliation and the 30-day queue grace are exercised.
  Day intervals are verified across 23-hour/25-hour DST transitions.
- Concurrent identical and increasing syncs cannot duplicate credits. Concurrent
  same-ID/different-input requests yield one commit and one conflict. Sync/store
  races are exercised in both lock orderings with independent database sessions.
- Placed duplicates grow independently; stored copies and their fractional state
  remain unchanged. Empty gardens consume input without banking future growth.
  Profile defaults cannot reprice previously awarded copies or established days.
- Adult/maturity caps, first-maturity counts, lifetime activity independent of
  water caps, unchanged transforms/layout versions and state-only growth versions
  are verified. No wallets, token/ticket credits or visitor production are added.
- B6 callbacks see old/new growth at one server boundary and do not rerun on
  replay. Injected post-growth failures roll back growth, watermarks, counters,
  events, recaps and receipts. Completed requests replay across app recreation,
  device replacement and expired observation windows.
- Owner-only recap retrieval/pagination, acknowledgement and reconnect recovery
  pass. PostgreSQL rejects edits to configuration/credit/event history and recap
  payloads or completed acknowledgements. Activity fields are not echoed in errors.
- Ruff lint/format, Python compilation, dependency consistency and diff whitespace
  checks pass.
- `backend/scripts/smoke_activity.py` passed against a real hidden Uvicorn process:
  readiness, account, enrolment, placement, confirmed growth/attraction, replay,
  recap recovery/ack, activity status and store/replay preservation. Its process
  and disposable database were cleaned up. The walkthrough is also added to CI.

The HTTP/CI contract and exact policies are in [ACTIVITY_API.md](ACTIVITY_API.md).
Calculation values are development fixtures, not approved production balance.
New enabled growth configurations require the adult threshold to equal terminal
maturity. Wider input handlers/modifiers remain B8; visitor time accounting and
currency remain B6/B7. Managed auth, production configuration, hosting, retention,
rate limiting and device HealthKit integration retain their existing release gates.

Docker's local engine returned HTTP 500 when queried, so a B4/B5 image build/run
could not be validated here. Native PostgreSQL and actual HTTP verification passed;
remote GitHub Actions execution is configured but not claimed as executed.

## F5 presentation contract — 22 October 2026

Added owner-copy `growthProgress` presentation fields resolved from its pinned
growth profile, including versions absent from the enabled catalogue. No database
migration or accounting/economy change is introduced.

**231 tests passed** against the isolated loopback PostgreSQL 17.11 test cluster.
The 13 additional cases verify actual native wire fixtures and retired-profile
progress at sprout, seedling and terminal adult. All prior 218 cases still pass.
Ruff lint/format and diff whitespace checks pass. The real Uvicorn activity HTTP
walkthrough also passed and exported synthetic responses for native regression
tests with its explicit `--export-frontend-contract` flag. Its temporary process
and database were cleaned up. No developer game database was changed.

Native F5 XCTest, Xcode and physical iPhone/Tailscale acceptance remained pending
at that checkpoint; the subsequent F5a work below supersedes its auth deferral.

## F5a Supabase auth contract — 23 October 2026

**242 tests passed** against isolated PostgreSQL 17.11, including 11 new tests
through the actual JWT verifier, HTTP routes and database with locally generated
EC keys/Supabase-shaped claims. Verified explicit game onboarding, one account/
garden/starter across linked-provider-shaped tokens, signing-key changes, unchanged
activity replay/baselines, cross-account isolation, wrong-project/raw-provider/
expired token rejection, disabled users and development-token rejection in JWKS
mode. These are not live Supabase linking tests.

Compose forwards configured JWKS issuer/audience/algorithm while preserving its
local database URL; `.env.supabase.example` documents operator configuration.
Both Compose configurations parse; Ruff lint/format and dependency consistency
passed. No new migration/accounting change was necessary. Disposable test databases
were cleaned up and the temporary test cluster was stopped.

iOS source/native tests/provider flags are implemented; Xcode/native execution,
hosted project/SMTP and real iPhone/provider acceptance remain pending. Follow
`frontend/F5A_AUTH_ACCEPTANCE.md`. Actual `.env`, development game state and cloud
resources were not modified or provisioned.


## B7 collection exchange/draws — 23 October 2026

Executed the complete PostgreSQL regression suite: **335 passed** in 307.51s.
Final focused collection/migration run: **61 passed** in 72.67s, including the
additional unpublished-asset editing and unsafe-asset publication checks added
during final review. Migration upgrade/model parity/downgrade/reupgrade and
preservation of populated B6 account balances/counters/history pass.

The final focused run also passed both real Uvicorn HTTP walkthroughs: existing
activity/growth/storage and visitor activation/session/welcome/claims followed
by actually earned tokens → exchange → opening → owned sprout Storage. Server
restarts preserve both exchange and opening receipts. Opt-in export produced
synthetic collection/visitor fixtures for native tests; no personal data.

Verified integer rarity boundaries and unchanged tier weights under membership/
order edits, profile pinning across configuration changes, strict inputs and
reference/asset checks, no overspending or duplicate opening under concurrency,
rollback, owner isolation, durable receipts, retired offers, pagination and
mixed visitor-earning/collection-spending ledger reconciliation. No ticket,
unlock/milestone, social or wider activity implementation is included.

Ruff lint/format, dependency consistency, portable frontend resource/project/
contract checks, Swift parsing and diff whitespace checks pass. Development
pacing simulation passes and now reports first 5-token pack/open estimates:
starter ~8.8 active minutes at assumed 50% capture, or ~20 inactive minutes plus
claiming. These are provisional fixture estimates, not measured device results.

Docker Desktop's Linux engine returned HTTP 500 to `docker info`, so a new image
build/run could not be executed. Actual Python/HTTP/database checks above passed;
no remote CI run, Mac/XCTest/Release build or iPhone acceptance is claimed.

All database validation used random disposable forest_test_* databases on the
dedicated loopback test cluster, which was stopped after the runs. Existing game
DB/account state, auth configuration, .env and running game services were not
migrated, seeded or reset. Use COLLECTION_API.md and the F7 acceptance guide for
the explicit existing-server upgrade. Existing IMPLEMENTATION_PLAN edits were
retained while adding the current collection decision/implementation record.


## Species-first draws / Moonwillow — 23 October 2026

Executed full PostgreSQL regression suite: **364 passed** in 307.68s. Final
focused schema-1/schema-2 collection, Moonwillow and migration run: **89 passed**
in 71.63s, including the additional variant-profile override regression added
during final review. Fixture/runtime data uses strict schema-2 validation,
secure rarity → uniform species → weighted variant selection, and species rarity
from Alembic `0005_species_draws`. Legacy schema-1 sampling/contracts/receipts stay
unchanged. Migration parity/downgrade/reupgrade and preservation of B6/B7 accounts,
plants, unopened packs, old openings, balances and receipt JSON pass.

Verified exact three-level boundaries, invariant species odds under variant
additions/reordering, invariant rarity odds, empty/duplicate/invalid distribution
rejection, species-rarity publication validation, one sampling event under four
concurrent openings, profile override resolution/pinning, repeat-safe seeding and
retirement, and actual Moonwillow draw → Storage → placement → step growth.
Older migration tests bootstrap current-model records then downgrade to the old
schema before snapshotting/upgrading, so current ORM columns are never queried
against an older schema. A separate 0004→0005 check preserves actual pack state.

Real Uvicorn HTTP activity and visitor/collection walkthroughs passed. The latter
uses earned tokens for Woodland v2, restarts before receipt replay, acquires a
Moonwillow pack without forcing random outcomes, places its sprout and grows it
to seedling via activity sync. Exported current collection/visitor fixtures are
synthetic. The prior collection contract is retained separately for legacy native
decoding/odds tests. No personal Health data is exported.

Ruff lint/format, dependency consistency, diff whitespace and portable frontend
resource/contract/project/Swift parsing checks pass. Docker Desktop still returns
HTTP 500 from its Linux-engine info endpoint; image build/run is not verified.
No remote CI, Xcode/XCTest, Release build or new iPhone acceptance is claimed.
Only random disposable forest_test_* databases were created/dropped; the dedicated
loopback validation cluster was stopped. Existing game DB, game API services,
accounts, .env/auth/signing configuration and production balance were untouched.

## Sleeping Dew / B8 skill and cap increment — 24 October 2026

Final full PostgreSQL regression suite: **399 passed in 274.28s**. The focused
skill/placement/migration run passed **101 tests** before the final full run.
The initial full run exposed a delayed-present test double missing the new
boundary keyword; the wrapper was corrected and the final full run is green.

Verified adult/storage activation, shared Standard/Golden groups, deterministic
strongest selection, recipient filtering, capped copy counts, exact fractional
carry, +150% activity/water caps and ×6.25 composition, percentage/flat attraction
and capacity limits, maturity clamping, source activation after the entire upload,
actual bonus provenance, source-store/sync races in both orders, concurrent
repeat-safe grants and preservation of legacy pack/profile versions. Database
INSERT checks reject unsupported components; profile/policy immutability and
Alembic model parity/downgrade/reupgrade/preservation checks pass.

Real Uvicorn HTTP walkthroughs passed:

- New skills walkthrough: stored adult grant, confirmed placement/activation,
  exactly 10.4 water for neutral Oak's 1,000 eligible steps, confirmed recap,
  server restart/receipt replay, source storage and subsequent neutral growth.
- Existing activity/growth/storage walkthrough.
- Existing visitors → earned tokens → exchange → pack opening and restart replay.

Exported skills-contract.json contains only synthetic disposable-account data.
Ruff check, Ruff format check (68 Python files), pip check, diff whitespace,
portable native resources/contracts and all 50 Swift syntax parses pass.

All database tests used randomly named forest_test_* databases on a dedicated
loopback PostgreSQL validation cluster. The configured personal database on
127.0.0.1:5432 was unavailable; Docker reported an engine error. At the user's
explicit request Docker was not restarted and no personal grant, migration,
seed, account/auth/signing or environment edit was performed. The tested,
repeat-safe named-account grant/upgrade commands are in SKILLS_API.md.

Not executed on this Windows host: Docker image build/run, remote CI,
Xcode/Apple SDK compilation, XCTest/UI execution, Release simulator build or
physical-iPhone acceptance. These are pending checks, not reported passes.
Personal marginal boosts, wider metric/workout uploads and deferred mechanics
are not implemented or claimed validated by this first B8 increment.

### Existing Docker database upgrade / personal grant follow-up — 24 October 2026

With Docker available again, inspected the unhealthy API without restarting the
engine. The migration image contained head 0005 while the API contained head
0006; the database remained at 0005. Plain Compose build had excluded the
tools-profile migration service. Rebuilt migrate explicitly and corrected both
upgrade guides to build api and migrate (or run migrate with --build).

At the user's subsequent request, ran the rebuilt migration to
0006_garden_skills, published Sleeping Dew/new development offers, and waited
for Compose API/database health checks. Both are healthy and HTTP readiness
returns ready. Granted one adult Standard Moonwillow with behaviour v2 into
storage using the repeat-safe CLI; SQL confirmed the stored copy and mature
growth of 1,000,000,000 micro-units. The verified game username is isaac_auth_test
(display name Isaac Test), correcting the earlier transposed username advice.
No Docker engine restart, data reset, volume deletion or auth changes occurred.

## Wider activity and launch balance — 25 October 2026

Final complete PostgreSQL suite: **425 passed in 316.52s**. Focused launch run:
**26 passed**, followed by four passing real Uvicorn HTTP walkthroughs: existing
activity, visitors/collection, Sleeping Dew, and the new nonfixture launch.

The new coverage verifies steps plus workouts, all optional daily quantities,
independent first-readable baselines, unavailable steps with usable workouts,
manual true/false/absent metadata, replay/concurrent imports, cross-source/type
overlaps, split versus whole sessions, multisport parent suppression, paused
duration across midnight, shared two-hour cap and overflow without backlog,
exact fractions, curve continuity/bounds, actual ×4 composition and explicit
zero workout coefficients. Publication tests verify fresh production settings
without a fixture seed, repeat safety, profile/old-owned-pack preservation and
fresh local sprouts without resetting progress. Finite milestone tests verify
concurrent claims, once-only wallet ledger credits without hosted-count inflation,
earned growth → milestones → exchange → a new-profile sprout. Existing migration
model parity, downgrade/reupgrade, immutability and preservation tests pass at
`0007_activity_launch`. Legacy queued-request hashes remain compatible.

New HTTP walkthrough migrates an empty disposable database, publishes nonfixture
configuration, enrols four quantities/workouts, places a new Oak, credits exactly
100.004166 water from 10,000 steps plus one eligible workout second (with fraction
carried), earns a seedling, claims movement/seedling milestones and verifies the
same receipts/balance after an actual server restart.

Ruff lint, Ruff format (76 Python files), pip dependency check and diff whitespace
pass. Portable frontend resources/project/contracts and all **50 Swift syntax
parses** pass. Added native optional-wire/workout-boundary and milestone journal
recovery regressions; XCTest, Apple SDK typechecking, Release simulator build and
physical-device Health/background/consent acceptance are **not executed** on this
Windows host. Use `frontend/scripts/test-mac.sh` and B8_ACTIVITY_ACCEPTANCE.md.

All PostgreSQL checks used random disposable `forest_test_*` databases on the
dedicated loopback cluster; that cluster was stopped afterwards. The existing
Docker status command returned an engine HTTP 500. No engine restart, live game
migration, live publication or personal plant grant was performed. The ready-to-run
commands are in [LAUNCH_ACTIVITY.md](LAUNCH_ACTIVITY.md). Existing personal data,
auth/signing settings and unrelated uncommitted plant assets were preserved.

### Existing Docker installation upgraded — 25 October 2026

After the user started Docker, rebuilt both API and tools-profile migration
images, started PostgreSQL against the existing `movement-forest_forest-db`
volume, verified the active `isaac_auth_test` account and upgraded from
`0006_garden_skills` to `0007_activity_launch`. Published `launch-balance-v1`
(effective 2026-10-25 13:45:47 UTC), including version-10 offers and `b8-caps-v2`.
Started the rebuilt API; Compose database/API health checks and host HTTP
`/health/ready` all pass.

Before/after migration and publication checksums match for all pre-existing
owned plants, garden placements and wallets. Granted exactly one new stored
Standard Oak (`launch_oak` v1) and Standard Moonwillow (`launch_moonwillow` v1),
both sprouts at zero growth with steps/workout wildcard coefficients of 1.
The follow-up dry run finds those same copies rather than proposing duplicates.
The account retains 205 tokens, 17 active hosted visits and 231 offline hosted
visits. Its existing adult Moonwillow with behaviour v2/Sleeping Dew remains
available for bonus testing. No other personal rewards were claimed or awarded;
no data reset, auth/signing change or Docker engine restart was performed.

This supersedes the earlier Docker deployment block above. Native Mac/iPhone
checks remain pending; follow frontend/B8_ACTIVITY_ACCEPTANCE.md with the updated
app and the same account/installation.

## Scheduled visitors and tenfold economy — 25 October 2026

Final full PostgreSQL suite: **454 passed in 281.26s**, including the final lane
and rounding-boundary guards. Focused scheduler/conversion group: **29 passed in
29.52s**. All four real
Uvicorn HTTP walkthroughs pass, including a new once-only ×10 conversion,
future-arrival/early-claim guard, first actual welcome and replay after server
restart. The final microsecond wait clamp is covered by the focused group.

Coverage includes exact scaled rates/fractions/lots, wallet ledger conversion,
overflow and injected-failure rollback, concurrent publication, a milestone claim
racing cutover, immutable receipts/audits, old-offer retirement, profile/progress
preservation, explicit client capability gating, multiple scheduled identities,
lease expiry without backfill, frozen waiting progress, rate changes, repeated
replanning/lane reservations and mean-interval pacing. Existing legacy visitor,
activity, migration model parity/downgrade/reupgrade and concurrency checks pass.
Activity launch fixtures now anchor at game-local noon so duration/cap tests do
not accidentally cross midnight depending on the wall-clock test start time.

Ruff lint/format (81 Python files), pip check, diff whitespace, portable frontend
assets/contracts, generated-project consistency and all 50 Swift syntax parses
pass. The retained legacy-fixture pacing simulation passes. Native XCTest cases
were added for not-before visibility, multiple simultaneous visitors, arbitrary
visible-target welcomes, protocol negotiation and Reduce Motion lane separation.
Windows does not establish Apple SDK/XCTest/Release or iPhone acceptance.
GitHub's [iOS workflow](https://github.com/isaacwvh/forest_game/actions/runs/40204851522)
reports successful Debug tests and Release simulator build for bd18ab1.

Docker image build/status attempts again returned engine HTTP 500. No live
0008 migration, currency conversion, rule publication or account reset has been
performed. The isolated validation cluster was stopped after each run; tests
created/dropped only random forest_test_* databases. Upgrade and exact selected
values are in [VISITOR_RESCALE.md](VISITOR_RESCALE.md). GitHub workflows now run
the skills/new launch HTTP smoke and retain short failure summaries so remote
native and Linux results can be distinguished from local validation. The first
Linux run passed backend regressions and the new HTTP flow but exposed the legacy
visitor smoke's dependency on an ignored .local-tmp parent directory. It now uses
the platform temporary directory, allowing a clean checkout to run the walkthrough.

## Scaling S1-S3 - local validation, 30 October 2026

Full isolated PostgreSQL suite: **487 passed in 425.91s**. All four real Uvicorn
HTTP walkthroughs passed: activity, visitors/collection, Sleeping Dew, and typed
launch/milestone/economy conversion/scheduled arrivals with server restart replay.
Final updated scaling group: **16 passed in 25.34s**, including the additional
no-growth cleanup/retry race and database proof/size constraints added after the
full run. No failures remain in the executed checks.

Coverage includes explicit migration model parity/downgrade/reupgrade, original
account/plant/wallet/request preservation, 24-hour/seven-day/30-day exact expiry
boundaries, dry-run and legacy backfill preservation, unknown operations,
compacted account/profile/enrolment/ack/edit/sync/welcome/empty-claim recovery,
changed payload/target conflict, original exchange/opening receipts, device
replacement, latest-control completion after restart, stale starts/ends, concurrent
control starts, account-lock skips and interrupted cleanup rollback. New control
cache rows disappear while the account sequence and ordinary keys remain.

Ruff lint and formatting, pip dependency check, frontend project/assets/contracts,
all 72 Swift syntax parses and diff whitespace checks pass. Operation measurement
uses a bounded payload-free collector; the reproducible synthetic artifact is
backend/benchmarks/scaling-s1-baseline.json. Single-plant measured query counts:
heartbeat 31, welcome 31, empty claim 26 and activity sync 71. This is not a live
storage audit, p95/load result, 15-plant benchmark or a 1,000-MAU capacity claim.

All database tests used only random forest_test_* databases on the dedicated
loopback validation cluster; it was stopped after validation. No game .env,
auth/provider configuration, personal account data or live schema was changed.
Migration 0010_compact_recovery and maintenance remain explicit server commands;
maintenance defaults to a dry run and has no automatic schedule. Nothing was
committed or pushed and no CI run was requested.

Apple SDK typechecking, native XCTest/UI, Release/InternalRelease builds and
physical iPhone/multidevice acceptance are not executable on this Windows host.
See SCALING_S1_S3.md and frontend/scripts/test-mac.sh before broader cleanup.
