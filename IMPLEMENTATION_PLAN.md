# Movement Forest implementation plan

Revised 20 October 2026 against `forest_game_v1_spec.md`, version 0.9.
This is a proposed delivery plan, not a source of approved balance values. F1–F3 are complete per the user's update. The B1–B3 backend is now implemented under `backend/`; see `backend/VALIDATION.md` for verification and remaining provider/container checks. B4 and subsequent mechanics are not implemented.

**Milestone status:** B1 and B2 accepted as complete by the user. Live managed-auth provider integration, approved production configuration and remote CI execution remain tracked follow-up work in `backend/VALIDATION.md`.

**B3 implementation:** atomic batch edits, canonical geometry, optimistic layout/catalogue checks, durable retries, consistent reads and disabled future visitor-accounting boundaries are implemented. All 132 backend tests and a real HTTP smoke check passed. No database migration or new production balance values are required. See backend validation for scope limits and the pending Docker image check.

## What changed from the previous plan

The core loop is now:

**Movement → independent planted-plant growth → stage-based attraction → active welcomes / stored-visit claims → visitor tokens → seed tickets → new sprouts.**

- Remove ticket entitlement from B4 and direct currency settlement from activity sync in B5. Activity may still advance permanent packet access.
- Add a substantial visitor milestone before collection. Separate its time accounting, active opportunities and stored claims into reviewable increments.
- Pin attraction profiles alongside growth and behaviour profiles in B2. Each duplicate remains an independent owned copy.
- Establish the transaction boundary in B3/B5 where elapsed visitor time will be settled before membership, stages or skills change. Implement actual visitor settlement in B6, with regression tests through the existing placement and growth paths.
- Budget frontend visitor behaviour explicitly. Basic visitor interaction is required gameplay; advanced swarm art and cosmetic plant effects can follow.
- Keep additional metrics, typed workouts and separate growth/visitor skill resolvers visible in the plan. A steps-first vertical slice does not remove the wider V1 input scope.

Existing B6–B9 become B7–B10 below. Existing F6 becomes F7 and F7 becomes F8, with visitor UI inserted as F6.

## Revised backend milestones

