# Movement Forest implementation plan

Revised 23 October 2026 against `forest_game_v1_spec.md`, version 0.13.
This delivery plan is not a source of approved balance values. B1–B6 and F1–F6 are accepted as complete for the current steps/email-authentication development slice, with the explicit F5a provider exceptions below. B7/F7 collection source is implemented with native acceptance pending; wider inputs, progression rewards, social, deployment and final visual polish remain future work.

**Current checkpoint — 23 October 2026:** the user accepts work through **B6/F6**,
including B6a–B6c, the F5 steps slice and the tested F5a email-authentication path.
Physical-iPhone testing confirmed active butterfly welcomes, token/count updates,
stored accrual/claims, smooth visitor motion and removal of sync/placement camera
jerks. SMTP and Google/Apple configuration and their dependent live acceptance
remain deferred. The placeholder visitor art and flat screen-space flight are
accepted for development; final art and garden-depth presentation move to **F8**
and do not reopen B6/F6. See
[backend/VISITOR_API.md](backend/VISITOR_API.md) for the delivered contract and
[frontend/F6_VISITOR_ACCEPTANCE.md](frontend/F6_VISITOR_ACCEPTANCE.md) for the
existing-account Tailscale walkthrough. Executed automated validation is recorded
separately in backend/frontend `VALIDATION.md`; user-reported device acceptance
does not imply unrecorded XCTest, Release-build or remote-CI results.

Delivered policies: PostgreSQL time after accounting locks; first B6 interaction
activates a garden without historical grants; stable UTC 30-second slots; one
installation-bound session and one visible opportunity; bounded leases; exact
fractional inactive storage and pinned whole-visit reward lots; atomic token
ledger/hosted counters; durable iOS control/reward requests. Visitor skills remain
B8, exchange/draws remain B7/F7 and deployment remains B10. New visitor fixture
rates are provisional and do not replace approved balance.

## Implementation history

The dated notes below preserve the original delivery/validation record. Their
pending-device and next-work statements are historical; the current checkpoint
and milestone tables govern accepted scope and remaining work.

**B4/B5 implementation — 22 October 2026:** exact neutral growth calculations, derived garden attraction, immutable fixture rule versions, steps-first activity enrolment/sync, one-device replacement/baseline policy, cumulative watermarks, atomic per-copy credits, counters and recoverable recaps are implemented. [backend/ACTIVITY_API.md](backend/ACTIVITY_API.md) is the F5 integration contract. The explicit queue policy accepts seven game dates per observation with a bounded 30-day unresolved-upload grace; completed receipts replay beyond it. Initial enabled maturity profiles require adult threshold = terminal maximum. No activity currency, visitor production, B8 handlers or cloud deployment is included. Test fixture values remain unapproved production balance.

**Milestone status:** B1 and B2 accepted as complete by the user. Supabase Auth source integration is implemented in F5a; native/hosted-provider acceptance remains the next check to close B2's provider follow-up. Approved production configuration and remote CI execution remain tracked follow-up work in `backend/VALIDATION.md`.

**F5 implementation — 22 October 2026:** the delivered slice uses development-token
login under the earlier decision. That deferral is superseded by the Supabase
selection and implemented F5a source; native/live login acceptance remains pending.
Implemented in-app account provisioning, scoped confirmed-garden cache, separate
Health upload consent, account-timezone step reads, durable enrolment/sync/recap
requests, device replacement, membership preflight, monotonic confirmed growth,
resolved pinned-profile progress and stage updates. Native Xcode/iPhone acceptance
remains pending; use [frontend/F5_ACCEPTANCE.md](frontend/F5_ACCEPTANCE.md).
Foreground/manual recovery is required now; Health observer background delivery
and cosmetic watering remain deferred increments.

**Architecture/auth update — 22 October 2026 (documentation only):** retain FastAPI,
SQLAlchemy/psycopg and Alembic; target Cloud Run compute plus Supabase PostgreSQL,
Auth and Storage/CDN. Deliver F5a next using hosted Supabase Auth and the existing
local game database. Move the database and remote assets separately during B10.
Email/password, Google, native Apple and explicit identity linking are planned;
game usernames remain separate from authentication. Setup instructions are in
[SUPABASE_SETUP.md](SUPABASE_SETUP.md). No cloud resources, code, dependencies,
secrets or environment configuration are changed by this plan update.

