# Forestivity Go backend

The Go API and workers run natively with PostgreSQL. The Python backend remains the reference for gameplay behavior and the hosted release.

See the [iPhone test and retirement checklist](RETIREMENT_CHECKLIST.md).
For current Woodland, milestones, Observatory, and the rotating Shop, see the
[release-content iPhone playtest](RELEASE_PLAYTEST.md).
For local operator commands and isolated managed-auth testing, see [Go operations](OPERATIONS.md).

## Run locally

From this directory, with Docker Desktop running Linux containers:

```powershell
docker compose up --build --wait
./scripts/smoke-local.ps1
```

The API listens on loopback port 18000. The worker listens on loopback port 18001 and exposes `POST /tasks/shop` and `POST /tasks/history`. These local services use a disposable development catalogue and development authentication. The Compose database has no published port. The smoke test creates a fresh synthetic account in the local database.

The SQL baseline comes from a disposable PostgreSQL 17.12 database after applying Alembic through `0023_cloud_runtime`. The embedded migration sets up the application schema on an empty database. The Compose fixture adds only local catalogue, rule, and runtime-control rows and a restricted local database login. Existing hosted data has not been assessed for migration-tool adoption. The second Go migration adds an index for the request backfill queue.

The local worker enables response, visitor and growth maintenance by default. Hosted configurations opt in with `FOREST_MAINTENANCE_RESPONSES_ENABLED`, `FOREST_MAINTENANCE_VISITORS_ENABLED` and `FOREST_MAINTENANCE_GROWTH_ENABLED`. The worker also reads `FOREST_WORKER_BUDGET_SECONDS`, `FOREST_MAINTENANCE_BATCH_LIMIT` and `FOREST_OPERATION_METRICS_ENABLED`.

## Validation scope

- The Go API covers account setup and replay, profile updates, catalogue, plant and item inventory, account and activity status, activity enrollment, recap listing and acknowledgements, level notice claims, compact Home attention, and visitor sessions and rewards on supported contexts.
- The Go shop worker persists new rotations with the existing slot, rarity, cooldown, and purchase-limit rules. The Go history worker reconciles wallet and growth evidence, rolls up old visitor intervals and earnings, removes covered opportunities and unused sessions and contexts, compacts old growth detail and acknowledged recaps, and removes orphaned provenance. Pending recaps, activity watermarks and legacy welcome receipts stay available. Request retention covers account and profile, activity, garden, visitor sessions and rewards, commerce, recaps, milestones and expeditions. Legacy receipts retain their full bodies. The worker reports committed row counts and optional database result metrics.
- Go serves the Shop, collection summary, owned packs, opening history, pack odds, token and gem exchanges, pack openings, item purchases and resale, and stored-plant resale. The tests cover offer windows, featured allowances, immutable odds, discovery, ownership, receipt replay, and one-time wallet updates. Pack openings record milestone discovery and expedition progress.
- Legacy and advanced milestone reads, activity and visitor observers, event deadlines, and atomic token, bonus-gem and pack claims run in Go. Claims retain the reference's legacy fulfillment, pack-capacity checks, immutable bundle definitions, running-tier supersession and durable replay. Home attention reads counts without returning the full track. The Go CLI can activate the current milestone policy, backfill entitlements and publish timed events locally.
- Garden snapshots, preview, and atomic edits apply active plant skills and passive item effects in Go. Garden responses reuse versioned skill definitions from the evaluator cache so repeated reads do not transfer the same definition for every copy. Edits validate geometry and strategy, settle the old visitor context, and write a replacement if its inputs changed. Move and rotate receipts can reuse a known inventory version. Edits that change which copies are placed return fresh inventories.
- Go activity sync accepts daily steps, distance, active energy, flights, and recorded workouts for supported gardens. Growth uses the pre-credit skill snapshot, including step bands. Device buckets, workout records, exact growth, progression, discovery, recaps, visitor context, and replay receipts commit together. Visitor accounting splits elapsed time at published rule and daily skill boundaries and preserves the previous context for already-issued arrivals.
- Morning Rain settles once per account-local day before the next garden read, placement change, activity sync, or visitor action. Alignment of Worlds uses newly eligible steps while placed. Duplicate copies share each grant, and PostgreSQL returns only bounded daily and step-tier summaries. The existing iOS garden model renders both histories.
- All five expedition routes run in Go. Monthly recurrence and partial launch boundaries use the published UTC assignment. Garden, growth, welcome and pack observers grant progress in the source transaction. Evidence uploads keep separate device watermarks and use only overlapping workout coverage. Claims award pinned currency, item or pack rewards and recover through permanent receipts.
- The local Go CLI covers current release publication, pack and visitor rule publication, event scheduling, level benefits, backfills, storage reporting and History maintenance. Hosted schema adoption, the operator role review and a staged rollback rehearsal remain before cutover.
- Run `go test ./...` for unit tests. Set `FOREST_GO_TEST_ADMIN_DSN` to an explicitly disposable PostgreSQL admin DSN on `127.0.0.1` with database `postgres` to include the integration suite. The suite creates and removes only its randomly named databases. Use `go test ./... -count=1 -v` to see byte counts.
- The 30-minute visitor test measures SQL result-value bytes for 180 heartbeats and roughly 200 welcomes with a synthetic 23-source visitor context. It excludes PostgreSQL framing, pooling, workers, activity sync, garden edits, and screen-navigation traffic. Actual Supabase Shared Pooler Egress requires a separate hosted measurement.

## Measure a supported local player-day

Set FOREST_GO_TEST_ADMIN_DSN as above, then run from this directory.

```powershell
$env:FOREST_GO_PLAYER_DAY = "1"
go test ./internal/server -run '^TestSupportedGoPlayerDay$' -count=1 -v
```

The workload includes 30 minutes of play, 180 heartbeats, approximately 200 welcomes, 23 planted copies including two adult skill sources, and 23 stored plants. It covers three daily uploads with recorded workouts and all three Alignment of Worlds awards, one activity replay, a Morning Rain rollover for 21 growing plants, preview, planting, three live moves with compact inventory receipts, placement and storage of a passive-skill bench, snapshots, Shop and pack navigation, three pack openings, buying and resale. It includes a full milestone track view, one bundle claim and replay, and progress with an active timed event. It also covers an active expedition, current, detail and archive reads, one UTC evidence upload with a workout, and a pack-opening quest reward and replay. Published milestone and expedition definitions use development species fixtures. The test includes 1,440 idle history and 96 ready Shop worker calls as shared daily traffic. It measures loopback HTTP latency and PostgreSQL downstream bytes including connection startup and message framing. Active worker cleanup, Supavisor, TLS, and IP overhead are outside the simulation.

Run `go test ./internal/server -run '^TestHistoryRollsGrowthAndVisitorEarningsWithDurableReplay$' -count=1 -v` with the same local database to measure an active history pass and its idle retry. That test ages HTTP-created activity and visitor records with a synthetic worker cutoff and verifies that replay, wallet totals, and activity watermarks survive compaction.
