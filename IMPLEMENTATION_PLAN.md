# Movement Forest implementation plan

Revised 27 October 2026 against `forest_game_v1_spec.md`, version 0.23.
This delivery plan is not a source of approved balance values. B1–B6 and F1–F6 are accepted as complete for the current steps/email-authentication development slice, with the explicit F5a provider exceptions below. B7/F7 collection source is implemented with native acceptance pending; wider inputs, progression rewards, social, deployment and final visual polish remain future work.

**Current presentation handoff — 27 October 2026:** F8.3 is completed and
user-accepted after live testing of commit `219381b`, pushed to GitHub `main`.
My plants / Garden / Edit / Activity, details-first focused editing, frontend-wide
developer-output cleanup and retained internal diagnostics form the accepted
baseline. The follow-up batch is **F8.3b — Garden viewport and layout refinement** below:
a continuous scene, transparent compact header and plant-selection popup, direct
visitor interaction and quieter routine feedback. Source is implemented locally;
portable validation passes. Mac/native and iPhone acceptance remain pending.
Token shimmer/floating +1 and other animations,
workout eligibility, pack-opening cleanup, asset delivery and later custom designs
remain separate. User acceptance does not establish unrecorded native automated
test or CI results; executed checks remain in `frontend/VALIDATION.md`.

The first B8 skill/cap increment is now source-implemented below, including
Sleeping Dew and the native Active skills disclosure. Its selected provisional
modifier caps supersede earlier open-cap notes. Wider personal/input increments
remain scheduled separately; this does not mark all of B8 complete.

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

**B8 weather scope — 24 October 2026:** weather integration and weather-dependent skills are deferred to a later increment. B8 keeps weather neutral; no weather API, location permission, weather ingestion/storage, weather handler/UI or weather-specific acceptance work is required. The future design and WeatherKit membership/request-budget notes remain in spec section 6.4; no provider is selected.

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
| **B8. Additional inputs, boosts and skills** | Daily distance/active energy/flights, typed workout import/deduplication, personal marginal water boosts and the two-layer growth resolver. Separately enable visitor attraction/capacity skills. Keep weather neutral; weather integration and weather-dependent skills are deferred beyond B8. Offline-rate skills and complex synergies still require explicit scope decisions. | Each included handler passes independently before combinations. Workout parent/segments and overlapping records cannot duplicate duration; intentional overlap with ordinary daily activity remains. Same-group skills resolve deterministically and stage activation uses the proper snapshot. Capacity removal preserves earned storage. Weather integration/conditional-weather tests are outside B8. |
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
| **F8. Hardening and polish** | Download/cache limits, durable retries, delayed Health inputs, session recovery, stage transitions, recap receipts, accessibility, long sessions and economy pacing. Final visitor render and garden-relative depth/perspective, cosmetic watering/swarm effects and the agreed two-tap pack opening follow durable mechanics; see the F8 backlog below. | A small TestFlight alpha completes the full loop over several days. No duplicate rewards on interruptions or reconnects; realistic active earnings and time-to-first-draw meet selected targets. |

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

### Species-first draws and grouped catalogue — current update

The initial pack purchase/opening behaviour was confirmed by the user. The next
source update uses rarity → uniformly selected species → weighted variant.
Species own rarity; each published schema-2 contract freezes its species list,
variant weights and resolved profile references. Adding variants cannot inflate
species chance. Schema-1 packs/results remain unchanged and open through their
original sampler. Alembic `0005_species_draws` adds species rarity without changing
owned plants, balances, packs or receipts.

The development catalogue now includes Common Oak (three variants) and Common
Moonwillow (two variants). Woodland v2 costs five fixture tokens and picks species
50/50; Oak variants are 75/20/5 and Moonwillow variants 90/10. A separate eight-token
Moonwillow pack tests guaranteed species award, placement and growth. All values
are unapproved fixtures. Superseded offers stop selling, while acquired packs keep
their versions. Seeding is explicit and repeat-safe, not an application startup task.

F7 includes one catalogue entry per species, a variant selector inside its detail,
species rarity and pack-specific conditional/overall variant odds. New Swift models
read schema 1 and 2. Hidden-stage discovery is deferred to the polishing scope
below. See backend/frontend VALIDATION.md for actual execution; source/parsing does
not imply native Xcode/Release or device acceptance of this update.

## B8 skill/cap increment — 24 October 2026

Source implements the first complete garden-skill increment: immutable behaviour
schema 2; validated reusable adult activation, optional placed-count conditions,
recipient selectors, fixed/capped-copy magnitudes, deterministic strongest groups;
separate growth and visitor destinations; exact two-layer percentages; flat
visitor additions; immutable `b8-caps-v1` policy; old-state visitor settlement;
one pre-credit source snapshot across the entire upload; credit/recap provenance.
Alembic `0006_garden_skills` replaces the SQL neutral-only validator and retains
legacy schemas/data. No startup migration, profile rewrite or account grant.

Selected caps supersede earlier open-cap notes: +150% per activity metric and
combined water (×6.25 across layers), +50% plant/garden attraction with final ×2
unmodified-base ceiling, total flat attraction min(+10 points, 25% base), +200%
capacity with total +10 flat visits inside final min(absolute maximum, ×3 base).
Flat additions enter after percentage layers and cannot amplify their budgets.
Rate skills, flat activity quantities and fixed-water grants remain unsupported.

Sleeping Dew is adult placed Moonwillow's +4% combined-water skill, shared across
Standard/Golden copies and non-stacking. Publish behaviour v2 and new Woodland v3 /
Moonwillow v2 packs explicitly; old owned copies, unopened packs and receipts keep
their original profiles. Named-account development grant is repeat-safe, preserves
identity, awards an adult into storage and does not increment earned maturity.

Native support adds a confirmed/cached Active skills disclosure inside the fixed
garden status panel, source/duplicate explanations, effective water headline,
growth cap notice, owned/catalogue skill descriptions and confirmed recap bonus.
An HTTP-generated synthetic fixture supplies native decoding/cache tests.
See [backend/SKILLS_API.md](backend/SKILLS_API.md) for upgrade/provisioning and
[frontend/B8_SKILLS_ACCEPTANCE.md](frontend/B8_SKILLS_ACCEPTANCE.md) for device flow.
Executed checks and actual personal provisioning status belong in VALIDATION.md;
source or Windows parsing does not imply Xcode/Release/iPhone execution.

## B8 wider activity and launch balance increment — 25 October 2026

The subsequent scheduled-visitor rescale is implemented in
[VISITOR_RESCALE.md](backend/VISITOR_RESCALE.md): ×10 base arrival/offline rates,
1,200/2,400-token offers, 1,500/4,500 capacity, scaled finite milestone rewards,
audited once-only balance/stored-return conversion and batched server-authorized
arrivals. Legacy rules/receipts remain valid. Apple-platform and physical-device
acceptance is recorded separately from portable validation.

Source implements independent daily distance/active-energy/flights tracking and
rewards, typed workout uploads, manual-entry exclusion, replay/overlap handling,
paused/multisport intervals and account-midnight attribution. Explicit optional
upload consent preserves legacy journals and step-only availability. Migration
`0007_activity_launch` adds quantity/interval/identity records and milestone claims.
`launch-balance-v1` publishes nonfixture Oak/Moonwillow profiles, rarity/footprint
targets, the revised attraction curve, 120/240-token packs and finite introductory
milestones. `b8-caps-v2` uses +100% per growth layer (×4 maximum); old profile,
pack, policy and settlement versions remain intact. See
[LAUNCH_ACTIVITY.md](backend/LAUNCH_ACTIVITY.md) for constants and upgrade steps,
and [B8_ACTIVITY_ACCEPTANCE.md](frontend/B8_ACTIVITY_ACCEPTANCE.md) for device flow.
Production configuration publication is available independently of development
seeds. Portable validation does not establish Mac/iPhone acceptance.

Remaining scope after this increment:

1. Personal activity baseline boosts are explicitly deferred until after launch.
   No personal lookback/boost storage or bonus bands are introduced. Anti-backfill
   enrolment baselines remain required and are distinct from this optional system.
2. Permanent pack unlocks are deferred; both launch offers are available. The
   implemented five one-time milestones provide the small introductory track.
3. Wider Apple SDK/XCTest/Release and physical-device acceptance remain separate
   checks with actual results recorded in validation guides.