**F5a source implementation — 23 October 2026:** added pinned Supabase Swift Auth,
email/password/confirmation/recovery, Keychain session restore/refresh,
identity-scoped API retries, game onboarding, conditional Google browser and native
Apple login/linking, logout/switch isolation and late-response protection. Docker
forwards JWKS settings while retaining local game PostgreSQL. All **242 backend
tests passed** using disposable local PostgreSQL databases; source/project/resource
and Swift syntax checks passed. Xcode/XCTest, hosted Supabase/email/provider
acceptance and physical iPhone checks remain pending. Configure email first using
[frontend/F5A_AUTH_ACCEPTANCE.md](frontend/F5A_AUTH_ACCEPTANCE.md); leave Google/Apple
disabled until their provider setup is ready. No project/credentials were created.

**Workout guard / onboarding update — 22 October 2026:** the existing iOS workout query excludes `HKMetadataKeyWasUserEntered = true` before its result limit. B4/B5 still accept steps only; do not add workout uploads/rewards before B8. B8 must preserve the manual-entry flag and exclude flagged workouts/segments before reward accounting. Onboarding remains unimplemented; section 3.1 of the spec now defines Apple Fitness recording and third-party app → Apple Health setup, including Strava instructions, for implementation with onboarding.

**B3 implementation:** atomic batch edits, canonical geometry, optimistic layout/catalogue checks, durable retries, consistent reads and disabled future visitor-accounting boundaries are implemented. All 132 backend tests and a real HTTP smoke check passed. No database migration or new production balance values are required. See backend validation for scope limits and the pending Docker image check.

## What changed from the previous plan

The core loop is now:

**Movement → independent planted-plant growth → stage-based attraction → active welcomes / stored-visit claims → visitor tokens → unopened packs → new sprouts.**

- Remove ticket entitlement from B4 and direct currency settlement from activity sync in B5. Activity may still advance permanent packet access.
- Add a substantial visitor milestone before collection. Separate its time accounting, active opportunities and stored claims into reviewable increments.
- Pin attraction profiles alongside growth and behaviour profiles in B2. Each duplicate remains an independent owned copy.
- Establish the transaction boundary in B3/B5 where elapsed visitor time will be settled before membership, stages or skills change. Implement actual visitor settlement in B6, with regression tests through the existing placement and growth paths.
- Budget frontend visitor behaviour explicitly. Basic visitor interaction is required gameplay; advanced swarm art and cosmetic plant effects can follow.
- Keep additional metrics, typed workouts and separate growth/visitor skill resolvers visible in the plan. A steps-first vertical slice does not remove the wider V1 input scope.
- F5a supplied the real-session boundary for the accepted F5/F6 slice. Preserve completed mechanics; finish SMTP and Google/Apple setup and dependent acceptance before enabling those deferred paths.

Existing B6–B9 become B7–B10 below. Existing F6 becomes F7 and F7 becomes F8, with visitor UI inserted as F6.

## Revised backend milestones

