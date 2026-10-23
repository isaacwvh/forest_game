# Validation record

Prepared on Windows; native acceptance is pending.

## F6 initializer actor-isolation correction — 23 October 2026

The user's Xcode build reported that the `VisitorJournalStore()` default argument
in `VisitorCoordinator.init` invoked a main-actor-isolated initializer from a
synchronous nonisolated context. Changed the parameter to an optional defaulting
to nil, then construct/resolve the journal inside the main-actor initializer,
matching the existing `ActivitySyncCoordinator` pattern. Explicit injected journals
retain their previous behaviour. Added a native regression case exercising the
omitted-journal initializer used by the connected app, bringing visitor cases to 13.

Reviewed nearby visitor/repository defaults; no other visitor default constructs
an actor-isolated dependency. Portable project/resource and Swift syntax checks
passed. These checks cannot certify Swift actor isolation: Xcode typechecking and
native test execution still require the Mac. No backend, migration, account data,
credentials or local Xcode settings changed.

## F6 visitor interaction — 23 October 2026

Implemented the shared native butterfly appearance/controller over the garden,
server-session start/heartbeat/end, expiry, pending/confirmed welcome and one-action
stored collection, token/hosted display and attraction/storage explanation. Editing,
navigation, sheets, background and logout pause presentation. Reduce Motion uses
a stationary appearance; an accessible welcome button avoids precise scene taps.

`VisitorCoordinator` owns confirmed versioned state and installation-scoped sessions.
All uncertain controls/rewards persist exact UUID/body before transmission in
account/server-scoped protected files. Logout detaches work and ignores late results.
Old receipts cannot roll back a newer wallet/visitor snapshot. Time projection uses
server time plus local uptime; it does not authorise rewards.

Executed on Windows:

- All **287 backend tests** passed on disposable PostgreSQL databases, including
  actual wire fixture validation and pre-B6 partially grown account preservation.
- Both real Uvicorn HTTP walkthroughs passed, including process-restart visitor
  replay; `visitor-contract.json` contains only synthetic server-generated responses.
- Portable project/resource checks passed for all 20 USDZs/alpha PNGs and the
  deterministic Xcode source/project configuration.
- All **44 Swift files** parsed without syntax errors. This is not Apple SDK
  typechecking, native XCTest execution or a Release build.
- Python lint/format/compilation, dependency consistency and diff whitespace passed.

Added **12 native visitor tests** covering actual HTTP decoding, active/pause
lifecycle, pause during start, unknown welcome retry bytes/UUID, persistence failure,
receipt-cleanup recovery, detached late responses, monotonic wallet snapshots,
uptime expiry/offline gating, another installation, scoped journals and corrupt
journal preservation. They are included in the generated project but **not executed
here**. Existing native unit/UI tests remain in the Mac test script.

Required on Mac/iPhone: Debug XCTest/UI suite, Release build, actual connected
Isaac Test walkthrough over Tailscale, touch/camera/foliage behaviour, VoiceOver,
Reduce Motion, Dynamic Type/landscape, interruptions and sustained frame/memory
performance. No native screenshots or visual acceptance are claimed. Follow
`F6_VISITOR_ACCEPTANCE.md`; keep the existing bundle ID and do not uninstall/reset.

The user accepts the earlier tested F5/F5a path except SMTP/Google/Apple setup and
dependent provider/email acceptance. The older pending notes below predate that
update. F6 native acceptance is a new, separate gate. Docker image validation also
remains unavailable because the local engine returned HTTP 500; no live account,
provider settings, database, credentials or service configuration were changed.

## F5a Supabase authentication — 23 October 2026

Implemented the pinned supabase-swift 2.55.4 Auth adapter, email-first account UI,
confirmation/recovery callbacks, Keychain session restore, async API refresh with
one unchanged-request retry, stable identity scopes, game provisioning, conditional
Google browser/native Apple login/linking, and logout/switch guards. Client values
come from ignored `Local.xcconfig`; provider flags default off. The game database
remains local and generated-token accounts are not rebound/reset.

Verified in this Windows session:

- **242 backend tests passed** on isolated PostgreSQL 17.11, including 11 new
  Supabase-shaped JWT HTTP/database cases. Disposable test databases were cleaned
  up and the test cluster was stopped.
- Ruff lint/format, Python dependency consistency, documentation links and
  whitespace checks passed.
- Docker Compose parses for development mode and the supplied Supabase template;
  no container/live provider validation is claimed.
- Deterministic Xcode project/package/source inclusion, all 20 USDZs/checksums and
  alpha PNGs, callback/configuration plists and optional Apple entitlement passed.
- All **40 Swift files** parsed without syntax errors. This is not Apple/SDK
  typechecking or execution of native tests.

Added **13 authentication XCTest cases** plus two editor/activity late-response
regressions: refresh/retry bytes, account changes during token/response work, stale
SDK events after logout, relogin scopes, recovery, confirmation, callback/config
rejection and linked identity safety. Native tests have not run here. Adapter APIs
were checked against the pinned official SDK source, including native Apple
`linkIdentityWithIdToken` support. Debug test fixtures disable live Auth.