| Step | Work | Completion check |
| --- | --- | --- |
| **B1. Project foundation** | Docker-based FastAPI, SQLAlchemy, PostgreSQL, Alembic, environment configuration, request-scoped sessions, automated tests and GitHub CI. Establish explicit transaction ownership and a documented common lock order. | Fresh checkout can start the service, apply migrations explicitly and pass tests against PostgreSQL. CI is configured for the same database-backed checks. |
| **B2. Catalogue, accounts and ownership** | Species, variants, stage/model/thumbnail references, immutable growth/behaviour/attraction profiles, pinned owned copies, one garden per user and paginated inventory. Verify managed-auth tokens and enforce ownership. Add repeat-safe account/starter provisioning. | Two test accounts see their own state; neither can modify the other's plants. Duplicate copies have distinct IDs/progress. Awarded copies retain pinned profiles. Starter retries cannot grant extra plants. |
| **B3. Placement and transaction boundaries** | Continuous canonical coordinates, authoritative circular clearance, atomic batch plant/move/rotate/store, request deduplication, catalogue checks and separate layout/state versions. Centralise mutations so visitor settlement can be integrated before state changes. | Boundary/tangency/overlap, invalid precision, batch-swap, rollback, retry, stale-version and concurrent-edit tests pass. Storage preserves identity/progress; rotation and stage do not change radius. |
| **B4. Growth and attraction calculations** | Independently test normalised per-metric water, species coefficients, cumulative stages, terminal maturity caps and fractional carry. Derive attraction from placed copies and pinned stage profiles; define versioned visitor curve/capacity configuration. Start with neutral modifiers. | Fixed fixtures give exact growth and attraction, including duplicates, adults, omitted metrics and stored plants. Splitting inputs within unchanged contexts preserves totals. Activity calculations award no currency. |
| **B5. Activity synchronisation — priority** | `/v1/activity/sync`, enrolment baseline, game-date buckets, observed values versus per-metric credited watermarks, device policy, idempotency, per-plant growth credits, first-maturity/activity counters and recap records. Start with steps; add the wider input handlers incrementally in B8. | Replays, downward corrections, late totals, concurrent syncs and sync-versus-store races neither duplicate nor lose eligible growth. Stored plants remain unchanged. Sync mints no tokens/tickets. Reaching a stage leaves transforms intact. |
| **B6. Visitors — new core milestone** | Deliver B6a–B6c below. Integrate elapsed-time settlement into B3/B5 before their state changes. Include token wallet/ledger and authoritative lifetime hosted counters. | Active/inactive time never pays twice; slots cannot reroll; welcomes/claims pay once. Storage caps/fractions/reward versions survive reconnects, state changes and concurrent requests. |
| **B7. Collection economy** | Versioned visitor-token → ticket exchange, introductory/permanent visitor milestones, permanent packet unlocks, ticket spending and server-selected draws into sprout storage. Reuse shared wallet/idempotency rules. | Concurrent claims/exchanges/draws cannot overspend or double-grant. Retries return original amounts and awarded plant ID. Logical milestones cannot regrant on a rule-version edit. Spending never reverses permanent access or growth. |
| **B8. Additional inputs, boosts and skills** | Daily distance/active energy/flights, typed workout import/deduplication, personal marginal water boosts and the two-layer growth resolver. Separately enable visitor attraction/capacity skills. Use neutral weather or controlled fixtures initially; live weather, offline-rate skills and complex synergies require explicit scope decisions. | Each handler passes independently before combinations. Workout parent/segments and overlapping records cannot duplicate duration; intentional overlap with ordinary daily activity remains. Same-group skills resolve deterministically and stage activation uses the proper snapshot. Capacity removal preserves earned storage. |
| **B9. Social** | Friend requests, exact lookup, read-only visits, visibility and blocks. | Access tests pass; friend responses exclude health history, private visitor state and ledgers. Friends cannot redeem another garden's opportunities/storage. |
| **B10. Staging and release readiness** | API/managed PostgreSQL, HTTPS, secrets, controlled migrations, asset delivery, logs, monitoring, backups/restore checks and account deletion. Run closed-loop economy and long-absence/load checks. Start minimal staging after B3/B5 if useful. | Automated API tests pass on staging. Starter-to-first-draw pacing and realistic active versus offline income are evaluated. Retention/deletion, restore and device-release checks are completed before alpha release. |

### B6 should contain three increments

1. **B6a — Server timeline and stored production.** Injectable server clock; immutable attraction/rate/capacity contexts; lazy interval settlement; inactive accrual, fractions, cap overflow and pinned whole-visit reward lots. Integrate old-context settlement into placement, growth-stage and configuration boundaries. Prove no retroactive use of improved attraction.
2. **B6b — Active sessions and opportunities.** One authorised active session, bounded leases, heartbeat/end/expiry, durable active/inactive coverage, stable slot grid, persisted outcomes/gap protection, opportunity expiry and presentation limits. Reconnects must neither reroll slots nor replay missed arrivals in a burst.
3. **B6c — Welcome and claim rewards.** Consume valid issued opportunities once; claim whole stored visits in one transaction; retain valid fractions; token ledger and hosted counters. Replays return the completed result, including after its original opportunity/session has expired. Concurrent consumption and state changes are covered by PostgreSQL tests.

B6 is a substantial milestone with both accounting and behaviour requirements. It should not be treated as one small endpoint or one evening of work.

### Backend checkpoints

- **After B3:** accounts can retrieve inventory and persist valid garden arrangements through API tests.
- **After B5:** simulated movement grows placed plants and updates derived attraction. There are no earned tickets yet.
- **After B6:** active welcomes and stored claims earn tokens with durable accounting.
- **After B7:** API tests complete the new movement → growth → visitors → tokens → tickets → draw → storage/placement loop, including reopen/claim and retries.
- **After B8:** the wider chosen V1 metric/workout and skill rules are integrated. B7's steps-first slice is not the complete V1 feature set.

## Revised frontend milestones