| Step | Work | Completion check |
| --- | --- | --- |
| **B1. Project foundation — complete** | Docker-based FastAPI, SQLAlchemy, PostgreSQL, Alembic, environment configuration, request-scoped sessions, automated tests and GitHub CI. Establish explicit transaction ownership and a documented common lock order. | Fresh checkout can start the service, apply migrations explicitly and pass tests against PostgreSQL. CI is configured for the same database-backed checks. |
| **B2. Catalogue, accounts and ownership — complete** | Species, variants, stage/model/thumbnail references, immutable growth/behaviour/attraction profiles, pinned owned copies, one garden per user and paginated inventory. Verify Supabase access tokens and enforce ownership. Add repeat-safe account/starter provisioning. Core implementation accepted; email-authentication integration accepted in F5a. SMTP and Google/Apple follow-ups remain explicit there. | Two test accounts see their own state; neither can modify the other's plants. Duplicate copies have distinct IDs/progress. Awarded copies retain pinned profiles. Starter retries cannot grant extra plants. Real linked-provider acceptance is tracked by F5a rather than assumed complete. |
| **B3. Placement and transaction boundaries — complete** | Continuous canonical coordinates, authoritative circular clearance, atomic batch plant/move/rotate/store, request deduplication, catalogue checks and separate layout/state versions. Centralise mutations so visitor settlement can be integrated before state changes. | Boundary/tangency/overlap, invalid precision, batch-swap, rollback, retry, stale-version and concurrent-edit tests pass. Storage preserves identity/progress; rotation and stage do not change radius. |
| **B4. Growth and attraction calculations — complete** | Independently test normalised per-metric water, species coefficients, cumulative stages, terminal maturity caps and fractional carry. Derive attraction from placed copies and pinned stage profiles; define versioned visitor curve/capacity configuration. Start with neutral modifiers. | Fixed fixtures give exact growth and attraction, including duplicates, adults, omitted metrics and stored plants. Splitting inputs within unchanged contexts preserves totals. Activity calculations award no currency. |
| **B5. Activity synchronisation — complete steps slice** | `/v1/activity/sync`, enrolment baseline, game-date buckets, observed values versus per-metric credited watermarks, device policy, idempotency, per-plant growth credits, first-maturity/activity counters and recap records. Start with steps; add the wider input handlers incrementally in B8. | Replays, downward corrections, late totals, concurrent syncs and sync-versus-store races neither duplicate nor lose eligible growth. Stored plants remain unchanged. Sync mints no tokens/tickets. Reaching a stage leaves transforms intact. |
| **B6. Visitors — complete** | Deliver B6a–B6c below. Integrate elapsed-time settlement into B3/B5 before their state changes. Include token wallet/ledger and authoritative lifetime hosted counters. | Active/inactive time never pays twice; slots cannot reroll; welcomes/claims pay once. Storage caps/fractions/reward versions survive reconnects, state changes and concurrent requests. |
| **B7. Collection economy — source implemented** | Versioned token exchange for owned unopened packs, immutable rarity-first pools, server openings into sprout storage, shared wallet/idempotency and controlled publication/retirement. All test offers available; unlock/milestone progression deferred. | PostgreSQL concurrency/rollback/replay, migration preservation, ledger reconciliation, pool-edit invariance and real HTTP loop pass; see backend validation. |
| **B8. Additional inputs, boosts and skills** | Daily distance/active energy/flights, typed workout import/deduplication, personal marginal water boosts and the two-layer growth resolver. Separately enable visitor attraction/capacity skills. Use neutral weather or controlled fixtures initially; live weather, offline-rate skills and complex synergies require explicit scope decisions. | Each handler passes independently before combinations. Workout parent/segments and overlapping records cannot duplicate duration; intentional overlap with ordinary daily activity remains. Same-group skills resolve deterministically and stage activation uses the proper snapshot. Capacity removal preserves earned storage. |
| **B9. Social** | Friend requests, exact lookup, read-only visits, visibility and blocks. | Access tests pass; friend responses exclude health history, private visitor state and ledgers. Friends cannot redeem another garden's opportunities/storage. |
| **B10. Staging and release readiness** | Deploy the FastAPI image to Cloud Run; migrate game PostgreSQL to Supabase with controlled Alembic, tested TLS/pooler/driver settings and bounded aggregate connections. Publish immutable shared assets to Supabase Storage/CDN. Add HTTPS, secrets, logs, monitoring, backup/restore and coordinated Supabase/game account deletion. Run economy and long-absence/load checks. | Automated API tests pass on isolated staging. No game-table access bypasses FastAPI. Database migration/restore, asset delivery, cold-start/first-sync latency and resource budgets are verified. Starter-to-first-draw pacing, retention/deletion and device-release checks pass before alpha. Real Auth is already delivered in F5a; full cloud deployment is not its prerequisite. |

### B6 completed increments

1. **B6a — Server timeline and stored production.** Injectable server clock; immutable attraction/rate/capacity contexts; lazy interval settlement; inactive accrual, fractions, cap overflow and pinned whole-visit reward lots. Integrate old-context settlement into placement, growth-stage and configuration boundaries. Prove no retroactive use of improved attraction.
2. **B6b — Active sessions and opportunities.** One authorised active session, bounded leases, heartbeat/end/expiry, durable active/inactive coverage, stable slot grid, persisted outcomes/gap protection, opportunity expiry and presentation limits. Reconnects must neither reroll slots nor replay missed arrivals in a burst.
3. **B6c — Welcome and claim rewards.** Consume valid issued opportunities once; claim whole stored visits in one transaction; retain valid fractions; token ledger and hosted counters. Replays return the completed result, including after its original opportunity/session has expired. Concurrent consumption and state changes are covered by PostgreSQL tests.

