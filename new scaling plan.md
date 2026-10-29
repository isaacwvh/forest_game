# New scaling plan

Saved 29 October 2026. Architecture proposal for approximately 1,000 monthly
active users, with room to grow. This document does not implement database
reduction or change the game's accepted reward rules.

## Direction

Use a hybrid client/server architecture with compact authoritative player state.
The client renders and predicts; the server validates progression, rewards,
ownership and spending. Processing a request does not require retaining its full
response or calculation history permanently.

The earlier estimates describe the current implementation's accumulated history
under daily play, not the inherent storage cost of an idle game. MAU is distinct
from daily active users and total stored accounts. Capacity must account for all
three, account age and inventory growth.

## Responsibilities

| Client | Server |
| --- | --- |
| Scene rendering, camera, animation, menus and catalog browsing | Identity, ownership, token balances, packs, discoveries and milestones |
| Garden drag/placement previews | Validate final placement and settle membership changes |
| Predicted counters/progress between syncs | Validate accepted activity, growth conversion and duplicate prevention |
| Durable pending requests and cached confirmed state | Compact authoritative state and recovery/claim checkpoints |
| Butterfly movement between updates | Authorize visitors, validate rewards and maintain active/offline accounting |

Heartbeats remain server-side. Renew an existing session lease and advance
checkpoints; avoid one permanent full response or completion row per heartbeat.
Sequences and bounded response caches must reject stale controls without starting
new sessions or paying rewards again. Visitor timing, active/offline eligibility,
reward amounts and immediate confirmed feedback require explicit compatibility
review if their protocol changes.

Store current plants/growth/pinned profiles/placement, wallet, unopened packs,
discovery, milestones, necessary activity watermarks and deduplication, visitor
checkpoints/fractions/reward lots, important receipts and bounded recent recovery
data. Give verbose calculation traces, old snapshots, technical logs and
acknowledged recap details explicit retention or aggregation policies.

## Delivery scope

1. **Data contract and budget:** classify every table as current state, durable
   recovery, temporary history or diagnostics. Set retention and indexed-size
   targets. Inspect actual usage before choosing capacity limits.
2. **Visitor/control storage:** reuse existing leases, settled-through timestamps
   and scheduling sequences. Add safe control sequence recovery, short response
   retention, terminal-opportunity cleanup and reconciled session/day earning
   summaries. Keep important purchase/opening receipts. Preserve reward uniqueness,
   stored fractions, rule-version boundaries and concurrent-device behavior.
3. **Activity/growth storage:** retain current growth, pinned configuration and
   required watermarks/workout deduplication. Replace indefinite verbose per-copy
   calculation history with compact accounting summaries and bounded diagnostics.
   Compact acknowledged recaps while preserving pending recap and acknowledgement
   identity. Preserve the current delayed-upload policy.
4. **Migration and verification:** backfill/reconcile before removing historical
   detail; implement bounded maintenance and monitoring. Test old retries, lost
   responses, account changes, concurrent devices and cleanup races. Benchmark
   realistic MAU/DAU distributions, growing inventories and long-lived accounts,
   including physical indexes/TOAST/dead tuples and maintenance overhead.

Backend work is substantial; iOS recovery/synchronization work is moderate;
visible UI/rendering changes are minimal. Migration, regression and native-device
verification are substantial. Treat this as several focused engineering batches
over multiple weeks; refine estimates after the data-contract audit.

## Timing and boundaries

Design now; implement before a broader external alpha and before substantial new
visitor/reward systems. A bounded catalog-discovery polish batch can finish first.
During private development with few accounts this is not an immediate emergency,
but it should not be left to final release polishing.

[DATA_RETENTION_PLAN.md](DATA_RETENTION_PLAN.md) describes an interim response-cache
batch: 24-hour visitor-control responses, seven-day ordinary responses and 30-day
activity responses, followed by compact completion records. That alone does not
achieve the broader scaling goal because other histories and per-request keys
still grow. The final design should bound or summarize those high-volume records
while retaining necessary financial and recovery guarantees.

A database-engine replacement, a full UI rewrite and fully client-authoritative
currency are not required. Keep existing game rules and accepted flows as the
baseline; any necessary behavior changes must be explicit and reviewable.

## Capacity target

Use a measured total indexed per-account footprint, including retained history.
Illustratively, 1,000 stored accounts at 100 KB each consume about 100 MB; at
250 KB each, about 250 MB, before platform overhead. These are design budgets,
not measured outcomes or a guarantee that 500 MB is sufficient indefinitely.
Total registered accounts can grow beyond MAU. Inventories, important receipts,
authentication state, compute, request volume and bandwidth need separate budgets.

Require measured storage savings and preserved gameplay/recovery guarantees as
acceptance criteria. Replace provisional capacity estimates with a mixed-workload
benchmark before setting operational enrollment limits.

## Published architectural references

- [Melvor Idle offline-client announcement](https://news.melvoridle.com/offline-client-public-beta-now-available-on-steam-mobile/): local gameplay with cloud/update/purchase services.
- [Antimatter Dimensions local storage](https://github.com/IvarK/AntimatterDimensionsSourceCode/blob/master/src/core/storage/storage.js) and [cloud saves](https://github.com/IvarK/AntimatterDimensionsSourceCode/blob/master/src/core/storage/cloud-saving.js): serialized local state, offline simulation and cloud save slots.
- [AdVenture Capitalist 2016 postmortem](https://media.gdcvault.com/gdc2016/Presentations/Gwertzman_James_AdVentureCapitalistPostmortem.pdf): backend identity, purchase validation, profiles, catalogs and live events; not a disclosure of all production tables.
- [Unity idle-game example](https://docs.unity.com/en-us/services/solutions/idle-clicker-game) and [command batching](https://docs.unity.com/en-us/services/solutions/command-batching): local presentation/simulation with validated server updates.