4. Assign further visitor skills only after balancing. Implemented attraction /
   capacity handlers are tested with synthetic profiles; weather, offline-rate
   skills, stateful/one-use mechanics and complex synergies remain deferred.

## F8 presentation and collection polish — incremental

### F8.1 lifecycle and butterfly-loading follow-up — done, user accepted on iPhone, 26 October 2026

**Closure:** the user accepts these tickets as done after physical-iPhone
play-testing. The first-return recap now behaves as expected; manual sync stays
quiet. Cold-start butterfly artwork now loads without getting stuck and without
manual artwork retry. This closes the priority follow-up and unblocks F8.2.
The previously accepted Packs routing and Garden recap destination also remain
done. This is user-reported functional acceptance, not an unrecorded XCTest,
Release-build or Instruments result, nor proof of a particular memory-leak cause.

| Ticket | Status / acceptance evidence |
| --- | --- |
| Resume lifecycle / accumulating return work | Done — included in the user's closure of the lifecycle follow-up; sustained resource profiling remains a separate F8 hardening gate |
| Delayed first-return recap / quiet manual sync | Done — user confirmed expected recap behavior and no manual-sync recap |
| Butterfly placeholder / cold-start loading and recovery | Done — user confirmed loading works, no stuck state and no manual artwork retry needed |

**Final loading/recovery correction — `4d151a1`:** butterfly import retains an
explicit cancellable Combine subscription, handles empty completion and bounds
import time to ten seconds; failure releases the shared load so retry starts
fresh. Renderer/controller binding follows the current visitor session, and a
successful visitor reconciliation clears the stale network-timeout message while
preserving the original pending request UUID/body. Four targeted native regression
cases were added. The bundled asset does not depend on a backend download.
Portable validation and Swift syntax checks passed; native automated execution
remains unrecorded. The user subsequently accepted the resulting device behavior.

The following investigation and delivery notes retain the history of the closed
tickets. Unexecuted broader accessibility and performance checks remain in
`frontend/F8_ACCEPTANCE.md`; they do not reopen these accepted functional fixes.

**Source follow-up delivered, 26 October 2026:** one foreground resume owner;
cancellation-responsive UI waiters around a shared durable sync; immediate
loading recap without a post-sync Health read or historical identity pagination;
an agreed 30-second continuous-clock absence threshold; no Garden activation or
inactive/active sync trigger; compatible Health-read coalescing and structured
Health query children; persistent butterfly template clones; weak editor
callbacks; renderer detachment and terminal session disposal; paused hidden
visitor timelines; and Debug lifecycle/asset timing logs. Existing blocking flows
consume the automatic entry without acknowledging unseen receipts. Interrupted
mutations keep their original journals/UUIDs. Thirteen native regression cases
were added and two existing recap cases updated. At that delivery point, device
acceptance was still pending; source checks did not establish a memory-leak
diagnosis. See `frontend/F8_ACCEPTANCE.md` and
`frontend/VALIDATION.md` for the exact test flow and executed checks.

**Intermediate play-test follow-up — corrected in `03abe14`, now user accepted:** the first
return still deferred the recap until a later Notification Centre interaction,
and some old butterfly overlays remained. Root eligibility still reread an
environment phase from within a transition callback. It now uses the event value
to update one published foreground state before testing eligibility; startup
cannot replay a stale phase after a newer event. Butterfly loading now prewarms
at app-container startup and attaches cached clones synchronously. The overlay
directly observes renderer readiness and resolves projection/readiness before
layout. Normal import uses a loading indicator rather than the old butterfly;
the accessible Welcome action remains available. Actual asset failure retains
the explicit fallback/retry path. Four targeted native regression cases were
added. Device acceptance was reported subsequently, as recorded above.

**Original report on iPhone 14 Pro:** lag accumulates after repeated Home/app switches
and Notification Centre interactions. The recap can arrive about 10 seconds after
return, or around 30 seconds into the reported lag episode. The old butterfly
fallback appears before the rendered model becomes available. Restarting clears
the accumulated lag but does not resolve the delayed recap. Treat delayed entry
presentation and cumulative performance degradation as potentially separate issues.

**Pre-fix source findings and uncertainty:** any genuine background transition
rearmed the recap without an absence threshold. Transient inactive/active changes
also started refresh work, although inactivity alone should not rearm the recap.
The root, garden and recap have multiple reconciliation entry points; concurrent
syncs are coalesced, but surrounding resume tasks are not cancelled on another
exit. One presentation path awaits sync and another Health read, while an immediate
path also exists. There is no deliberate ten-second popup delay. The old butterfly
is an explicit asset-not-ready fallback; ordinary backgrounding does not reset
renderer readiness. Renderer replacement/loading and incomplete teardown are
investigation targets, not a confirmed memory leak or proven cause of the lag.

**Original fix and diagnostic scope:**

- **Measure the actual sequence:** add development diagnostics for scene-phase
  transitions, entry eligibility/presentation, resume/sync/Health-read timings,
  renderer creation/destruction and butterfly-load counts/durations. Capture
  memory and frame-time behaviour on the affected iPhone across repeated switches.
  Correlate late presentation with those events before assigning a root cause;
  avoid logging credentials or raw Health records.
- **Own resume work in one place:** use one cancellable, generation-scoped resume
  operation, coalesce redundant reconciliation/Health reads and prevent old return
  tasks from presenting a recap during later play. Notification/Control Centre
  interruptions must not create a new entry or accumulate duplicate work. Preserve
  durable upload/reward requests and their recovery independently of UI cancellation.
- **Present eligible recaps promptly:** for an authenticated, ready connection,
  present over Garden immediately with a loading state while reconciliation runs.
  Keep cold-login/account verification requirements intact. Add a short-absence
  grace period so brief app switches do not repeatedly show the recap; select and
  record its duration before implementation rather than silently choosing it.
  Ordinary sync must never reopen the sheet, and unseen receipts remain pending.
- **Preserve and release rendering resources correctly:** retain the loaded
  butterfly template and garden renderer across ordinary pauses where appropriate.
  Investigate why the fallback reappears on return. Explicitly release callbacks,
  subscriptions, tasks and animation resources when a renderer is actually replaced;
  verify released instances do not accumulate. Preserve camera state, visitor
  identity/expiry, modal eligibility and single-award accounting.

**Regression reference / broader F8 performance gate:** compare a fresh uninterrupted session with a session of at least
10 minutes containing repeated Home/app switches, Notification/Control Centre
interruptions, rapid leave/return cycles and recap dismissal while loading. Cover
returns below/above the selected absence threshold, slow/offline reconciliation
and account changes. Eligible recaps appear promptly over Garden with loading
feedback rather than surprising the player later; brief/transient interruptions
and routine sync stay quiet. An already loaded butterfly does not unnecessarily
revert to the old fallback. Frame time and memory remain stable across cycles,
retired renderer instances are released, and no progress or rewards are duplicated
or lost. Record iPhone traces and targeted regression results separately from CI.
Functional closure above is based on user play-testing, not portable syntax
checks. A sustained Instruments trace remains unrecorded and is not a prerequisite
to the bounded F8.2 presentation batch.

### F8.1 first-release presentation — source implemented, 26 October 2026

**Completed follow-up — user-confirmed on iPhone, 26 October 2026:** commit
`dc392fd` separates the Packs page's contents/odds inspection from its Open pack
action and presents the entry activity recap automatically over Garden without
requiring a visit to Activity. The user confirmed these fixes work and accepted
them as done. Routine sync remains excluded from entry presentation. This targeted
acceptance does not establish the outstanding automated, accessibility or
minimum-device measurements below.

Scope: portrait-only play with a consistent light appearance; no Dark Mode or
landscape support in this batch. App entry presents a dismissible, scrollable
per-copy activity update after authentication, including saved water, skill
contribution, stage changes and current progress. Fresh launches and genuine
background returns of at least 30 seconds rearm it; routine/manual/observer syncs and transient inactive
states do not. Empty returns show a quiet status. A frozen receipt set is
acknowledged durably on dismissal, including while another sync is running;
dismissing a loading sheet cannot cause a later sync to reopen it.