B6a–B6c are complete and accepted for the current development slice. Final visitor art and depth presentation are F8 follow-ups; they do not change the completed accounting contract.

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
| **F4. Garden editor — complete** | Inventory thumbnails, select/drag/rotate/store, exact shared clearance fixtures, adult previews and pending-versus-confirmed edits. | Local preview agrees with backend examples. Rejection restores confirmed state; offline previews do not imply committed edits. |
| **F5. Backend and activity integration — complete steps slice** | Development-token account provisioning, catalogue/inventory/garden repositories, durable step uploads, scoped cached viewing and confirmed growth/stage updates are implemented. The accepted F5a email path provides real login. Extend wider metric/workout integration only as B8 handlers land. | Reopening/interrupted/repeated syncs are safe. Missing optional Health data does not block steps. Activity confirmation displays growth without inventing tickets. Accepted by the user for the steps slice; wider inputs remain B8. Automated native/Release results require their own execution record. |
| **F5a. Supabase authentication — accepted email slice; provider setup deferred** | Email/password, Google, native Apple; Keychain-backed SDK sessions; asynchronous API token refresh; existing account/starter onboarding; linked-method settings; safe logout/account switching and durable queue recovery. Configure FastAPI JWKS against hosted development Auth while keeping game PostgreSQL local. | Each method signs in on a real iPhone. Linked methods return the same Supabase subject/internal user/garden with one starter. Refresh/reauthentication preserve request UUIDs, watermarks and consent. Different accounts cannot share cached state or queued uploads. Email path accepted; SMTP and Google/Apple setup and dependent live/linking acceptance remain deferred below. |
| **F6. Visitor interaction — complete** | Attraction explanation; one shared visitor appearance/controller; arrival/flight/linger/tap/departure; server session lifecycle, heartbeat and opportunity expiry; pending/confirmed welcomes; stored capacity/time-to-full and one-interaction claim. | Background/edit/modal/friend-view transitions end or pause active mode correctly. Missed arrivals are not redeemed or converted into stored income. Functional visitor logic is accepted from user testing, including smooth motion and stable framing. Final visitor render and garden-depth presentation are deferred to F8; retain lifecycle, retry, accessibility and performance regression checks. |
| **F7. Collection UI — source implemented** | Simple Exchange/Catalog/Draws side menu, disclosed prices/odds, owned packs, confirmed results/history and durable account-scoped recovery. Social screens follow B9; unlocks/milestones are deferred. | Portable resource/contract/syntax checks pass. Xcode/Release and physical iPhone acceptance remain pending; use F7_COLLECTION_ACCEPTANCE.md. |
| **F8. Hardening and polish** | Download/cache limits, durable retries, delayed Health inputs, session recovery, stage transitions, recap receipts, accessibility, long sessions and economy pacing. Final visitor render and garden-relative depth/perspective, plus cosmetic watering/swarm/unboxing effects, follow durable mechanics; see the F8 backlog below. | A small TestFlight alpha completes the full loop over several days. No duplicate rewards on interruptions or reconnects; realistic active earnings and time-to-first-draw meet selected targets. |

Work through B6/F6 is accepted for the steps/email-authentication slice. Next deliver B7 collection mechanics with F7 exchange/draw UI; F7 social screens follow B9. SMTP and Google/Apple setup and dependent acceptance remain explicit F5a follow-ups before those paths are enabled or relied on in wider testing. Wider Health inputs remain B8. Final visitor art and depth polish remain F8. Native changes continue to require Mac/iPhone validation.

## F5a: accepted email-authentication slice; deferred provider follow-ups

### Timing and scope

The user has accepted the email-authentication/session boundary used by the current F5/F6 slice. SMTP and Google/Apple setup, live linking and dependent provider tests remain deferred. The scope and acceptance requirements below remain the reference for closing those follow-ups; they are not a new instruction to repeat accepted work. F5a retains B4/B5 calculations, enrolment/device policy and F5 activity contracts. Broader Health uploads, onboarding polish, garden merges and cloud database/asset migration remain separate milestones.

The initial environment is **iPhone → hosted Supabase Auth + local FastAPI → local Docker PostgreSQL**, with the existing private HTTPS path to the development API. The phone needs internet access for provider login/refresh, but game data need not move to Supabase yet. Start on an eligible Free development project; paid infrastructure is not required to exercise real authentication.