| Step | Work | Completion check |
| --- | --- | --- |
| **F1–F3. Native foundation, rendering and initial HealthKit feasibility — complete** | Retain the SwiftUI/RealityKit foundation, 15-plant scene, camera/lighting and Health diagnostics. | Marked complete from the user's update. Wider newly scoped metric/device coverage is verified during subsequent integration. |
| **F4. Garden editor** | Inventory thumbnails, select/drag/rotate/store, exact shared clearance fixtures, adult previews and pending-versus-confirmed edits. | Local preview agrees with backend examples. Rejection restores confirmed state; offline previews do not imply committed edits. |
| **F5. Backend and activity integration** | Login, catalogue/inventory/garden repositories, durable activity uploads, cached viewing and confirmed growth/stage updates. Extend diagnostics/read paths for the four daily inputs and typed workouts as each backend handler lands. | Reopening/interrupted/repeated syncs are safe. Missing optional Health data does not block steps. Activity confirmation displays growth without inventing tickets. |
| **F6. Visitor interaction — new** | Attraction explanation; one shared visitor appearance/controller; arrival/flight/linger/tap/departure; server session lifecycle, heartbeat and opportunity expiry; pending/confirmed welcomes; stored capacity/time-to-full and one-interaction claim. | Background/edit/modal/friend-view transitions end or pause active mode correctly. Missed arrivals are not redeemed or converted into stored income. Connection loss, camera/foliage hit testing, reduced motion and device performance are acceptable. |
| **F7. Collection and social UI** | Token/ticket balances and exchange, visitor milestones, packet access/probabilities, server-confirmed draws/results, friends and read-only visits, one screen at a time. | Prices and rewards match confirmed server versions; retries do not reroll. Friend-view visitors are non-rewarding visuals only. |
| **F8. Hardening and polish** | Download/cache limits, durable retries, delayed Health inputs, session recovery, stage transitions, recap receipts, accessibility, long sessions and economy pacing. Cosmetic watering/swarm/unboxing effects follow durable mechanics. | A small TestFlight alpha completes the full loop over several days. No duplicate rewards on interruptions or reconnects; realistic active earnings and time-to-first-draw meet selected targets. |

F4 can proceed alongside B1–B3 using shared geometry fixtures. F5 follows backend contracts. F6 can prototype visuals early but is validated against B6. Exchange/collection UI follows B7. Native changes continue to require Mac/iPhone validation.

## Tonight: start B1–B3

Proposed timebox: approximately **4–6 focused hours**, with environment/auth setup able to extend it. Aim to finish B1, deliver a narrow B2 and begin a tested B3 slice. Full B1–B3 completion is not a prerequisite for a successful evening.

| Order | Rough budget | Scope and evidence |
| --- | --- | --- |
| **1. Set the implementation contract** | 20–30 min | Pick SQLAlchemy mode/driver; document auth boundary and common lock order. Use proposed 10×10 board, 0.001-unit coordinates and 0.01-degree yaw as development defaults. Label all test radii/thresholds/attraction values as fixtures, not approved oak balance. |
| **2. B1 foundation** | 60–90 min | API/PostgreSQL Docker setup, explicit Alembic command and initial migration, environment template, health/readiness checks, PostgreSQL test setup and backend CI. Run local start/migrate/test; report remote CI separately if not executed. |
| **3. B2 narrow ownership slice** | 75–105 min | Core identity/garden/catalogue/profile/owned-plant schema; a small oak-based development catalogue; profile pinning; repeat-safe starter provisioning; catalogue, own garden and paginated storage reads. Test with two accounts and duplicate copies. |
| **4. B3 placement slice** | 75–105 min | Atomic batch-edit endpoint with ownership checks, canonical decimal geometry, final-layout validation, garden locking, expected layout/catalogue versions, persisted request IDs/payload hashes and original-response replay. Include plant/move/rotate/store and a swap fixture. |
| **5. Verify and record handoff** | 30 min | Run migrations/tests against PostgreSQL and a small documented API walkthrough. Record completed checks, incomplete B2/B3 items and unresolved configuration decisions. |

### Tonight's proposed minimal API surface

- Health/readiness endpoints.
- `GET /v1/catalog`.
- `GET /v1/me/garden`.
- `GET /v1/me/inventory`.
- `POST /v1/me/garden/edits`.
- Account/starter provisioning through the selected auth flow or explicit local/test tooling.

Full bootstrap aggregation can follow when its visitor/wallet/activity fields exist. Do not populate future fields with fabricated production state.

### Authentication scope