Still required: Xcode 16.3+/Swift 6.1 package resolution, Apple SDK typechecking,
Debug XCTest/UI execution and Release build; hosted Supabase/SMTP setup and physical
iPhone login/Health/provider acceptance. Use **[F5A_AUTH_ACCEPTANCE.md](F5A_AUTH_ACCEPTANCE.md)**
for exact artifact locations and the email-first device flow. No actual credentials,
external project, Mac build, remote CI run or physical acceptance were created or
claimed by this Windows implementation.

Passed:

- Portable validation of all 20 USDZ sizes, SHA-256 hashes and ZIP integrity.
- All 20 referenced PNG thumbnails exist and contain alpha channels.
- Fifteen sample plants have valid unique IDs and resolve to delivered assets.
- Info.plist, HealthKit entitlement, shared scheme and project source inclusion checks.
- Deterministic checked-in project matches its generator before local signing edits.
- Tree-sitter syntax parsing of all 19 Swift files, including unit and UI tests.
- Independent static review passed after fixing initial animation motion gating,
  rotated bounds guides and renderer restart handling.

These checks do not typecheck against Apple's SDK. Swift compilation, XCTest,
RealityKit import/animation, native layout/accessibility and real HealthKit reads
must run on macOS/iPhone. The included macOS CI workflow has not run in this
session. See XCODE_SETUP.md and MAC_TEST_CHECKLIST.md.

The optional isolated syntax-parser dependencies live in ignored
`.validation-tools/`; they are not app or Mac build dependencies.

Design documentation handoff was unavailable; the main implementation thread
recorded the existing design conventions directly in DESIGN.md. No native visual
approval or screenshots are claimed.

## Manual workout-entry guard — 22 October 2026

The existing HealthKit workout query now excludes records explicitly marked
`HKMetadataKeyWasUserEntered = true` before the 100-result limit. False/absent
flags remain eligible for this preliminary check. Added native regression coverage
for true, false, empty and absent metadata, plus the existing date-window boundary.
The tests construct in-memory workouts and do not write Health data.

Verified on Windows: portable frontend/project/resource checks passed; all 30 Swift
files parsed without syntax errors; whitespace checks passed. Native XCTest,
Apple SDK compilation and real HealthKit query verification remain pending on
Mac/iPhone; device cases are in `MAC_TEST_CHECKLIST.md`. B4/B5 remain steps-only,
and no backend workout handler or onboarding UI was added.

## F4 implementation — 20 October 2026

Implemented a Debug connected garden editor on the existing B3 contract: private
HTTPS connection, Keychain credential, separate wire/render models, inventory
pagination, exact canonical geometry, plant/move/rotate/store, adult preview,
incremental renderer updates and one durable pending edit per server/account.
Activity remains local diagnostics. No backend production mechanics or root spec
were changed by F4.

Verified on Windows:

- Existing **132 backend tests passed** against PostgreSQL 17 using disposable
  `forest_test_*` databases. The temporary loopback server was stopped afterward.
- Exported synthetic native wire fixtures from migrated PostgreSQL through the
  actual B3 HTTP handlers (account, catalogue, inventory, placement and rejection).
- **8 additional backend fixture/schema checks passed**; Ruff lint/format passed
  for the new contract test.
- Portable asset/resource validation and the deterministic Xcode project check.
- Swift tree-sitter syntax parsing, including new native tests. This is not an
  Apple SDK typecheck or execution of those tests.

Added native tests for exact shared geometry, actual wire fixture mapping,
numeric encoding, pending-save recovery/relaunch, journal failures, token
replacement, stale edits, pagination, request serialization, historical replay,
renderer entity reuse and the development connection UI.

Still pending: Xcode compilation, native XCTest/UI execution, physical iPhone
connection to the Windows API, live database walkthrough, gestures, preview art,
accessibility, landscape and performance acceptance. No remote CI run or native
visual approval is claimed. Follow `F4_ACCEPTANCE.md` on the Mac/iPhone.

## F5 development-token integration — 22 October 2026

Implemented steps-only B4/B5 integration with separate upload consent, in-app
account provisioning, account/server-scoped protected persistence, cached viewing,
durable enrolment/sync/recap requests, explicit device replacement, membership
preflight, monotonic confirmed snapshots, exact progress display and stage assets.
Managed login is deferred by explicit user decision; Release keeps the sample.
Health observer background delivery and cosmetic watering remain deferred.

Verified on Windows:

- **231 backend tests passed** against the isolated loopback PostgreSQL 17.11
  test cluster, using disposable `forest_test_*` databases. This includes 13 new
  F5 contract/progress cases in addition to all 218 prior cases.
- Actual Uvicorn HTTP activity walkthrough passed. Its new optional
  `--export-frontend-contract` exported synthetic account/catalogue/device/sync/
  recap responses to the bundled `activity-contract.json`; no personal Health data.