### Implementation scope and acceptance stages

The source for A2–A4 and their regression coverage is implemented. The current
email path is accepted from user testing; SMTP and Google/Apple portions of A1,
A4 and A5 still need provider configuration and live evidence. Unrecorded native
test/Release-build results must remain distinct from manual acceptance. The pinned
SDK supports native Apple linking, so the browser Apple
fallback below is unnecessary for the delivered path. Native Google remains
optional. Use the current [F5a walkthrough](frontend/F5A_AUTH_ACCEPTANCE.md).

| Order | Planned work | Evidence required |
| --- | --- | --- |
| **A1. Configure and prove the provider contract** | Complete [SUPABASE_SETUP.md](SUPABASE_SETUP.md). Record project URL, callback scheme, bundle ID, supported Swift SDK version and asymmetric signing algorithm. Enable email, Google, Apple and manual linking. Verify the documented Swift linking path; use browser OAuth linking if native ID-token linking is unavailable, including Apple's web credentials. Begin with Google browser OAuth and native Apple login; a separate native Google SDK is optional. | Real test sessions validate through the configured JWKS verifier. A provider spike proves Apple-relay/different-email linking can preserve one Supabase subject. Failed/cancelled/conflicting linking leaves the original account intact. Do not label SDK support or provider acceptance complete from configuration alone. |
| **A2. Integrate the iOS session boundary** | Add the supported Supabase Swift dependency and session service, Keychain persistence, email registration/confirmation/sign-in/reset, Google sign-in, native Apple nonce/token exchange and callback handling. Introduce asynchronous current-token retrieval with coordinated refresh; handle restore, network failure, explicit logout and account changes. Keep generated-token tooling restricted to isolated local/test builds/configuration. | Native tests cover session events and lifecycle races; Debug and Release builds compile. Release supports configured real login rather than relying on the current sample-only/development connection path. Secrets never enter app resources, logs or request journals. |
| **A3. Reuse game onboarding and protect F5 recovery** | Resolve identity with `GET /v1/me`; create game profile/garden/starter through existing `POST /v1/accounts` only for an explicit missing account. Preserve the server's internal game UUID as the cache/queue scope. On a 401, refresh/retry at most once with the same request bytes/UUID and same identity; retain unknown outcomes. Cancel/detach old account work and ignore stale completions before attaching another account. | Registration retries/concurrency create one starter. Expired sessions, connection loss, relaunch and same-account reauthentication do not duplicate growth or reset baselines. Account A's queued operations/cache remain inaccessible to B and can recover when A signs in again. Existing B4/B5/F5 contract checks still pass. |
| **A4. Link sign-in methods to the existing garden** | Add account settings showing linked methods and an explicit signed-in link action for Google/Apple. Distinguish linking from ordinary sign-in. Support email/password access on an existing social account through authenticated email verification/password setup where needed, not a second registration. Refresh identity/profile after linking and retain the current game account. | Linked providers reach exactly the same subject, internal user, garden, owned plants and pending receipts. Different/Apple relay email paths work. An identity already owned by another user produces a conflict with no automatic merge, transfer, second starter or lost journal. |
| **A5. Native/regression acceptance and handoff** | Extend API auth/ownership checks and iOS session/queue tests, then repeat relevant F5 real-step and recovery cases using real sessions. Update frontend/backend setup and acceptance documents during implementation, recording live checks separately from mocks. | Complete the gate below on Mac/iPhone before calling F5a done. Record credentials/callback configuration privately and leave only nonsecret templates/documentation in Git. |

The implemented F5a boundary replaces the original synchronous development-token-only path with asynchronous scoped session retrieval/refresh. Preserve `AccountDiskStore`'s server/internal-user partitioning; do not rename a saved journal to match a new subject. Before game provisioning supplies an internal user ID, scope pending account requests by environment and verified issuer/subject. Bind each repository/request to its expected issuer/subject and check identity before sending with a refreshed token and before applying responses. Preserve late-response protection and serialize recovery with identity changes. Manual linking must still be proven during deferred live-provider acceptance.

### F5a full-provider acceptance requirements

These requirements remain the reference for full provider completion. Current
email-path acceptance does not mark deferred SMTP, Google/Apple or linking checks
as passed, or assert automated checks without an execution record.

