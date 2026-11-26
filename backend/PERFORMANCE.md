# Hosted request performance

Implemented 25 November 2026; deployed at 00:05 Asia/Singapore on 26 November
2026. This was a **code-only deployment with no database schema migration**;
Alembic stayed at `0023_cloud_runtime`. The API and worker use backend commit
`9cc8a74`; the companion iOS changes are on `codex/request-latency` at `7a8d926`.
See the [completed release record and deployment flow](CLOUD_RUN.md).

## Request contracts

`GET /v1/me/garden/snapshot` returns the verified profile, garden, first plant
inventory page (30), first item page (100), capacities and catalogue in one
account/garden transaction. Existing content compatibility checks still apply.
Responses use `Cache-Control: no-store`. A client with a confirmed catalogue can
send `catalogVersion`; only an exact current version permits catalogue omission.
Pagination continues through the existing inventory endpoints.

The iOS client uses this response for initial account verification and garden
entry, then reuses it instead of loading again. HTTP 404 from an older backend
falls back to the existing profile/read sequence. Account/server/generation
checks and durable-operation recovery remain in place.

Clients advertising `X-Forest-Snapshot: 1` receive `inventory`, `itemInventory`
and `replayed` in edit receipts. Fresh receipts include inventory/capacity facts
from the committed layout and `replayed: false`, avoiding a post-save refresh.
Replayed receipts explicitly set `replayed: true`: they are historical and must
be followed by one current snapshot. Legacy receipts and compact-completion
recovery retain their existing behavior. A lost response reuses the same saved
UUID and exact request bytes.

Modern drafts send `expectedStrategySignature`, the existing native evaluator's
effective-result signature. The backend recomputes and compares it under the
edit's locks before applying changes. All geometry, ownership, catalogue/layout
version, accounting and idempotency checks still run. A mismatch rolls back with
`strategy_changed` and retains the draft for review. This removes the separate
preview request; legacy fingerprint validation remains supported. Oversized
signatures use the legacy preview path. Null additions do not change historical
request hashes.

Normal draft saving avoids the prior whole-inventory pre-save scan. Server-side
validation protects the commit, including changes made after the client's last
read. Membership changes still reconcile activity before editing; these can
require additional requests and HealthKit reads.

## Database round trips and caching

Catalogue assembly batches species, variants, stages and each profile family;
its SQL count does not grow with the number of variants. One process-local cache
entry retains the published catalogue for at most 60 seconds, configurable with
`FOREST_CATALOGUE_CACHE_SECONDS` (0 disables it; maximum 300). Every request still
checks the database catalogue version and fixture restrictions. Publication must
advance the catalogue version. Cache entries are isolated per Database instance,
contain no account data, and are copied defensively. A share lock prevents a
publication from mixing catalogue versions during assembly.

Garden/inventory presenters bulk-load pinned profiles and stages, sharing
immutable definitions within one transaction. These references are cleared on
commit/rollback; account state is never cached across requests. Capacity
counts share SQL statements. Daily grants avoid loading item skills when no
local midnight is due. Maintenance admission combines settings and the advisory
try-lock in one round trip, with the control-row read still after the lock. The
global early check, transaction fence, worker budgets and fail-closed behavior
remain enabled.

Collection summaries advertise `catalogVersion`; collection refresh reuses the
garden catalogue only when that version matches. Legacy servers still trigger
an explicit catalogue fetch.

## Measurements and acceptance

`test_request_performance.py` validates ownership isolation, snapshot coherence,
publication invalidation, legacy replay, fresh versus historical receipts,
signature rejection/rollback, bounded queries and concurrent edits on disposable
PostgreSQL. The existing native strategy reference fixtures validate the server
signature against the native evaluator, including input-order reversal.

A local synthetic published-item run with maintenance enabled measured:

| Operation | HTTP requests | SQL statements | Local server elapsed |
| --- | ---: | ---: | ---: |
| Separate refresh reads, after backend optimisations | 5 | 77 | 138 ms total |
| Coherent snapshot | 1 | 31 | 43 ms |
| Fresh edit with signature check and inventory | 1 | 77 | 111 ms |

These timings use a local database and are not hosted/device measurements or a
guarantee that every action finishes within one second. The target needs an
explicit device/network/percentile measurement after deployment; cold starts,
provider sign-in, offline recovery and activity reconciliation can exceed it.
The new request counts remove the main previously observed sequential overhead.

The deployed release enables existing payload-free operation metrics. iOS
diagnostics separate HTTP and
initial token-acquisition time. Compare warm p50/p95/p99 request and user-action
timings, query counts, SQL time and transaction time after release.

Hosted acceptance on the existing real garden measured snapshot round trips of
1,019.9–1,127.8 ms from the deployment computer, with server processing of
950.6–1,029.1 ms and 106–113 SQL statements. These observations supersede any
assumption that the small local synthetic timings establish production latency.
The strict sub-second target remains unproven/unmet in these checks; the larger
real garden and activity recap path need further profiling and device acceptance.
Authenticated hosted checks and scheduled worker passes succeeded. Full backend
CI passed 856 tests, with three opt-in storage benchmarks skipped; HTTP and image
checks passed. Native iOS CI was cancelled as requested because of its known stall.

## Release boundary

This change requires no database schema migration and does not raise Cloud Run
CPU, instance limits or connection pools. The code-only release procedure is in
`CLOUD_RUN.md`. The backend is deployed; rebuild/install the updated iOS app to
use the reduced client request sequence. Preserve compatible backend support for
any queued requests containing the new strategy expectation during rollback.
