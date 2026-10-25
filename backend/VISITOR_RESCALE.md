# Scheduled visitors and ×10 economy — 25 October 2026

Migration: `0008_scheduled_visitors`. Publication: `launch-visitors-v2`.
This supersedes the visitor timing, currency and capacity values in
[LAUNCH_ACTIVITY.md](LAUNCH_ACTIVITY.md). Plant profiles, attraction points,
footprints, rarity bonuses, growth/workout rates and +100% growth-layer caps are
retained. The new skill policy is `b8-caps-v3`; only its flat-capacity budget changes.

## Exact balance

For a non-empty garden with effective attraction A, active arrival target R is:

```
A <= 300: R = 120 + 2*A visitors/hour
A > 300:  R = 960 - 240*exp(-(A-300)/120) visitors/hour
```

Empty gardens earn zero. This is exactly ×10 the previous **base** curve. The old
ten-attempt forced-slot guarantee is replaced, so realised active income is not
an exact ×10 multiple of the old protected slot results.

| Attraction | Active target/hour | Mean interval | Offline/hour |
| --- | --- | --- | --- |
| Non-empty floor | 120 | 30 seconds | 30 |
| 2 | 124 | 29.03 seconds | 31 |
| 32 | 184 | 19.57 seconds | 46 |
| 50 | 220 | 16.36 seconds | 55 |
| 100 | 320 | 11.25 seconds | 80 |
| 200 | 520 | 6.92 seconds | 130 |
| 300 | 720 | 5 seconds | 180 |
| 450 | approximately 891.24 | approximately 4.04 seconds | approximately 222.81 |
| Upper limit | 960 | 3.75 seconds | 240 |

Offline production remains 25% of the active target, capped at 0.1 visits/second
(360/hour, above this curve's upper limit). Base capacity is **1,500**, absolute
maximum **4,500**. At A=300, base storage holds 8 hours 20 minutes; at A=50,
approximately 27 hours 16 minutes. Capacity percentages are unchanged; existing
flat capacity effects convert ×10, with their combined flat budget increasing
from 10 to **100**. Attraction effects remain in unchanged attraction units.

One welcomed/claimed visit awards **one token**. Offer/pack version **11**:
Woodland **1,200 tokens**, guaranteed Moonwillow **2,400**. Odds and pinned plant
profiles are copied exactly from version 10. Introductory milestone rewards are
**300 / 300 / 600 / 300 / 900**, total **2,400**. Existing objectives remain:
first movement, first hosted visitor, three hosted visitors, first earned seedling,
first earned adult. Claimed milestone IDs never reset.

## Arrival protocol 2

- The server draws each interval uniformly from 0.5 to 1.5 times its target mean,
  with exact symmetric discrete jitter and at most one microsecond of rounding.
  The floor therefore uses **15–45 seconds**, mean 30; A=50 uses approximately
  **8.18–24.55 seconds**, mean 16.36. This replaces slot drought protection.
- A first-ever tutorial visitor arrives within **five seconds** of starting a
  populated active garden. Tutorial state persists across end/restart/re-entry;
  legacy visitor history also prevents an additional tutorial grant.
- A 45-second presence lease is renewed by the existing ten-second heartbeat.
  Responses include bounded upcoming opportunities, not pre-awarded tokens.
  Every advertised arrival has a **20-second** welcome window within that lease.
  A client must wait until issuedAt; the server rejects early claims, expired
  claims and duplicates. The batch is bounded to **128** pending identities.
- The iOS overlay checks the confirmed server clock every **0.2 seconds**, shows
  all due visitors and gives them distinct positions. It supports **12** concurrent
  visitors; the maximum configured rate and minimum interval fit this budget.
  Lane allocation also avoids due visitors when future batches are replanned.
  Reduced Motion uses distinct static positions. Flight identity survives polling.
- Pausing/end freezes the first unfinished interval in arrival credits. Resume
  carries that wait; attraction changes rescale its remaining time to the new
  rate. Future identities under the previous context are cancelled. A missed
  unscheduled deadline is not backfilled as an immediate return reward.
- While offline, backgrounded or disconnected, active schedules are bounded by
  the lease. Expired active opportunities are never banked or issued retrospectively.
  Exact, capacity-limited offline accrual remains separate.
- Updated clients advertise arrivalProtocol 2 on start only when the server
  advertises it. An old client receives visitor_client_update_required for a new
  scheduled session. Historical protocol-1 rules still use the original engine;
  old queued request hashes and saved receipts remain compatible.

## Once-only conversion and publication

The trusted CLI holds the normal account → garden → catalogue locks, inserts new
forward rules, settles old intervals up to one cutover instant, then converts all
existing wallets and exact stored returns ×10 in the same transaction. Stored
whole visits and rule-pinned lots reconcile; fractions carry exactly, including
fractions that become whole visits. Conversion credit is recorded in the wallet
ledger and an immutable per-account audit. Overflow aborts the transaction.

Historical hosted counters, plants, layouts, growth, owned packs, request receipts,
pack openings and milestone claims are preserved. A pre-conversion receipt still
contains its original historical numbers; replaying it grants nothing again and
the client's monotonic wallet version prevents rewinding the current balance.
Pending old active sessions/opportunities close at cutover. A repeated publication
returns alreadyPublished and never converts again or re-enables retired offers.
Concurrent registration detected at the lock boundary aborts cleanly for retry.

## Apply to the existing local game

From the repository root, with Docker running:

```powershell
docker compose -f backend/compose.yaml build api migrate
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml up -d --wait api
docker compose -f backend/compose.yaml exec -T api forest publish-visitor-rescale
docker compose -f backend/compose.yaml ps
```

The new API supports old rules before publication. Run publication once after
the new image is healthy. Fresh environments first need publish-launch-balance;
wait until its future effective time has passed before rescaling. Neither
migration nor application startup performs the currency conversion automatically.

On the Mac, install the updated client over the same installation. Existing plants
work with the new visitor scheme; no fresh copies or account reset are required.
Follow [VISITOR_RESCALE_ACCEPTANCE.md](../frontend/VISITOR_RESCALE_ACCEPTANCE.md).
Execution evidence and actual local provisioning are in [VALIDATION.md](VALIDATION.md).
