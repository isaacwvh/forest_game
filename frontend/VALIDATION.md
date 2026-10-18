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