B2 ultimately needs verified managed-auth tokens. If a provider is selected and available, wire verification now. Otherwise build the verifier interface with an explicitly local/test-only identity provider, test ownership, and leave real provider integration marked incomplete. Development identities must fail closed outside local/test configuration. No password system is required.

### Essential B3 checks

- Exact board-edge and circle tangency accepted; just-outside and just-overlapping layouts rejected.
- Invalid/nonfinite/excess-precision coordinates rejected; arbitrary valid yaw does not change clearance.
- Complete final batch validated, so swaps work and a failed action rolls back all actions.
- Store/replant preserves plant ID, growth, variant and pinned profiles.
- Another account's plants cannot be read through owner routes or placed/moved/stored.
- Same request/payload replays the original response without changing versions again; same ID/different payload fails.
- Stale layout and catalogue versions receive distinct structured errors.
- Competing same-version edits and competing placements into overlapping space cannot both commit.
- Layout/state counters remain separate so future growth alone does not invalidate a layout edit.

Concurrency and retry coverage is required before calling B3 complete. If the timebox ends first, record B3 as partial rather than skipping its invariants.

### Visitor preparation tonight

Pin attraction profiles now and put placement mutations behind one transaction-owning service. Define the old-state settlement → mutation → future-state refresh sequence and a server-clock boundary. Until B6, visitors remain disabled; no-op integration points are explicitly scaffolding, not completed accounting. B6 must replace them and add cross-feature regression tests before visitor earnings are enabled.

Do not build visitor tables/endpoints, growth sync, wallets, draws, friends, live weather, full legendary skills, cloud infrastructure or frontend changes tonight. Add their migrations with the feature that uses them.

### Practical stopping point

Two local/test users can read their own inventories. One can place, move, rotate and store an existing plant; invalid edits are rejected and restart preserves confirmed state. If time permits, batch swaps, replay and concurrent-edit tests also pass. Leave the repository runnable with exact commands and an honest milestone status.

## Specification points to preserve or resolve at the relevant milestone

1. **Two different baselines:** enrolment prevents rewarding old history; a personal activity baseline defines bonus bands. Do not merge them. Finalise timezone, backfill and device-switch rules before B5 is complete.
2. **Per-metric credits before per-plant conversion:** use section 6.3's typed watermarks with cumulative cap/band evaluation, rather than a universal garden growth or ticket entitlement. Preserve contexts when garden membership or effects change.
3. **Chunking invariance has context limits:** equal eligible inputs under the same pinned contexts must reconcile equally. Different actual stage/membership timing can legitimately alter future visitor income under credit-time membership. Do not apply a final-stage attraction retrospectively to make outcomes look equal.
4. **Visitor state is not only a clock:** choose stable slot origin, partial-slot transition handling, lease/heartbeat policy, issuance/visible limits, expiry and durable gap-protection rules before B6 ships. Replay completed welcomes before applying current expiry checks.
5. **Storage is not the wallet:** whole visits retain earned payout versions; claims award tokens and hosted progress once. Lowered capacity preserves earned storage; full storage discards overflow without a hidden backlog.
6. **Economy needs simulation:** agree starter-to-first-draw and realistic active-income targets; test mature/duplicate/small-footprint layouts and all supported skills. A lower theoretical offline rate alone does not prove a better active experience.
7. **Draft values stay draft:** oak radius, growth thresholds, attraction, prices and caps remain open. Fictional silver-birch examples are contract fixtures, not approved launch content. The workbook's former step-ticket fields are superseded and need authoring updates before runtime configuration export.
8. **Wider Health scope still needs coverage:** completed initial Health diagnostics do not by themselves certify the newly scoped distance, energy, flights and typed-workout cases. Extend and verify them as those features land.
9. **Maturity and attraction rules stay consistent:** confirm whether the maturity maximum equals the adult threshold. If they differ, define the role of any post-adult growth rather than inventing another stage. Reject unusable profile configurations. All four stage attraction values are nonnegative and strictly increase under the proposed V1 profile contract.
10. **Optional complexity stays explicit:** live weather needs activity-time buckets; daily totals alone cannot attribute rainy steps. Complex synergies, recurring daily quests, visitor species inventories, bespoke visitor AI and offline-rate skills are not silently included in the minimal loop.