Exchange separates inspection, explicit confirmation and inline pending/result/
recovery feedback. Packs replaces the player-facing Draws label. Pack opening
uses confirmation, the bundled Woodland image layers, two deliberate taps,
receipt-rarity light, the saved sprout and Continue. Other themes use an explicit
generic wrapper. Interrupted openings retain their saved result/history without
automatically replaying the ceremony. Images are downsampled to at most 900 pixels
on the long edge. The three delivered aligned PNGs total 3,911,092 bytes and
would occupy approximately 18 MiB as full-resolution RGBA images, superseding
the older unmeasured resource estimates below.

The bundled butterfly USDZ uses shared template clones and its embedded wing
animation, board-relative paths and camera projection for 64-point touch targets.
The separate accessible Welcome action remains available. Motion follows the
existing server-issued opportunity identity/time, expiry and modal eligibility.
Storage is directly accessible from Garden; placing enters the existing editor.
Progress, metric labels, Health upload copy and screen-reader focus are refined.

Portable assets/project/contracts and all 56 Swift syntax parses pass. The full
PostgreSQL suite passes 454 tests and all four real HTTP walkthroughs pass.
Ten native regression cases were added; Xcode/Apple SDK compilation, XCTest/UI,
Release build, broader visual acceptance and physical minimum-device measurements
remain unrecorded here beyond the targeted iPhone acceptance above.
Follow [frontend/F8_ACCEPTANCE.md](frontend/F8_ACCEPTANCE.md). This closes
the source scope only, not all of F8 or deployment readiness. Catalogue discovery,
the economy increment below, remote asset delivery, watering/swarm and elaborate
effects remain separate increments.

### F8.2 focused presentation refinements — completed, user accepted 27 October 2026

**Live-test acceptance:** the user confirmed that butterfly tapping is much more
seamless, the icon draft looks good, pack lighting is fixed and Milestones works
as expected, and explicitly accepted F8.2 as complete. Commit `cedba46` was pushed
to GitHub `main`. This closes the bounded F8.2 polish batch and releases the F8.3
planning gate. It does not claim unrecorded XCTest/UI, Release, accessibility or
performance checks passed, or establish the current CI result.

**Bounded batch:** the F8.1 lifecycle/loading tickets are closed above.
These four work items define F8.2; source implementation is complete. Preserve
portrait-only play, the light appearance, accepted recap/loading behavior and the
two deliberate pack taps. This batch uses existing assets, APIs and reward rules;
it does not change backend schema, balance, prices, milestone rewards or Health
collection/consent. If investigation reveals a missing backend requirement,
record it separately rather than expanding this presentation batch silently.

#### F8.2a — pack lighting from the torn opening

- Replace the broad glow behind the wrapper with light anchored inside the torn
  opening. Layer/mask it behind the opaque front of the opened wrapper; allow a
  restrained upward spill from the rim. On the second tap, transition to the
  matching halo behind the revealed sprout. Use the existing three Woodland PNGs
  and an equivalent restrained treatment for the generic wrapper.
- Keep rarity hidden while sealed. Once opened, derive light and text from the
  confirmed receipt: Common grey, Rare blue, Epic purple, Legendary gold. Variant
  names/art must not override rarity, including Common Golden Moonwillow.
- Preserve confirmation, first tap to tear, indefinite wait for the second tap,
  second tap to reveal and Continue. Keep Reduce Motion, accessible actions,
  downsampling limits and saved-result recovery; no new particles, 3D wrapper,
  asset generation, automatic reveal or reward requests.
- **Primary surface:** `frontend/MovementForest/Features/PackOpeningScreen.swift`.
  Extend existing pack fixtures/UI checks rather than introducing a second reveal
  state machine.
- **Done when:** all four receipt rarities visibly emit from the opening without
  shining through the opaque wrapper, then produce the matching sprout halo;
  both taps and the pause between them work with/without Reduce Motion. Generic
  packs remain usable, and background/relaunch recovers exactly one saved sprout.

#### F8.2b — reliable butterfly taps, including near the header

- Reproduce missed taps near the menu/header and identify the actual cause:
  compare the AR view projection with the overlay's coordinate space and viewport
  insets, then check clipping, flight bounds, camera movement and overlapping
  controls. Existing targets are 64 points; do not assume target size alone is
  the fault or compensate by moving only an invisible hit target.
- Keep the target aligned with the visible butterfly through orbit/pan/zoom and
  supported portrait sizes. Reserve the header/menu's interaction area. If flight
  must be lower or constrained, adjust the world-space path and projection
  together; enlarge targets only where this does not intercept adjacent controls.
  Fully offscreen/ineligible visitors must not leave active invisible buttons.
- Preserve garden-relative depth, opportunity identity/time/expiry, camera state,
  independent selection where multiple visitors are supported, the accessible
  Welcome action, modal/editing eligibility and single-award accounting. Do not
  change import ownership, resume work or backend visitor scheduling.
- **Primary surfaces:** `Features/Garden/VisitorViews.swift` (including
  `VisitorWorldPose`), `Rendering/GardenRenderer.swift` and
  `Features/Garden/GardenViewportLayout.swift`, under `frontend/MovementForest`.
  Confirm the actual layout owner before editing; no header redesign is included.
- **Done when:** direct taps at the visible centre and edges of a butterfly work
  near the upper boundary and at normal/minimum/maximum camera zoom, without
  activating the menu or a different visitor. Test after camera gestures, sync,
  sheet dismissal and background return. Rapid repeated taps grant one reward;
  menu taps, garden gestures and VoiceOver Welcome remain usable.

#### F8.2c — dedicated Milestones sidebar page

- Add Milestones alongside Exchange, Packs and Catalog in the existing sidebar.
  Move the current introductory milestone list/claims out of Exchange; Exchange
  retains pack offers and purchase feedback. Navigating must preserve the mounted
  Garden/camera and use the existing collection coordinator/account session.
- Show each existing milestone's server title, requirement description and token
  reward, including before it is eligible and after it is claimed. Render explicit
  not-yet-eligible, ready-to-claim, confirming/recovering and claimed states, plus
  loading, empty and failed-refresh feedback. Keep cached data distinguishable
  from a freshly confirmed result.
- **Contract boundary:** `APIIntroMilestone` currently supplies `eligible` and
  `claimed`, not numeric progress counters. Use those authoritative states and
  requirement text; do not invent a percentage or infer counts from local Health
  totals. Numeric progress, lifetime-step rewards, recurring quests and events
  are separate work. Do not present nonfunctional quest/event tabs in this batch.
- Reuse the durable milestone claim operation and its original UUID/body on
  retry, existing mutation lock and confirmed wallet updates. Repeated taps,
  navigation and restart must not duplicate a reward. Token-only claims can
  offer a link to Exchange; do not imply that claiming awards or opens a pack.
- **Primary surfaces:** `Features/CollectionScreen.swift`, the existing sidebar
  in `App/MovementForestApp.swift`, and `Services/CollectionCoordinator.swift`
  under `frontend/MovementForest`, plus the existing collection tests in
  `frontend/MovementForestTests`. Change coordinator behavior only if the new page
  exposes a concrete gap in existing feedback or recovery.
- **Done when:** all existing milestones are reachable on the new page and absent
  from Exchange; locked/ready/claimed states match server data; a claim updates
  the wallet once. Verify offline refresh, interrupted claim/retry, relaunch and
  account switch. Existing Exchange/Packs/Catalog routes continue to work.

#### F8.2d — consistent token and activity icons

- Define shared icon/label components or mappings for visitor tokens, steps,
  walking/running distance, active energy, flights climbed, supported workout
  types and the default workout rule. Unknown workout types need a readable
  generic fallback. Use the supplied `quantity-icons-v1/png-128` exports, with
  system symbols for workout types without supplied art; originals are not bundled.
- Apply the activity mapping to owned plant details, Catalog growth explanations
  and existing Activity metric rows. Apply the same token icon to existing wallet,
  visitor-token, Exchange, Milestones and receipt labels where tokens are shown.
  Do not confuse spendable tokens with stored visits or visitor capacity.
- Keep text labels, units, values and per-species/per-copy multipliers. An icon
  must not imply growth for an unsupported input, obscure an unavailable metric,
  or replace the distinction between a default workout rule and a specific type.
  Decorative icons should not duplicate spoken labels in VoiceOver.
- **Primary surfaces:** `Features/SharedViews.swift`, plant detail and Activity
  views, `Features/CollectionScreen.swift` and `Features/Garden/VisitorViews.swift`
  under `frontend/MovementForest`. No metric calculations, growth rules or Health
  ingestion changes.
