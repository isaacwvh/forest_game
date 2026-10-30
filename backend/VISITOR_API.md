# B6 visitor contract

**Scaling update, 30 October 2026:** S1–S3 are user accepted. S4–S6 add optional
seven-day visitor-detail rollups, protected cursor/tutorial history and compact
paid-welcome outcomes. For recovery-v1 requests, a new UUID targeting an already
welcomed visitor can return typed completion even inside the response-cache
window; it never pays again. Legacy exact-response recovery stays protected.
See [SCALING_S4_S6.md](SCALING_S4_S6.md) for retention, explicit migration and
maintenance. Current arrival protocol 2/timing is defined in VISITOR_RESCALE.md;
the original slot-based description below is historical.

Implemented for the existing FastAPI/PostgreSQL application. Game data remains
local; hosted Supabase Auth and the existing Tailscale HTTPS origin are reused.
No Health-device replacement, account recreation or growth reset is required.

## Accounting and activation

- Each garden activates on its **first B6 interaction** (visitor read/session or
  placement/growth accounting hook). Its current placed stages form the initial
  context. Pre-activation time earns nothing. Existing accounts/plants are unchanged.
- Runtime operations acquire user -> garden -> shared catalogue/configuration lock,
  then read PostgreSQL `clock_timestamp()` once. Visitor state/wallet writes stay
  inside that transaction. Tests inject an exact clock instead. Timestamps are UTC;
  a backwards clock never moves `settled_at` backwards.
- Lazy settlement splits intervals at lease expiry and immutable rule effective
  times. Membership/stage mutations settle the old context before publishing the
  new one at the same boundary. Configuration publication takes the catalogue
  write lock and must be strictly future-effective. No background timer is needed.
- Inactive production carries an exact rational fraction; the wire micro-unit
  amount is rounded down for display only. Whole visits aggregate into reward lots
  by earned rule version. A newly completed whole visit uses its completion rule.
- At capacity, generated overflow (including fractions) is discarded. Earned
  storage above a newly reduced cap survives and pauses production. Claims collect
  every whole visit in one transaction and preserve the valid sub-visit remainder.
- Active intervals never accrue stored visits. Empty gardens produce nothing new;
  adults/duplicates contribute their own pinned attraction while placed. B8 skills
  remain disabled. Capacity-change tests use controlled configuration contexts.

## Active sessions and slots

The stable grid is UTC Unix epoch / 30 seconds and cannot change across rule
versions. Starting mid-slot waits for the next slot. There is one active session
per account/garden, tied to an installation distinct from Health enrolment. Another
installation receives `visitor_session_conflict`; it cannot take over a live lease.

Start/read do not issue an immediate free opportunity. An eligible heartbeat can
decide a current, previously undecided slot once. Durable cursors cover historical
missed/empty ranges without per-slot replay. Only the current slot is eligible for
presentation; late polls without a fair remaining window miss it. There is at most
one outstanding/visible opportunity. Gap protection counts eligible live decisions,
survives reconnects and never bypasses the one-opportunity-per-slot cap. Fresh
heartbeats use new request IDs; retries of one heartbeat replay its original result
and do not renew the lease again.

Explicit end expires unconsumed opportunities. Connection loss leaves active
coverage until the durable lease expiry; subsequent time is inactive. No request
backdates a pause or converts missed active opportunities into stored income.
Opportunities pin their context, payout and expiry. Only valid owner-session
opportunities can be welcomed. Purely local animations award nothing.

## Local development configuration

`forest seed-dev` inserts `development-visitors-v1` once, including when the earlier
catalogue already exists. It does not update existing plants or overwrite versions.
All values below are **test balance**, rejected outside local/test:

| Parameter | Fixture |
| --- | --- |
| Slot / heartbeat / lease | 30 / 10 / 45 seconds |
| Opportunity lifetime / visible limit | 20 seconds / 1 |
| Starter probability / probability cap / curve K | 0.5 / 0.8 / 2 attraction points |
| Gap protection | Third eligible live decision at latest |
| Inactive fraction / rate cap | 0.25 / 0.01 visits per second |
| Base / maximum capacity | 30 / 120 whole visits; base currently effective |
| Reward | 1 token per welcomed or claimed visit |

