# Catalog and capacity follow-up — 13 November 2026

## Delivered scope

- Packs/Exchange summary: two flexible columns, one at accessibility text sizes;
  long quantities wrap without escaping their cells. Confirmed values/cache notices remain.
- Catalog: rarity order Common/Rare/Epic/Legendary, then localized species name
  and stable ID, unknown rarities last. Search/filter behavior is retained.
- Garden: the effective owned-plant cap is the only count ceiling; pinned
  clearance and boundary validation remain authoritative. Legacy over-limit
  layouts retain move/rotate/store/swap/reduce behavior. Planted labels show counts.
- Sprout discovery: exact-variant acquisition is permanent, alongside existing
  growth-stage unlocks. Every catalog thumbnail/portrait/stage uses the same
  generic locked state without loading concealed plant PNGs. Names/stats remain.
- Existing accounts: migration 0016 backfills live copies, earned later stages
  and permanent opening receipts, including sold sprouts. Repeated backfills are
  idempotent. Legacy earned-stage disk caches are safely upgraded offline.
- Updated clients advertise `X-Forest-Discovery: 2`; older clients receive the
  earlier later-stage-only response shape. Confirmed/recovered openings invalidate
  discovery. Account/server isolation and monotonic confirmed unlocks are retained.

## Existing game database

Source validation never migrates the personal database. To activate against an
existing installation, back up the database, stop API/maintenance writes, build
the updated backend, run the existing Compose migration service to head, and
restart the updated backend. Build/install the updated iOS client. This follow-up
does not require reseeding, resetting, republishing packs, or reactivating benefits.
The new readiness revision is `0016_sprout_discovery`.

After taking the backup, run these individually from the repository root:

```text
docker compose -f backend/compose.yaml stop api maintenance
docker compose -f backend/compose.yaml build api migrate maintenance
docker compose -f backend/compose.yaml up -d --wait db
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml up -d --wait
```

These commands are upgrade instructions, not commands executed during this task.

## Regression coverage

- Backend: starter/exact acquisition, duplicate/replayed awards, transactional
  rollback, intermediate growth stages, account isolation, legacy API shape,
  sale permanence, sold-pack migration backfill, migration/model parity and
  repeat-safe backfill. Valid 21/50/100-copy layouts, collision rejection,
  grandfathered layouts, capacities and level benefits are exercised.
- Native tests: four-metric summaries at narrow widths/long balances/larger text,
  rarity/name ordering, discovered-only species portraits, no image resolution
  when locked, exact sprout visibility, legacy cache conversion, account isolation,
  monotonic responses and level-cap propagation.
- Portable gates: backend pytest/lint, frontend project/resource/contract validator,
  Swift syntax parser, Woodland release/asset validator and whitespace checks.
  Actual execution results are recorded in the validation logs and task summary.

## Executed validation

Final backend run: **638 passed, 3 skipped** (existing opt-in storage benchmarks).
The focused backend run passed all 83 tests. An existing unordered-query assumption
in the Sleeping Dew test was corrected, strengthened, and passed in the full rerun.
Backend Ruff and changed-file formatting checks pass. Frontend project/resource/
contract/contrast validation, Woodland asset/release validation, all 92 Swift
syntax parses and diff whitespace checks pass. Native tests described above were
added/updated but require Xcode execution; no native pass is claimed.

## Native acceptance still required

Run `bash frontend/scripts/test-mac.sh` on macOS for XCTest/UI and public/internal
Release builds. Windows syntax parsing does not typecheck SwiftUI or run XCTest.

On the smallest supported iPhone and a normal viewport, check Tokens/Gems/Packs/
Plants with missing and very large amounts, largest text, VoiceOver and saved data.
Check catalog before acquisition, after pack recovery, after sale, while offline,
and when switching variants/accounts. Locked image areas must reveal no plant shape
or brief full-color flash; names/stats stay readable and earned images stay unlocked.
Verify owned/current Garden art, placement previews and opening choreography retain
their existing behavior.

Exercise dense feasible gardens around 50 plants and toward the level-20 100-owned
ceiling. Record frame rate, memory, loading, animations, selection, editing and
activity-sync responsiveness on a device. A synthetic 100-copy backend geometry test
does not establish a native rendering or minimum-device performance guarantee.
