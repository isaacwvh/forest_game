# Account progression — stages 1 and 2

Source implementation, 6 November 2026. Requires explicit migration to
`0013_account_progression`. These stages provide accounting, an account-summary
API and shared native state. Profile/Home progress bars, badges, level-based
capacity benefits, gardening XP, gem spending and new packs are later stages.

## Rules and authority

`step-progression-v1` uses the existing accepted lifetime game-step counter:

- One XP per 100 steps, rounded down over the lifetime total.
- One gem per 10,000 steps, with the remainder carried across days and devices.
- Level 1 starts at zero XP. Advancing from level L costs `50 + 25*(L-1)` XP.
- XP required to reach level L is `25*(L-1)*(L+2)/2`.
- Steps count with no placed plants, mature plants and after the daily water cap.
  Pre-enrollment Health history and duplicate observations keep the existing
  eligibility/baseline rules. Optional workout/distance water does not mint gems.

XP/level are derived with integer arithmetic, rather than a second writable XP
counter. The existing account wallet holds `gems`, `lifetime_gems_earned` and
`progression_initialized`. `gem_grants` permanently records each positive mint
and its nonoverlapping milestone range. One upload crossing multiple thresholds
writes one grant, not one row per step, XP or gem.

Activity reconciliation, balance/grant updates and the request receipt share the
existing account lock and transaction. A retry returns the saved result before
reward calculation. Gem grants survive request/recap compaction. Maintenance
reconciles grants, wallet and lifetime-step entitlement before retiring history.
Spending is deferred; its accounting must be added to this reconciliation when
that feature is implemented.

## API

`GET /v1/me/account-summary` is authenticated, owner-only and read-only. It sends
`Cache-Control: no-store` and never settles visitor production or awards currency.

- `profile`: verified game identity, username, display name, join date, timezone.
- `progression`: rules/version, recorded steps, step/total XP, level, XP within
  the level, XP needed to advance, gem-step remainder/remaining, grown-adult count
  and last successful activity sync.
- `wallet`: economy version, token/gem balances, lifetime gems awarded,
  initialization status, active welcomes, collected offline visits and their sum.
- `serverTime`: the time of the locked read.

Large quantities are decimal strings, following existing wire conventions.
`plantsGrownToAdulthood` counts earned adult copies, not unique species.
Optional `progression` and `wallet` blocks also extend activity status/sync
responses. Legacy receipts lacking them remain readable. Recaps record positive
gem changes in `resourceDeltas.gems` and XP changes in `progressionDeltas.xp`;
these descriptions never award rewards when presented or acknowledged.

At 37,250 accepted steps, before spending: 3 gems, 7,250/10,000 gem-step progress,
372 XP, level 5, and 22/150 XP toward level 6.

## Upgrade the local game

From the repository root, with Docker Desktop healthy, build first:

```powershell
docker compose -f backend/compose.yaml build api migrate
```

Pause the old API and, if running, the maintenance service before the schema
upgrade/backfill so old server code cannot advance counters during the cutover:

```powershell
docker compose -f backend/compose.yaml stop api maintenance
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml run --rm api forest backfill-progression
docker compose -f backend/compose.yaml run --rm api forest backfill-progression --apply
docker compose -f backend/compose.yaml up -d api
```

The backfill command previews by default. It processes at most 500 pending
accounts; repeat `--apply` while `hasMore` is true. A second completed pass awards
nothing. It creates no fake steps, growth, visitors or token rewards. New accounts
start initialized at zero; an existing account's first post-upgrade activity sync
can also initialize its entitlement safely under the same lock.

If the maintenance worker was previously enabled, rebuild/restart it as well:

```powershell
docker compose -f backend/compose.yaml --profile maintenance build maintenance
docker compose -f backend/compose.yaml --profile maintenance up -d maintenance
```

API startup itself performs neither migration nor a bulk backfill. Preserve the
existing volumes and authentication configuration. Install the updated native
app over the existing installation; no account or activity-queue reset is needed.

## Repeatable validation without touching the game database

Set `FOREST_TEST_DATABASE_URL` to a PostgreSQL admin connection dedicated to local
validation (for the repository's local Compose database):

```powershell
$env:FOREST_TEST_DATABASE_URL = 'postgresql+psycopg://forest:forest-local-only@127.0.0.1:5432/postgres'
backend/.venv/Scripts/python.exe backend/scripts/validate_progression_local.py
backend/.venv/Scripts/python.exe -m pytest backend/tests -q
```

The smoke flow creates/drops only a random `forest_test_progression_*` database.
It tests 9,999 -> 10,000 -> 37,250 steps, account-summary reads, old-receipt retry,
ledger reconciliation and compacted completion recovery. `--write-contract`
explicitly regenerates the synthetic Swift fixture from that real HTTP flow.

Native-state/on-device acceptance: [progression acceptance](../frontend/PROGRESSION_ACCEPTANCE.md).
