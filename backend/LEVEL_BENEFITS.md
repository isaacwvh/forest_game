# Account level benefits

Policy `level-benefits-v1` adds server-authoritative capacities and durable level-up
notices. Migration `0014_level_benefits` installs the schema; the separate,
idempotent activation command enables the policy. Migration alone retains the
previous fixed capacity behavior.

## Approved tiers and calculations

| Account level | Base offline capacity | Owned plant limit |
| --- | ---: | ---: |
| 1 | 600 | 50 |
| 2 | 675 | 50 |
| 4 | 825 | 50 |
| 5 | 900 | 60 |
| 10 | 1,200 | 75 |
| 15 | 1,500 | 90 |
| 20 and above | 1,800 | 100 |

The complete base formula is
`600 + 75*min(L-1,4) + 60*min(max(L-5,0),15)` for `L >= 1`.
Levels 1–5 add 75 per level; levels 6–20 add 60 per level. The base plateaus at 20.
Owned plants use tiers 1–4:50, 5–9:60, 10–14:75, 15–19:90, 20+:100. This limit
counts planted plus stored copies. The configured planted and unopened-pack
limits are unchanged (defaults 20 and 50).

Effective offline capacity is
`floor(min(base*(1+resolvedPercent)+resolvedFlat, 3*base))`.
Existing skill group resolution, percentage/flat budgets, and the current visitor
rule's flat-unit multiplier remain in force. Do not apply the old visitor rate
rescale multiplier to these base values. The ceiling includes flat bonuses.

XP remains `floor(lifetime accepted steps / 100)`; reaching level L requires
`25*(L-1)*(L+2)/2` total XP. Gems remain one per 10,000 accepted steps. Maturity XP,
pack changes, and other level-scaled stats are outside this change.

## Existing local Docker backend upgrade

Run from `backend`. These commands work individually in PowerShell and a Mac
terminal. Check each command succeeded before continuing. The API and maintenance
worker stay stopped while the old offline contexts are settled and the policy is
activated. No seed/reset/publish command is needed.

```text
docker compose stop api maintenance
docker compose build api migrate maintenance
docker compose up -d --wait --wait-timeout 90 db
docker compose run --rm migrate
docker compose run --rm --no-deps api forest activate-level-benefits
docker compose run --rm --no-deps api forest activate-level-benefits --apply
docker compose up -d --wait --wait-timeout 90
```

The preview reports the account count without changing state. Apply records one
database-clock activation boundary, settles existing visitor contexts under the
old policy, baselines each existing account at its current level, and installs new
contexts for future earnings. Running apply again reports `alreadyActive` and
changes nothing. Existing stored visitors above a newly lower capacity survive;
further offline accrual pauses until storage is below the effective limit.

Lifetime steps, XP, gems, tokens and existing plants are retained. Historical
levels do not create catch-up popups. A newly registered account starts at level 1
with the new benefits once the policy is active. Use the full Compose startup if
the local `.env` enables the maintenance profile.

This implementation has not run these commands against the personal game
database. Automated validation uses disposable `forest_test_*` databases only.

## Contracts and one-time presentation

`GET /v1/me/account-summary` adds nullable `benefits` and `levelUpNotice` fields.
Benefits include base/effective/maximum offline capacity, owned/planted limits,
next increases, and progression/garden versions. Reads do not settle visitors.
Activity sync settles the previous context before crediting steps; a crossing
creates its notice and new capacity context in the same transaction. A multi-level
crossing within one sync produces one `Level X → Y` notice with aggregate gains.
Crossings after level 20 still produce a notice, with no capacity gain rows.

The owner-authenticated endpoint
`POST /v1/me/level-up-notices/{noticeId}/present` accepts
`{requestId, installationId}` UUIDs. It claims the oldest pending notice under the
account lock. Only the winning request/installation may present; an exact retry
gets the same permission, while other devices get `mayPresent:false`. Notices and
reached/presented high-water marks are durable account state, not expirable
diagnostic history. They survive request/history compaction.

The client journals its original claim before sending it, then saves a shown
marker before mounting the card. This prioritizes at-most-once presentation across
retries, relaunches, reinstalls and devices. A crash between the final local marker
and the first rendered frame can skip that animation; benefits are already earned
and remain visible in Profile. Network/disk failures defer presentation without
blocking gameplay or rolling back benefits.

## Validation

Run `pytest tests -q` with `FOREST_TEST_DATABASE_URL` set to a PostgreSQL connection
that may create/drop isolated test databases. The suite covers migration parity,
all tier boundaries, existing balance/skill math, activation, over-cap storage,
inventory enforcement, atomic rollback, multi-level crossings, owner isolation,
replayed sync and concurrent device claims.

`python scripts/validate_level_benefits_local.py` creates and deletes a separate
random database and exercises HTTP level 4 → 5, offline 825 → 900, plants 50 → 60,
sync replay, and cross-device presentation. Optional `--write-contract` regenerates
the synthetic frontend contract; ordinary validation does not rewrite it.

See [native acceptance](../frontend/LEVEL_BENEFITS_ACCEPTANCE.md) for app testing.