- **Done when:** the same metric/token has a consistent icon across those screens;
  labels and multipliers remain correct for differing species, zero/unavailable
  inputs and unknown workouts. Largest accessibility text stays readable and
  scrollable; VoiceOver announces meaningful labels/values without icon noise.

**Implementation order:** fix butterfly hit geometry first, then pack lighting,
then the Milestones route, then apply the shared icons across the final screens.
Keep these as reviewable changes and run the combined regression flow afterwards.

**Implementation notes:** model taps now use the ARView's existing tap recognizer
and projected visual bounds at tap time, clipped to the scene viewport. SwiftUI
fallback buttons remain available; model overlay buttons no longer intercept camera
gestures. Loading/readiness observation, import ownership/cache, timeout recovery,
flight motion and renderer/app-resume sequencing are unchanged. Pack light uses an
aperture mask traced to the supplied opened PNG and transitions into the sprout
halo within the existing reveal state machine. Milestones is a sidebar destination
using the shared collection coordinator, original durable claim bytes, explicit
freshness/retry feedback and confirmed claim guards. Shared icons retain labels,
units and pinned per-copy multipliers. No backend or economy changes were made.

Portable project/asset/contracts and all 59 Swift syntax parses pass locally.
Native regression coverage was extended for boundary/overlapping targets, camera
projection and one welcome, milestone refresh/claim recovery, icon resolution,
Milestones navigation and both taps for all four rarities with/without Reduce
Motion. These native tests and Apple SDK builds were not executed on Windows.
The subsequent user live-test acceptance above is separate evidence. The original
local handoff preceded the push of `cedba46`; CI results have not been recorded
here. See `frontend/F8_ACCEPTANCE.md`.

**Validation and handoff:** run portable frontend project/asset/contract checks,
Swift parsing and whitespace checks. On Mac, run
`bash frontend/scripts/test-mac.sh` for Debug XCTest/UI and the Release build.
Extend the existing native projection/visitor, collection and pack UI coverage
only for changed behavior, including boundary taps, route/claim recovery and
the two-tap rarity cases. Physical-iPhone acceptance covers the visible lighting,
actual tap registration, milestone states/one reward and accessible icons.
Regression-check first-return recap after 30 seconds, quiet manual/Notification
Centre refresh and cold-start butterfly loading. Record executed checks separately
from user play-test results; no unexecuted Apple check is a pass.

**Outside F8.2:** the compact header, bottom navigation, read-only Storage/Edit
Garden redesign and developer-output cleanup remain F8.3. New milestone rewards,
lifetime steps and collection pacing retain their separate economy scope below.
No catalogue stage-discovery system, watering/swarm effects, remote assets or
deployment work is included.

### F8.3 first-version frontend presentation — completed, user accepted 27 October 2026

**Handoff / status:** completed and user-accepted. Commit `219381b` was pushed to
GitHub `main`; the user subsequently confirmed live testing works as planned and
closed this batch. Portable validation is recorded in `frontend/VALIDATION.md`;
no additional XCTest, Release-build or CI result is inferred from that acceptance.
The delivered scope below superseded the earlier three-tab Garden/Activity/Storage
proposal and immediate-placement inventory picker. Preserve the accepted behavior
as the baseline for F8.3b.

The completed work packages below retain their original scope and acceptance
criteria; pre-implementation descriptions are historical. Their former a–f
sublabels are now numbered so **F8.3b** uniquely identifies the new follow-up batch.

**Goal:** deliver a clean, coherent, usable first version of the entire frontend
using its current native visual style, fonts, shared icons and existing artwork.
Normal pages must be free of additional developer/debug output. Preserve useful
technical information in Developer tools. This is the functional presentation
baseline before later custom page designs, backgrounds or new visual assets.
Preserve portrait-only play, light appearance, APIs, economy, ownership and Health
collection/consent rules. No new gameplay, reward rules or asset-delivery system.

#### Completed F8.3 work package 1 — bottom navigation and shared scene ownership

- Bottom menu, in this order: **My plants, Garden, Edit, Activity**. My plants,
  Garden and Activity are browsing destinations; Edit explicitly enters focused
  Garden editing mode, not another Garden/renderer instance. No standalone Storage
  tab. Storage remains the stored-copy section and the inventory entry in editing.
- Keep Exchange, Packs, Catalog and Milestones in the existing sidebar outside
  editing, with Settings reachable. Do not add placeholder Friends/quest/event
  destinations. Initial and accepted entry-recap presentation remains over Garden.
- Preserve one mounted Garden, camera state, account-bound editor/inventory,
  activity and collection coordinators. Switching destinations must not reimport
  models, reset the scene or create visitor sessions as a navigation side effect.
- Keep normal Garden selection and its Plant details action. All browsing and
  details routes outside editing are read-only. Preserve valid copy selection;
  clear stale selection after a confirmed removal or account switch.
- **Primary surfaces:** `App/MovementForestApp.swift`,
  `Features/Garden/ConnectedGardenScreen.swift`, `Features/Garden/GardenScreen.swift`
  and navigation/editor tests under `frontend/MovementForest`.
- **Done when:** all four menu entries and sidebar destinations work, share the
  same account state, and preserve the mounted Garden/camera without browse edits.

#### Completed F8.3 work package 2 — My plants: all owned copies, read-only

- Provide one scrollable overview with clearly labelled **Planted** at the top
  and **Stored** below. Combine confirmed placed copies and paginated stored
  inventory; this is an owned-copy view, separate from the species Catalog.
- Each row opens that exact copy's plant details: thumbnail, species/variant,
  stage, confirmed growth/progress, available pinned per-copy multipliers and
  garden-skill state. Keep duplicates separate by copy identity. Do not invent
  missing fields, totals or progress from a partially loaded inventory.
- My plants and its details have no Place, Move, Rotate or Store actions and do
  not enable editing. There is no automatic switch to placement from browsing.
- Provide loading, genuinely empty, cached/offline, refresh failure, retry and
  load-more states. Browsing and pagination must not depend on mutation readiness;
  `GardenEditorStore.loadMore()` is currently gated by `canEdit` and needs a narrow
  read/mutation separation. Keep account attachment, cursor/generation and stale
  response protection; do not bypass them when making reads independent.
- Share existing inventory state with editing. Preserve loaded pages where valid;
  respect refresh/cursor invalidation after mutations/account changes. Confirmed
  Place/Store updates must move the same copy between sections without duplication
  or loss of growth/profiles. No second ownership source or new inventory cache.
- Disconnected/sample sessions show clear, truthful explanatory states and cannot
  expose another account's copies or mutate sample ownership.
- **Primary surfaces:** a My plants view under `Features`, existing plant details,
  `Services/GardenEditorStore.swift`, `MovementForestApp.swift` and inventory tests.
- **Done when:** both sections and per-copy details work through pagination,
  offline viewing and account switches; browsing issues zero garden mutations.

#### Completed F8.3 work package 3 — focused Edit mode and details-first placement

- Enter from the bottom **Edit** action. While editing, hide the ordinary bottom
  menu and sidebar entry points. Keep the scene, an obvious mode indication,
  **Storage**, necessary contextual editing controls and a top **Done/tick** with
  an accessible "Done editing" label. Retain necessary loading/recovery feedback
  and accessible alternatives to camera/precise placement gestures.
- Stored-copy flow: **Edit → Storage → select copy → plant details → Place →
  placement preview → confirm**. Selecting a row must not start placement. Details
  show a bottom Place action only in this edit context, enabled by the existing
  mutation-safety rules. Returning from details without Place makes no preview
  or request. Cancel during placement leaves the copy stored.
- Selecting a planted copy offers **Move, Rotate, Store, Plant details**. Details
  remain inspection only; Move/Rotate/Store preserve their current behavior and
  clearance rules. Retain useful precise controls, placement validity and adult
  preview; remove unrelated navigation/buttons rather than editing functionality.
- Reuse shared detail content with explicit read-only/edit context. Do not duplicate
  plant data or infer edit permission from the fact that a details screen is open.
- Done cancels an unsubmitted preview and exits to Garden browsing. It does not
  undo confirmed edits, and is not an implicit batch-save action. Backgrounding
  cancels unsubmitted previews and returns to browsing on resume. Preserve original
  UUID/body and journal for any submitted/in-flight/unknown edit; exit must not
  discard, recreate or resubmit it. Pending recovery stays visible/reachable and
  blocks unsafe mutations. Account changes retain existing isolation.