- Ruff lint/format and diff whitespace checks passed.
- Portable validation passed for all 20 bundled USDZs and alpha PNGs, shared
  geometry and checked-in project/source inclusion.
- All **35 Swift files** parsed without syntax errors. This is not Apple SDK
  typechecking or execution of XCTest.

Added 25 native F5 tests for real wire decoding, strict/null step encoding,
consent, enrolment/unavailable baseline, pre-baseline filtering, exact retry bytes,
cleanup failure, definitive rejection, token expiry, conflicts, coalesced triggers,
offline capture/cache, scope tampering, device replacement, fixture isolation,
recaps, timestamps/timezones and exact progress. Added two editor membership
preflight cases and a renderer stage/same-stage update case.

Still pending: Xcode Debug native unit/UI execution and Release build, physical
iPhone HealthKit/Tailscale checks, native layout/accessibility and renderer review.
No Mac build, remote CI execution, device aggregation or native visual acceptance
is claimed. Use **F5_ACCEPTANCE.md** for setup, expected API/database evidence,
failure cases and the acceptance record. Existing development game state was not
migrated, seeded or reset by this validation.

## F6 smoothness fix — 23 October 2026

Separated butterfly frame rendering from network updates; preserved opportunity
identity during heartbeats; added one atomic, durable reward queue behind an
in-flight heartbeat, with backwards-compatible single-request journal loading.
Read-only activity refreshes keep a confirmed foreground garden visitor-eligible.
Expiry uses monotonic elapsed time and cannot be extended by an old receipt.

Reserved scrollable status/control panel regions by screen geometry, avoiding
viewport changes for sync, loading and invalid-placement messages. Metadata-only
snapshots skip renderer reloads; pause/resume and asset retries preserve camera
pose. A single-finger gesture keeps its initial plant/camera ownership even when
the preview is cancelled midway. Verified managed accounts retain their editor
across foreground refreshes.

Windows verification: portable asset/resource/project validation passed (20 USDZs,
20 alpha PNGs, 36 app source references); all 46 Swift files parsed without syntax
errors; diff whitespace check passed. These are not Apple SDK typechecks.

Added 14 native regression cases for heartbeat visibility, duplicate/queued taps,
lost-heartbeat recovery/relaunch, save failure, account detachment, stored claims,
legacy journal compatibility, monotonic expiry, real hosted timeline rendering
(five-second heartbeat and Reduce Motion), read-only refresh eligibility, camera
preservation, gesture ownership and stable portrait/compact viewport sizing with
large text. They require Mac execution; no native test pass or Release build is
claimed here. Rendering probes are Debug-only and nil by default. Artificial
delays exist only in test fakes.

Run `bash frontend/scripts/test-mac.sh` on the Mac, then the smoothness section in
`F6_VISITOR_ACCEPTANCE.md` on the existing iPhone/account over Tailscale. Backend,
migrations, account data and ignored local configuration were not changed.


## F7 collection source and Windows verification — 23 October 2026

Added Exchange/Catalog/Draws through a simple side menu. Source includes durable,
account/server-scoped collection requests and confirmed result recovery; exact
retry bytes/UUIDs; monotonic wallet versions shared with B6; Storage refresh;
profile/rarity/catalogue metadata; and an indexed bundled-asset loader. All test
offers are available; unlock/milestone rewards and social work are deferred.

Portable validation passed: 20 USDZ checksum/archive checks, 20 alpha PNGs,
15 sample-garden plants, generated project/source/resource inclusion, plists,
shared scheme, B3 fixture/geometry checks, and genuine synthetic HTTP collection
accounting/pack-consumption/probability/award-thumbnail checks. All **50 Swift
files** parsed without syntax errors; this does not typecheck Apple SDK APIs.

Backend full regression run passed 335 tests; the final 61-test collection/
migration run and real activity/visitor/collection HTTP walkthroughs passed.
The latter restarts Uvicorn before replaying exchange/opening receipts. Exported
collection-contract.json contains synthetic earned tokens, not injected personal
account balance data. Historical visitor fixture values remain unchanged in
meaning while adding the new economyVersion field.

Added eight native collection unit tests for real wire/stat decoding, lost
response/relaunch, persistence failure, terminal versus recoverable rejection,
late detached responses, wallet ordering/callbacks and journal scope/tampering.
Added one UI test for collection-menu routes and return to Garden. Existing
F6 visitor lifecycle and camera preservation remain regression requirements.

Not executed here: Xcode Debug XCTest/UI tests, Apple SDK compilation, Release
simulator build and physical iPhone visual/accessibility/Health/Tailscale flow.
Run bash frontend/scripts/test-mac.sh on the Mac and follow
F7_COLLECTION_ACCEPTANCE.md using the existing installation/account. The local
Docker engine also returned HTTP 500, so backend image validation is pending.
No existing game database, auth settings, local signing/configuration or account
was changed by these checks.