A starter produces 15 stored visits/hour (one per four inactive minutes), fills in
two inactive hours and ordinarily offers a live visitor within 90 seconds of
continuous eligible polling. Poll delivery/presentation delay can add time. A
grown plant can produce faster stored visits under its higher attraction. Real
capture performance must be measured before approving release balance.

## Endpoints

All paths below begin `/v1/me`. Owner identity comes exclusively from the verified
access token. All POST bodies include a UUID `requestId`.

| Method/path | Additional body | Result |
| --- | --- | --- |
| GET `/visitors` | None | Settle/read `VisitorSummary`; never claims currency |
| POST `/visitor-sessions` | `installationId` UUID | Start/resume own installation; summary |
| POST `/visitor-sessions/{id}/heartbeat` | `installationId` UUID | Settle/renew and poll; summary |
| POST `/visitor-sessions/{id}/end` | `installationId` UUID | Close active coverage; summary |
| POST `/visitor-opportunities/{id}/welcome` | None | Pinned reward receipt and summary |
| POST `/stored-visits/claim` | None | Whole stored-visit reward receipt and summary |

`VisitorSummary` includes server time, garden/context/rule IDs, monotonic visitor
version, fixture status, pinned per-plant attraction explanation, stored micro-units,
claimable whole count, capacity, inactive rate/hour, inactive time-to-full, token
balance, lifetime active/offline/total hosted counts, heartbeat cadence and current
session/opportunity. Int64 resource values use decimal strings. Visitor versions
are independent of layout versions. In active mode time-to-full is unavailable.

Reward receipts include request/event IDs, whole visits, tokens and the original
summary. Replays occur before expiry/session checks and preserve the original
result even after later accrual, logout/relogin or server restart. A different
request UUID for the same welcomed opportunity returns its first receipt. A
different request UUID for a stored claim is a new claim of then-current storage;
clients must retain uncertain requests. Reusing a request UUID for another payload,
operation or target fails `idempotency_conflict`.

Errors include `visitor_not_found` (404), `visitor_expired`,
`visitor_session_conflict`, `visitor_session_inactive` (409),
`visitor_rate_limited` (429), and unavailable/invalid rule errors (503). Owner
visitor traffic has a shared durable 90-successful-operations/minute budget;
completed mutation replay bypasses it. This is a gameplay bound, not complete
abuse prevention or a replacement for ingress limits before public release.

## Rules, observability and retention

`forest publish-visitor-rules FILE --version VERSION --effective-at ISO_TIMESTAMP
[--fixture]` validates a complete `VisitorRuleDefinition` and inserts a new future
version. It serialises with settlement and cannot rewrite a used context. Slot grid
and timing validation preserve fair presentation. Do not edit earned history or
change `is_fixture` to promote unapproved balance.

`visitor_settlements` record mode, covered ranges, before/after storage and exact
generated/discarded amounts. `visitor_opportunities` record issued/welcomed/expired
outcomes. `visitor_reward_events` and `visitor_wallet_entries` explain wallet and
hosted changes. Partial indexes bound current-session/pending-opportunity lookups.
No auth tokens or Health payloads enter these records.

This increment retains accounting, rewards, receipts, contexts and covered cursors;
there is **no automatic purge**. B10 must budget retention/archival and account
deletion without removing reward uniqueness or covered-slot guarantees. Long
absence work scales with configuration boundaries, not elapsed seconds or slots.

## Validation

Use the full PostgreSQL test suite, `scripts/smoke_activity.py`,
`scripts/smoke_visitors.py` and `scripts/simulate_visitors.py`. The visitor HTTP
script runs a test-only injectable-clock factory **outside the production package**,
creates/drops a randomly named database and proves restart replay. Its explicit
`--export-frontend-contract` writes only synthetic native wire fixtures.

Windows-only local helper: `python backend/scripts/validate_visitors_local.py
--smoke` from the repo root, using the dedicated local validation cluster. Normal
CI uses its provided PostgreSQL service. See `VALIDATION.md` for executed evidence
and `frontend/F6_VISITOR_ACCEPTANCE.md` for Mac/iPhone checks.