- Pause visitors during editing and inventory/details modals using the existing
  eligibility rules. Preserve accepted entry-recap blocking and resume semantics.
- **Primary surfaces:** `ConnectedGardenScreen.swift`, shared plant details,
  `GardenEditorStore.swift`, app navigation and editor recovery tests. Make only
  demonstrated mode/read-safety changes; do not add another save state machine.
- **Done when:** every stored-copy route shows details before Place; planted-copy
  actions include details; Done and interruptions safely preserve confirmed edits,
  the camera and exactly one original pending operation.

#### Completed F8.3 work package 4 — compact Garden and secondary game information

- Replace expanded routine status text with **visitor tokens, attraction, stored
  visits/capacity**, using F8.2 icons and readable labels. Distinguish spendable
  tokens from uncollected visits; missing values must not appear as zero.
- Keep **Collect stored visits** and accessible **Welcome visitor** reachable,
  with concise pending/result/retry feedback and single rewards. Put detailed
  rates/capacity explanations, hosted totals and active skills in labelled secondary
  game-information views. They are useful gameplay information, not developer logs.
  Keep activity history, sync controls and Health permissions in Activity/Settings.
- Give the scene space recovered from routine text. Scene bounds may adapt to
  viewport/safe area/text size but must stay stable through transient status
  messages. Reflow large text without overlapping header or scene touch areas.
  Preserve selected-copy inspection and necessary accessible camera controls.
- **Protected behavior:** retain F8.2 ARView-local hit testing and visual-bound
  alignment, readiness observation outside `GeometryReader`, preload/shared cache,
  timeout/retry, embedded animation and renderer/resume ownership. Do not alter
  flight clocks/scheduling or compensate for a new header with displaced invisible
  targets. Limit renderer changes to a demonstrated viewport/projection defect.
- **Primary surfaces:** `Features/Garden/GardenViewportLayout.swift`,
  `ConnectedGardenScreen.swift`, `VisitorViews.swift`, `Features/SharedViews.swift`
  and existing Activity/skills information surfaces.
- **Done when:** Garden has a compact, understandable summary and clear primary
  actions; taps still align at the new boundaries through orbit, pan and zoom.

#### Completed F8.3 work package 5 — frontend-wide developer-output cleanup and retained diagnostics

- Audit every player-facing page and reachable secondary view: Garden, My plants,
  copy details, editing, Activity/Health views, Exchange, Packs/results/history,
  Catalog, Milestones, Settings/account and recap/loading/error/empty states.
  Remove technical/debug-only output from these normal routes. No raw request IDs,
  payloads, internal asset/profile/version diagnostics, balance-verification output,
  verbose lifecycle/sync traces or developer baseline text should remain there.
- Move that information into **Settings → Developer tools → Diagnostics**. The
  current Developer tools has inspectors and Health diagnostics, not a unified
  event-log viewer. Add the viewer before removing existing useful visibility.
  Provide timestamped/filterable events, request IDs and operation/retry outcomes,
  live Garden renderer/asset state, activity/baseline diagnostics and collection/
  wallet confirmation/recovery state. Inspect the real session, not only sample
  scenes. Retain existing asset/scene/Health inspectors and system logging.
- Provide manual Copy/export and a bounded recent history, including enough
  previous-session events to investigate relaunches; do not keep unbounded logs.
  Never log credentials/tokens or unnecessary personal Health payloads. Keep detailed
  Health inspection local/explicit. Backend logs remain backend-side and correlate
  through request IDs; no automatic upload or remote log-streaming service.
- Current access is `#if DEBUG` only. Keep Developer tools readily available in
  development and explicitly enabled internal Release/TestFlight builds, so device
  testing does not lose diagnostics in Release configuration. Detailed tools are
  excluded/disabled for public production builds; do not rely on hidden gestures
  or an undocumented route for internal testers.
- Keep concise player-facing loading, offline/cached, permission, pending,
  confirmed and failure states with useful Retry/Reconnect actions. No recovery
  path may require Developer tools. Preserve meaningful sample/provisional labels
  where removing them would misrepresent data. Game explanations belong in normal
  secondary information views, not exclusively in diagnostics.
- **Primary surfaces:** all `Features` pages, `SettingsScreen.swift`,
  `Features/DeveloperTools`, `Features/HealthDiagnostics` and shared display views.
  Change service display/log separation only where needed; preserve instrumentation,
  durable operations and existing log emission/rendering sequencing.
- **Done when:** normal navigation is free of developer/debug clutter across all
  states, while useful events and live diagnostic state remain accessible during
  internal iPhone testing, including an internal Release configuration.

#### Completed F8.3 work package 6 — consistent first-version presentation and copy

- Review the complete frontend for consistent native typography, spacing, section
  hierarchy, readable labels/units, shared icons and accessible touch targets.
  Keep clear empty/loading/error/pending/result states and scrollability with large
  text. Distinguish a missing metric from zero; preserve per-copy multipliers.
- Update instructions and accessibility copy for **My plants → Stored** browsing
  and **Edit → Storage → details → Place** placement. This includes pack-result,
  receipt, empty-Garden and Settings helper text. Navigation-copy corrections in
  `PackOpeningScreen.swift` are allowed; ceremony controls/recovery changes below
  are deferred. Do not remove Continue later in this increment.
- Preserve consent/account flows, meaningful gameplay information and all existing
  confirmation/retry actions. Reuse current assets and native visual language;
  no custom backgrounds, new art, ornamental effects or new page design system.
- **Done when:** ordinary app journeys look intentional and understandable as a
  first frontend version, with debugging accessible through Developer tools.

**Implementation order:** preserve diagnostics access/viewer first → navigation
and My plants → focused Edit/details-first placement → compact Garden/secondary
information → frontend-wide technical-output and presentation/copy pass. Perform
cleanup across all pages, not just the redesigned Garden. Keep changes reviewable.

**Validation and handoff:** run portable project/asset/contract checks, Swift
syntax parsing and whitespace checks. Extend native tests for four-entry navigation,
read-only combined ownership/pagination, contextual details/Place, edit exit and
pending recovery, account isolation and final-layout visitor targets. On Mac run
`bash frontend/scripts/test-mac.sh` for Debug XCTest/UI and Release build; also
verify internal Release diagnostics access and public-build gating. Device flow:
My plants (Planted/Stored) → inspect each without mutation → Garden → Edit (normal
navigation hidden) → Storage → details (no preview) → Place → cancel → Place and
confirm → select placed copy → Details/Move/Rotate/Store → Done → My plants.
Repeat with failed/lost responses, background/relaunch, cached inventory and account
switch. Verify no duplicate copy/reward/request, stable camera, normal-page cleanup
and useful diagnostic history/export. Check large text, VoiceOver, Reduce Motion,
upper-boundary butterfly taps through orbit/pan/zoom, accepted cold/warm artwork
loading, 30-second entry recap versus quiet routine/Notification Centre refresh,
existing two-tap lighting and Milestones claims. Record executed checks separately
from user acceptance. No unexecuted check is a pass; this plan update runs no app,
backend, native tests or CI.

**Outside F8.3:** workout-eligibility/anti-idle changes and pack-opening cleanup
below; backend/schema/API/economy changes; new species integration; numeric
milestone progress/early-collection/lifetime-step rewards; catalogue discovery;
My plants search/filter/sort/bulk operations; placement-rule changes; custom
backgrounds/new assets; asset hosting/cache migration; watering/swarm effects;
onboarding/auth redesign; Dark Mode/landscape; general renderer rewrites and
deployment. This polish does not itself establish production/release readiness;
existing provider, deployment and minimum-device evidence gates still apply.

### F8.3b — Garden viewport and layout refinement — source implemented, native acceptance pending

**Status / authority — 27 October 2026:** user-confirmed follow-up to completed
F8.3. Source implementation is complete locally, with portable project/asset/contract
validation, all-Swift syntax parsing and whitespace checks passing. Native XCTest,
Apple SDK builds and physical-device acceptance have not run on this Windows host.
No push or CI run was requested. The delivered scope supersedes the completed batch's permanent browsing Plants/controls strip,
separate visible Welcome button and routine Garden success-text presentation.
Other accepted navigation, editing, recovery and gameplay behavior remains the
baseline. The former F8.3b My plants subtask is preserved above as completed work
package 2; it is not reopened by this new batch identifier.