1. **Registration and return:** confirmed email/password, Google and native Apple each reach a game account on a real iPhone. Cancelled login and incomplete email confirmation create no game state. Missing profile versus network/auth failures are distinct. Duplicate/concurrent provisioning awards one starter.
2. **Linking preserves ownership:** create one garden, place/grow a plant, then link another provider from that signed-in account. Sign out and sign in through each linked method: Supabase subject, internal user/garden/plant IDs, progress and starter count match. Exercise both a matching verified email and a differing/Apple relay address. Set up password access on an existing social account without re-registering it.
3. **Conflict handling:** a provider identity already belonging to a second Supabase user cannot take over/merge the first garden. Cancelled/failed callbacks leave the active account unchanged. Do not remove the last usable sign-in method; full unlink controls remain deferred.
4. **Durable F5 recovery:** expire an access token while an activity/edit result is unknown; refresh or reauthenticate and replay the original request UUID/body. Test offline relaunch and unavailable/invalid refresh separately. No duplicate growth, starter, recap or new baseline; no silent queue deletion. Linked login on the same installation does not trigger device replacement.
5. **Account isolation:** switch A → B while A has pending activity/edit/recap work and an in-flight response. B sees only B's state and uploads only B's records; returning as A safely resolves A's requests. Login/linking does not enable Health upload consent for a different account. Signed-out UI hides private cached gardens.
6. **Backend trust:** accept real project tokens with the configured issuer, `authenticated` audience and matching ES256/RS256 key. Reject tampered, expired, wrong-project/audience/algorithm and development tokens in JWKS mode. Exercise key changes and provider unavailability without accepting unverified identity. Disabled accounts cannot use an otherwise valid token.
7. **Build/device evidence:** run appropriate existing PostgreSQL-backed backend tests and native Swift tests plus a Release build. Exercise signup confirmation/reset deep links, Google callbacks, Apple native login and the selected linking flow on a real iPhone. Re-run the relevant [F5 acceptance](frontend/F5_ACCEPTANCE.md) growth/storage/offline cases with real sessions; retain pending device evidence honestly.

### Existing development account transition

Generated-token users have a different issuer/subject from Supabase users. Default to fresh Supabase test accounts and separate fixture gardens; no production-player migration is currently required. If a specific development garden must survive, first design a reviewed one-time rebinding process proving control of both identities, enforcing target uniqueness and preserving the internal game user ID. Do not infer ownership from username/email, merge two populated accounts, reset growth/watermarks or rewrite journals to a different game user. This optional preservation work is separate from normal provider linking.

### Deferred deployment work

F5a does not change the game database connection, upload assets or deploy Cloud Run. B10 applies Alembic to Supabase PostgreSQL, verifies connection/SSL/pooler/grant compatibility, closes Data API bypasses and tests backup/restore. Asset delivery adds the remote resolver/download cache and trusted publishing. Cloud Run receives a bounded autoscaling/pool budget and measured cold-start policy. Account deletion across Supabase Auth and game state, including Apple revocation requirements, remains a release gate in B10; full unlink UI and garden-merge support remain outside F5a.

## B7/F7 collection implementation — 23 October 2026

This current decision supersedes ticket/immediate-draw wording in the earlier
milestone tables: **tokens → unopened packs → plants**. The first slice makes
both development offers available immediately. Permanent unlocks, milestones,
pity, duplicate conversion and all friend/social work are deferred. Existing
B6/F6 acceptance and SMTP/provider follow-ups remain unchanged.

Implemented source: explicit Alembic `0004_collection`, one authoritative token
balance with append-only collection spending/receipts, immutable pack contracts,
profile/member retention, versioned offers and controlled publication/retirement,
strict quantity/price checks, rarity-first secure draws, owner pack inventory,
unique openings into sprout storage and durable replay. Native source adds a
simple side menu, Exchange/Catalog/Draws, full catalogue metadata, an asset index,
account-scoped collection journals, result/history recovery, ordered wallet
versions shared with visitor rewards and Storage refresh after an award.

Contract and publishing: [backend/COLLECTION_API.md](backend/COLLECTION_API.md).
Server update/device flow: [frontend/F7_COLLECTION_ACCEPTANCE.md](frontend/F7_COLLECTION_ACCEPTANCE.md).
Actual automated execution belongs in each `VALIDATION.md`; source/syntax checks
do not imply Xcode, XCTest, Release-build or physical-device acceptance. Existing
game databases are not automatically migrated/seeded by implementation or tests.

