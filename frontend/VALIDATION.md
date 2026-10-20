# Validation record

Prepared on Windows; native acceptance is pending.

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