**Goal:** the Garden itself occupies most of the screen as one continuous scene
between the existing top navigation and bottom My plants / Garden / Edit / Activity
navigation. Remove the large opaque white browsing panels. Use the current assets,
native typography, icons and forest-green accent, with compact transparent overlays.
No new backgrounds, artwork or gameplay/economy work is required.

**Target browsing composition:**

```text
            Existing top navigation

 Tokens          Attraction          Stored visits
 [Garden info]                           [Collect]

                    Garden scene
                Orbit / Pan / Pinch

      +---------------------------------------+
      | Oak / Standard                      x |
      | Young plant             Plant details |
      +---------------------------------------+
             Only after selecting a plant

      My plants / Garden / Edit / Activity
```

#### Continuous scene and transparent overlays

- Replace the browsing layout's fixed top/bottom panel allocations with a scene
  filling the available space, plus compact overlays. The current portrait layout
  reserves up to 32% for status and 24% for controls even when little content is
  present; remove that permanent reservation rather than merely shrinking labels.
- Keep the existing top navigation controls, sidebar/Settings access and bottom
  navigation. Avoid duplicate titles, explanatory blocks or additional status rows
  in the routine Garden header.
- Selection, balance changes and temporary notices must not resize the ARView,
  reimport models, reset the camera or change its framing. Geometry may adapt to
  actual viewport/safe-area/text-size changes; do not force a camera reset to fit
  the new layout.
- The overlays use transparent fill and a thin forest-green outline where a box
  or button is specified. Preserve readable contrast over the scene; respect
  accessibility contrast/Reduce Transparency needs without restoring a permanent
  opaque browsing slab. Keep controls clear of device safe areas and navigation.
- Transparent container areas must not intercept scene gestures. Only real
  controls/popup content consume their own touch area. Navigation, header controls,
  selection and visitors must keep correct hit-test precedence at their boundaries.

#### Two-row Garden header

- At ordinary text sizes, show **visitor tokens, attraction, stored visits /
  capacity** together in one row, using existing icons, confirmed amounts and
  readable labels/units. Never substitute zero for unavailable or unconfirmed data.
- Directly below, place **Garden info** on the left and **Collect stored visits**
  on the right, aligned beneath the stored-visits value. Both use the transparent,
  green-outlined treatment; Collect greys out when no whole visits are available.
- Preserve existing request-safety gates. Disable repeated collection while a
  request is pending and provide a compact progress indication. The counter changes
  only through confirmed state; a tap must not optimistically award tokens.
- Remove routine visitor instructions and explanations from the header. Rates,
  time/capacity explanations, hosted totals and active skills stay in Garden info.
  Keep Activity history/sync and Health consent in their accepted destinations.
- Allow sensible reflow at accessibility text sizes rather than clipping three
  metrics into a single unreadable row. Maintain accessible labels and 44-point
  action targets while keeping ordinary-size presentation compact.

#### Selected-copy popup instead of the bottom browsing strip

- Remove the normal Garden **Plants** button, bottom Garden info button and
  permanent white controls panel. My plants remains the comprehensive read-only
  owned-copy overview, with Planted above Stored.
- Tapping a planted copy shows a small transparent, green-outlined popup immediately
  above the bottom navigation, over the scene. Show that exact copy's **plant name,
  variant, growth stage and Plant details** action. Do not show the popup permanently
  when no copy has been selected.
- Plant details opens the existing read-only owned-copy view. It does not enable
  editing, create a preview or send a mutation. Duplicate copies remain distinct;
  resolve the popup/details against current account-bound ownership by copy ID.
- Selecting another plant replaces the popup content. A close control or tap on
  empty ground dismisses it. Camera gestures outside the popup continue to work;
  showing, replacing or dismissing it must not move the camera or scene bounds.
- Clear stale popup content after confirmed removal or account changes. My plants
  browsing must not create a Garden placement preview or automatically open this
  popup as a side effect.
- Remove the permanent visible zoom-in, zoom-out and reset-perspective buttons
  from the browsing interface. Preserve orbit, pan and pinch, and expose camera
  accessibility actions without recreating a visible button strip.
- Keep focused Edit's accepted Storage, Done, Move/Rotate/Store/Plant details,
  precise positioning/rotation, validation and preview/cancellation behavior.
  Adapt shared layout only as necessary; this is not a redesign of editing.

#### Direct visitor interaction and accessibility

- Remove the standalone visible **Welcome visitor** button. Visitors are welcomed
  through the butterfly itself, with the same server-authoritative welcome request,
  expiry, repeat-tap safety and durable recovery as before.
- Make the butterfly itself an accessible element/action so VoiceOver activation
  invokes that same welcome operation. Do not replace the removed button with a
  displaced invisible SwiftUI touch target that interferes with orbit/pan/pinch.
- Preserve ARView-local visual-bound targeting, shared preload/cache, readiness
  observation outside GeometryReader, accepted loading/fallback/retry sequence,
  embedded animation, flight phase/clocks and eligibility/session behavior.
- Any renderer/UIView integration change must be narrowly justified by direct
  visitor accessibility or the new viewport/overlay bounds. No general renderer,
  scheduling, model-loading or visitor-accounting rewrite belongs in this batch.

#### Quiet routine feedback; retain recovery

- Stop presenting routine **Saved** and **Welcomed 1 / +1 visitor tokens** messages
  in the normal Garden. Keep operation outcomes/request IDs available through
  Developer tools and retain any meaningful history in its existing destination.
- Separate routine success from pending/failure/recovery presentation explicitly;
  do not hide messages using brittle string-prefix matching or clear shared service
  state that another screen or diagnostics needs.
- Preserve concise offline/cached, unavailable-data, uncertain-request and failure
  indications with useful Retry/Reconnect actions. Exceptional notices overlay the
  scene without reintroducing a permanent status panel or resizing the viewport.
  Never make internal tools the only route to recover a pending operation.
- Do not suppress required artwork-loading feedback or change the accepted recap
  presentation/dismissal/acknowledgement behavior while removing routine success text.
- **Later animation batch:** token shimmer, floating/direct +1 feedback, watering,
  growth-stage transitions and other reward effects. None is implemented in F8.3b;
  confirmed counter updates remain visible without a replacement reward animation.

#### Implementation sequence and likely files

1. Establish the continuous browsing scene and overlay geometry in
   `Features/Garden/GardenViewportLayout.swift`, preserving one mounted render session.
2. Build the compact two-row header and move Garden info in
   `ConnectedGardenScreen.swift` / `VisitorViews.swift`; retain collection gating.
3. Replace the browsing controls strip with the current-copy selection popup;
   retain read-only details and the accepted Edit flow. Update `GardenScreen.swift`
   to use a coherent sample layout without inventing player ownership/balances.
4. Remove visible Welcome and implement/verify direct visitor accessibility.
   Limit any `Rendering/GardenRenderer.swift` / GardenSceneView bridge changes to
   that accessibility or a demonstrated overlay/bounds defect.
5. Separate routine-success presentation from exceptional states, preserving
   service/journal behavior and diagnostics. Update relevant display models and
   shared views only where needed; keep API/endpoint/payload contracts unchanged.
6. Update affected native tests, current design notes and acceptance instructions;
   run portable checks, then Mac/native and device checks with actual results recorded.

#### Completion and validation

- Normal Garden has no permanent white top/bottom slabs, browsing Plants strip,
  visible zoom/reset buttons or standalone Welcome button. The scene occupies most
  of the available screen; top/bottom navigation remains usable.
- Metrics share one ordinary-size row; Garden info and correctly enabled/greyed
  Collect sit beneath it. Unknown/cached values remain truthful, and collection
  produces exactly one confirmed reward through interruption/retry.
- Plant selection shows the specified popup; changing/dismissing selection neither
  moves the camera nor changes scene bounds. Details open the correct duplicate
  copy, remain read-only and clear safely across removal/account switches.
- Butterfly centres/edges remain tappable through orbit, pan, zoom and the new
  overlay boundaries, including near the header/popup. Real controls keep their
  own touch areas; offscreen visitors do not leave active targets. Repeated taps
  award once; VoiceOver can activate the visitor itself without a visible Welcome.