## F8 final visitor presentation polish — deferred

The current functional B6/F6 experience is accepted. Schedule these visual changes
in the existing final hardening/polish milestone, after the remaining gameplay:

- Replace the temporary butterfly with the intended visitor render/asset, checking
  its materials, orientation, scale and flight/wing animation on the iPhone.
- Add garden-relative flight depth and camera-aware perspective so visitors read
  as flying through the garden, rather than moving flat across the screen.
  Preserve reliable tapping and the accessible Welcome action as visuals change.
- Verify portrait/landscape and orbit/pan/zoom, Reduce Motion and VoiceOver, smooth
  motion between server responses, and stable framing during sync/invalid
  placement. Visual changes must preserve server expiry and single-award rewards.

Cosmetic watering, swarm and unboxing effects remain in F8 as already planned.
These presentation improvements do not block B7/F7 or reopen completed B6/F6 logic.

## Historical B1–B3 delivery outline

This outline records the earlier local-foundation scope; B1–B3 are now implemented. It is not the next-work instruction. F5a above supersedes its provider deferral and its original exclusion of frontend/provider work.

The original timebox was approximately **4–6 focused hours**, with environment/auth setup able to extend it. It aimed to finish B1, deliver a narrow B2 and begin a tested B3 slice; the table below preserves that historical scope.

| Order | Rough budget | Scope and evidence |
| --- | --- | --- |
| **1. Set the implementation contract** | 20–30 min | Pick SQLAlchemy mode/driver; document auth boundary and common lock order. Use proposed 10×10 board, 0.001-unit coordinates and 0.01-degree yaw as development defaults. Label all test radii/thresholds/attraction values as fixtures, not approved oak balance. |
| **2. B1 foundation** | 60–90 min | API/PostgreSQL Docker setup, explicit Alembic command and initial migration, environment template, health/readiness checks, PostgreSQL test setup and backend CI. Run local start/migrate/test; report remote CI separately if not executed. |
| **3. B2 narrow ownership slice** | 75–105 min | Core identity/garden/catalogue/profile/owned-plant schema; a small oak-based development catalogue; profile pinning; repeat-safe starter provisioning; catalogue, own garden and paginated storage reads. Test with two accounts and duplicate copies. |
| **4. B3 placement slice** | 75–105 min | Atomic batch-edit endpoint with ownership checks, canonical decimal geometry, final-layout validation, garden locking, expected layout/catalogue versions, persisted request IDs/payload hashes and original-response replay. Include plant/move/rotate/store and a swap fixture. |
| **5. Verify and record handoff** | 30 min | Run migrations/tests against PostgreSQL and a small documented API walkthrough. Record completed checks, incomplete B2/B3 items and unresolved configuration decisions. |

### Original minimal API surface

- Health/readiness endpoints.
- `GET /v1/catalog`.
- `GET /v1/me/garden`.
- `GET /v1/me/inventory`.
- `POST /v1/me/garden/edits`.
- Account/starter provisioning through the selected auth flow or explicit local/test tooling.

Full bootstrap aggregation can follow when its visitor/wallet/activity fields exist. Do not populate future fields with fabricated production state.

### Original authentication scope and current follow-up

The original local/test verifier allowed B2 ownership and F5 activity work before provider selection. Supabase is now selected and F5a closes live-provider integration. Development identities continue to fail closed outside isolated local/test configuration. Supabase handles password credentials; the game backend does not implement its own password system.

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

### Original visitor preparation

Pin attraction profiles now and put placement mutations behind one transaction-owning service. Define the old-state settlement → mutation → future-state refresh sequence and a server-clock boundary. Until B6, visitors remain disabled; no-op integration points are explicitly scaffolding, not completed accounting. B6 must replace them and add cross-feature regression tests before visitor earnings are enabled.

The original foundation scope excluded visitor tables/endpoints, growth sync, wallets, draws, friends, live weather, full legendary skills, cloud infrastructure and frontend changes. Current milestones above now govern this work. Add migrations with the feature that uses them.

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
11. **Stable identity precedes more rewards:** F5a links provider methods within one Supabase user and preserves the internal game user ID. Auth refresh/linking must not regrant starters, reset activity enrolment or move queued Health data to another account. Real-provider acceptance is distinct from the completed generated-token F5 slice.