- Routine success text stays quiet; pending failure/recovery, cached viewing and
  loading remain understandable. Diagnostics/history retain useful operation outcomes.
- Recheck My plants, focused Edit, sidebar/Settings, cold/warm artwork readiness,
  background/resume, 30-second entry recap versus quiet brief interruptions,
  pack ceremony/Milestones and camera retention across navigation. Cover small
  screens, largest text, VoiceOver, Reduce Motion and Reduce Transparency/contrast.
- Run project/assets/contracts validation, Swift syntax and whitespace checks;
  update native viewport/navigation/selection/accessibility tests. On Mac run
  `bash frontend/scripts/test-mac.sh`, followed by the updated iPhone walkthrough.
  Keep executed automated results separate from subsequent user acceptance.

**Outside F8.3b:** token/reward/watering/stage-transition animations; workout
eligibility/anti-idle work; pack-opening cleanup (including removing Continue
later); backend/schema/API/economy changes; new assets/backgrounds; cloud delivery;
My plants search/filter/bulk actions; placement-rule changes; auth/onboarding redesign;
Dark Mode/landscape and general renderer rewrites. F8.3b source is implemented;
Mac/native and user/device acceptance remain pending. See frontend/VALIDATION.md.

### Later polish — pack-opening interruption cleanup (deferred; not F8.3/F8.3b)

- Remove **Continue later** from the ceremony in a separate future increment.
  Preserve Cancel before opening confirmation, the two deliberate taps during an
  uninterrupted ceremony, receipt-derived lighting and final Continue.
- If interrupted after a confirmed server opening, treat presentation as complete:
  retain the saved plant/result/history and do not replay the ceremony on return.
  Plant ownership never depends on watching or dismissing the animation.
- If interrupted before confirmation, recover the original saved UUID/body. Show
  completion only after the receipt confirms the award; do not invent ownership or
  submit another opening. Retain useful confirmation/error/retry navigation.
- Validate interruption during confirmation, tear, opened wait, reveal and result;
  cover network loss, background, relaunch, account switch, repeated taps and
  Reduce Motion. Exactly one pack consumption and saved sprout; no replay.
- Primary surfaces: `PackOpeningScreen.swift`, collection coordinator/journal only
  if a concrete gap exists, fixtures and opening/recovery tests. This is deferred
  behavior work; F8.3 only updates navigation text on these surfaces.

### Later activity integrity — workout eligibility and idle sessions (deferred)

**Separate reward-validation work, not presentation polish.** Investigate sessions
left recording while inactive, preserving genuine workouts with limited sensor
coverage. Do not implement a universal "no steps/distance/energy means cheating"
rule, choose thresholds silently, or alter past rewards as part of F8.3.

- Retain existing manual-entry exclusion, bounds, pauses/segments, baseline windows,
  deduplication, overlap handling and daily caps. First document actual coverage
  and representative valid/idle samples for each supported workout type.
- Current `WorkoutUpload` has duration/type/source/segments but no per-workout
  steps, distance or energy evidence. Plan explicit HealthKit extraction, versioned
  upload/schema compatibility and backend-authoritative eligibility before use.
  Preserve pending journal bytes/retry identity across any protocol upgrade.
- Distinguish observed zero from unavailable/missing data; HealthKit read-access
  restrictions can resemble no samples. Apply type-specific evidence: distance
  cannot be mandatory for strength/yoga, nor steps for cycling/swimming. Do not
  use unrelated daily totals to validate a particular workout.
- Assess long idle tails/intervals as well as whole-session totals. A small initial
  effort or nonzero calorie estimate alone must not validate hours of duration.
  Determine supported evidence and practical limits before enforcement; additional
  permissions/sensors require explicit scope, not automatic collection expansion.
- Specify handling of unknown/late evidence, re-evaluation and previously imported
  immutable workout identities before making exclusion permanent. Keep explainable
  outcome/reason codes in Activity and detailed Developer tools diagnostics.
- Exclude only ineligible workout bonus credit; do not delete the person's Health
  record or remove independently valid daily steps/quantities. No retrospective
  clawbacks or changed reward rates without a separate explicit decision.
- Test genuine indoor/outdoor workouts by type, pauses, missing permissions/data,
  zero evidence, idle tails, partial/delayed samples, overlaps, replay, upgrades and
  account/device changes. These checks reduce obvious abuse, not prove exercise.

### Later visual design and asset delivery — separate decisions

- **Visual design:** after F8.3's clean first-version baseline, apply any supplied
  page designs, custom backgrounds, new visual assets or optional effects as their
  own scoped work. Preserve the functional navigation/editing and diagnostic
  boundaries established here; no invented final visual direction in F8.3.
- **Asset delivery remains undecided:** the user will choose bundled, remote or
  hybrid delivery later. Core icons, butterfly and pack art can remain bundled
  with downloadable/cached plant packages, but this is a recommendation, not an
  approved migration. Current runtime source measurements: all nine local species
  models/thumbnails total about 57.09 MiB; the currently bundled Oak/Moonwillow
  art totals 11.29 MiB; core icons/butterfly/pack art totals about 11.54 MiB.
  Extrapolating 75 similar species gives about 487 MiB of artwork. The discussed
  roughly 600 MiB installed-app budget is provisional; code/library size, archived
  Release download/install sizes and memory remain unmeasured. Copies reuse art;
  this estimate is for species with the current stage/variant mix.
- If remote delivery is selected, scope trusted immutable/versioned manifests,
  checksums, local download cache, prefetch/eviction, offline/retry behavior and
  CDN publication/cost separately. Hand verified local files to existing rendering;
  do not introduce a network dependency into the accepted butterfly sequence.
- New species publication, catalogue stage discovery, early-collection/lifetime-
  step rewards, provider/deployment work and performance measurements retain their
  separate plan sections and acceptance gates; none is approved by this polish.

### Early collection pacing and lifetime step rewards — planned, 26 October 2026

Add this gameplay/economy follow-up to F8 alongside presentation polish. This is
a plan only: the current runtime rewards, prices, visitor rates and database stay
unchanged until this increment is implemented and validated. It requires backend
reward accounting as well as frontend milestone presentation.

**Problem and target:** at attraction 2–10, current offline income is 31–35 tokens
per hour, so a 1,200-token Woodland pack takes approximately 38h 43m–34h 17m from
zero without milestones. The existing first-movement/first-hosted/three-hosted
rewards already total 1,200 tokens; make that opening funding clear. Improve the
next acquisition steps so players can populate a garden with about 3–4 plants
early, while retaining the longer-term pack prices and attraction curve. Reward
finite introductory achievements rather than increasing recurring income again.

**Proposed introductory track:** direct rewards are owned unopened Woodland
packs, opened through the existing server-authoritative draw flow. Each pack
awards one sprout under its pinned pool; duplicate species/variants remain valid.

| Achievement | Proposed reward | Change from current rescaled track |
| --- | --- | --- |
| Starting garden | Existing starter Oak | Unchanged; never grant a second starter |
| First eligible movement | 1 Woodland pack | Replaces 300 tokens |
| First hosted visitor | 300 tokens | Unchanged |
| Three hosted visitors total | 1 Woodland pack | Replaces 600 tokens |
| First seedling earned through activity | 1 Woodland pack | Replaces 300 tokens |
| First adult earned through activity | 900 tokens | Unchanged |

This proposal gives the starter plus two reward plants in the opening session,
with another pack tied to growth. Its introductory reward value is 4,800 tokens
(three Woodland packs plus 1,200 tokens), versus 2,400 currently. Players must
still claim/open rewards and place sprouts; do not promise automatic placement.

**Lifetime step track — provisional reward targets:** add separate, once-only
account milestones at **3,000**, **10,000** and **50,000** cumulative eligible
steps, provisionally awarding **one Woodland pack each**. These are direct pack
grants, not permanent access unlocks, and are additional to the introductory
track. Use the existing authoritative lifetime credited-step counter after
confirming its semantics; count eligible steps once per account, independent of
plant count, species coefficients, boosts and whether a plant is already mature.
Do not count workout minutes as steps or import pre-enrolment Health history.
Re-enrolment, device replacement, repeated syncs and downward corrections must
not manufacture progress or repeat a reward. Personal activity baseline boosts
remain deferred; no new personal lookback history is needed for this track.

**Combined pacing review:** the 3,000-step pack can provide the fourth plant
before the seedling reward; these are overlapping achievements, not a promise
of exactly four plants or a cap. Before publishing final rewards, simulate both
tracks together for low/high daily steps, workout-only users, active/offline
play, duplicates and growing attraction. Check that the opening is generous
without exhausting the two-species test collection immediately. Keep step
milestones supplemental: workout users retain the introductory movement/growth
route. Later thresholds/rewards beyond 50,000 steps require a separate decision.

**Implementation and acceptance:** show threshold, authoritative progress,
reward type and claim status clearly, with a route to Draws after a pack claim.
Grant packs atomically with durable milestone receipts and stable account-scoped
claim IDs; no token deduction or activity-sync token minting. Pin the applicable
pack pool/version when awarding. Existing accounts should use already credited
steps and may claim newly introduced thresholds once. Preserve all historical
claims/receipts; decide an explicit compensation policy before changing rewards
for already-claimed introductory milestones, without silently resetting them.
Test exact thresholds, crossing multiple thresholds in one sync, capped growth
and mature plants, claim races, rollback, replay, interrupted pack opening,
account switching and upgrade compatibility. Record backend and native results
when implemented; this documentation update does not establish those tests.

### Visitor and collection presentation

**Historical presentation brief:** the butterfly asset/depth, Exchange feedback
and two-tap lighting items below were subsequently delivered in F8.1/F8.2. Use the
accepted F8.2/F8.3 baseline and confirmed F8.3b scope above for next work; do not reimplement
these historical items. Catalogue discovery and other explicit deferrals remain
future scopes. The later pack-interruption scope above adds a separate behavior
refinement and is not included in F8.3.

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

**Catalogue stage discovery — deferred polish:** keep one entry per species.
Conceal undiscovered growth-stage artwork with a silhouette/question mark and
accessible “Not discovered” text. Discovery should be permanent per account and
species when any owned variant reaches that stage, including intermediate stages
crossed in one credit. Backfill existing accounts from pinned owned-copy progress;
never relock discovery after storing a plant. Add authoritative discovery state,
transactional updates and account-scoped frontend presentation in that future
increment. It is separate from pack access/milestone rewards. This update keeps
all stage previews visible and adds no discovery schema/endpoints.

**Exchange and draw flow feedback — potential polish, 23 October 2026:** the user
confirmed the species-first draw update works well. Review the following frontend
flows alongside the user's future layout/UI designs; the presentation choices
below remain candidates for that design pass, except the pack-opening sequence
agreed separately below. Nothing in this section is implemented by this plan update.

- **Separate pack details from exchanging.** The current Exchange interaction
  opens pack information and applies the exchange in the same flow, making the
  intent unclear. Provide distinct ways to inspect a pack and explicitly exchange
  tokens for it. Viewing details alone should not make a purchase.
- **Show exchange completion where it happens.** The current “pack added to Draws”
  notification only becomes visible after returning from pack details. Present
  success on the active screen, clearly identifying the acquired pack and offering
  an obvious route to Draws. Decide the final layout/feedback treatment with the
  supplied designs.
- **Replace the opening result presentation.** Opening currently returns to the
  main Draws screen with only result text and a history entry. Implement the
  agreed two-tap sequence below in place of the earlier unspecified result
  view/popup proposal. Keep latest results and opening history for durable recovery.
- **Validate the revised flows during polishing.** Check details-only navigation,
  explicit purchase/open actions, visible pending/success/failure states and clear
  continuation after results. Back navigation, repeated taps, interruptions and
  retries must preserve the existing single-purchase/single-opening guarantees;
  recovered completed results should remain understandable.

**Pack opening — agreed flow, 23 October 2026; deferred to F8:** use a simple
trading-card-style wrapper themed to its pack type, such as Woodland. The approved
interaction is recorded in [spec section 3.4](forest_game_v1_spec.md#34-plant-unboxing-working-api-name-seed-draw).

1. **Confirm:** Open pack shows an “Open pack?” alert with Cancel/Open. Cancel
   leaves the owned pack unopened.
2. **Present:** after confirmation, dim the rest of the screen and enlarge the
   sealed pack in the centre. Show “Tap to open” when ready.
3. **First tap, tear and light:** briefly compress/tug the wrapper, detach its top
   strip and move/rotate/fade the strip away. Reveal coloured light from the open
   rim: Common grey, Rare blue, Epic purple, Legendary gold. Hold the opened pack
   and glow until the next tap, with “Tap to reveal”.
4. **Second tap, sprout:** lift the awarded sprout out of the opening while the
   wrapper lowers/fades. Expand the light into a halo around the sprout and show
   species, variant and rarity. Hold the result until Continue dismisses the
   overlay and restores the screen; the sprout is already in Storage.

**Assets and animation:** three aligned transparent PNGs per pack theme: sealed
pack, opened body with torn rim/dark opening, and detached top strip. Reuse the
existing species/variant sprout PNG and the sealed pack image for inventory.
SwiftUI animates image transforms, opacity and masks; shared runtime gradients
produce the opening light/halo, tinted from the receipt's rarity. No pack USDZ,
new plant model, prerecorded video or frame-by-frame animation is required.
Sounds and haptics are optional. Keep wrapper/effect assets separate from plant
runtime packages, consistent with spec section 12.4.

**Provisional resource/timing budgets, to validate during polishing:** approximately
0.5–2 MB of compressed PNG files per theme, budgeting 2 MB. Two 1024×1536 images
plus a closely cropped 1024×256 strip decode to about 13 MiB of image RAM before
rendering overhead; preload only the active theme and required sprout. These are
estimates, not measured asset sizes or total application memory. Suggested motion:
250–350 ms entrance, 350–500 ms tear with an overlapping 250–400 ms light reveal,
450–650 ms sprout reveal and 200–250 ms exit. Tap-wait states do not auto-advance;
final timings, layout and request timing remain for frontend polishing.

**Implementation boundary and acceptance:** frontend presentation only; reuse
the existing opening endpoint, receipt and account-scoped journal. Confirm the
server result before showing rarity light. Use receipt rarity, including for
legacy packs, rather than variant names/colours; the current Golden Moonwillow
fixture is Common and therefore uses grey. The animation never selects, grants
or re-grants a plant; no backend gameplay, API or database changes are required.
Prevent repeated taps from skipping transitions or submitting extra openings.
Preserve recovery after network loss, backgrounding, relaunch and account changes;
recover a committed result clearly without automatically replaying the full
sequence. Keep rewards independent of completing/dismissing the animation.
Handle missing artwork/loading, block background interactions, and preserve
visitor modal/session lifecycle behaviour. Validate all four rarity colours with
presentation fixtures, both taps, cancellation, failure/retry/recovery, VoiceOver,
Reduce Motion, large text, portrait/landscape and minimum-device performance.
Assets and frontend presentation are integrated in F8.1; native acceptance remains pending.

Cosmetic watering, swarm and elaborate effects remain in later F8 increments.
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
7. **Draft values stay draft:** oak radius, growth thresholds, base attraction and prices remain open; the selected initial B8 modifier caps are recorded above. Fictional silver-birch examples are contract fixtures, not approved launch content. The workbook's former step-ticket fields are superseded and need authoring updates before runtime configuration export.
8. **Wider Health scope still needs coverage:** completed initial Health diagnostics do not by themselves certify the newly scoped distance, energy, flights and typed-workout cases. Extend and verify them as those features land.
9. **Maturity and attraction rules stay consistent:** confirm whether the maturity maximum equals the adult threshold. If they differ, define the role of any post-adult growth rather than inventing another stage. Reject unusable profile configurations. All four stage attraction values are nonnegative and strictly increase under the proposed V1 profile contract.
10. **Optional complexity stays explicit:** weather integration and weather-dependent skills are deferred beyond B8, which keeps weather neutral. A later weather increment needs activity-time buckets; daily totals alone cannot attribute rainy steps. Complex synergies, recurring daily quests, visitor species inventories, bespoke visitor AI and offline-rate skills are not silently included in the minimal loop.
11. **Stable identity precedes more rewards:** F5a links provider methods within one Supabase user and preserves the internal game user ID. Auth refresh/linking must not regrant starters, reset activity enrolment or move queued Health data to another account. Real-provider acceptance is distinct from the completed generated-token F5 slice.
