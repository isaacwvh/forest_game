# Activity and two-species balance update — 25 October 2026

Visitor economy update: [VISITOR_RESCALE.md](VISITOR_RESCALE.md) supersedes the
visitor timing, token, capacity and milestone numbers below after publication.

Migration: `0007_activity_launch`. Publication: `launch-balance-v1`.
These selected test-launch values supersede earlier development fixtures. Changing
the workbook does not publish runtime configuration. Personal baseline boosts,
weather effects and permanent pack unlocks are deferred; both offers are open.

## Selected configuration

| Input | Base water | Daily water-eligible quantity cap |
| --- | --- | --- |
| Steps | 10 / 1,000 steps | 30,000 steps |
| Combined walking/running distance | 1 / kilometre | 30 km |
| Active energy | 1 / 100 kcal | 2,000 kcal |
| Flights climbed | 2 / 5 flights | 100 flights |
| Each supported workout type | 2.5 / 10 eligible minutes | **120 minutes shared across all types** |

The workout rate is a game bonus, not a physiological equivalence to steps.
Sixty eligible minutes give 15 base water. HealthKit mapping `healthkit-types-v1`:
running 37, walking 52, cycling 13, hiking 24, swimming 46, yoga 57, and
strength training 20/50. Other original types are retained but earn no workout
water. Workout distance is diagnostic; it is never added to daily distance again.
Daily quantities intentionally overlap workout duration.

Only Oak and Moonwillow are published. Both have
`{steps: 1, "workout_minutes.*": 1}`. The other daily quantities are tracked and
fully supported by the calculator but give these two plants zero extra water.
Only placed plants grow. Stage thresholds are cumulative 0 / 100 / 400 / 1,000
water (sprout / seedling / young / adult); adults stop at 1,000.

| Species | Rarity | Reserved radius | Stage attraction |
| --- | --- | --- | --- |
| Oak | Common | 0.90 | 2 / 5 / 12 / 20 |
| Moonwillow | Epic | 0.95 | 2.9 / 7.25 / 17.4 / 29 |

Adult targets use the workbook rule: round `20 × (radius / 0.9)² × rarityBonus`
to the nearest 0.5. Rarity bonuses: Common 1, Rare 1.15, Epic 1.30, Legendary
1.50. Earlier stages are 10% / 25% / 60% of adult. Radius affects placement
clearance; it does not rescale existing art.

`b8-caps-v2` limits activity-layer bonuses to +100% and the combined-water layer
to +100%, giving a maximum ×4. The original v1 policy remains immutable for old
settlements. Existing attraction/capacity skill caps are retained. Sleeping Dew
remains +4% combined water from a placed adult Moonwillow; duplicate sources
share one strongest group. No additional attraction/capacity skill is assigned
to either launch species.

Woodland costs **120 tokens**, with Common Oak 75% / Epic Moonwillow 25%.
Conditional variant odds: Oak Standard/Blue/Vined 75/20/5%; Moonwillow
Standard/Golden 90/10%. The guaranteed Moonwillow pack costs **240 tokens**.
Pack definitions and offers use version **10**. No pity mechanic is added.

## Attraction and visitor conversion

Empty gardens produce zero. Otherwise, for effective attraction `A` in points:

```
A <= 300: p = 0.10 + A / 600
A > 300:  p = 0.80 - 0.20 × exp(-(A - 300) / 120)
```

`p` is the chance per eligible 30-second active decision. The first tutorial
opportunity is forced, and the tenth eligible decision is guaranteed after nine
misses. Existing lease, visibility, welcome, expiry and replay checks remain in
force; backgrounded apps do not receive active welcomes automatically.

| A | Base chance / slot | Offline visits / hour |
| --- | --- | --- |
| 2 | 10.33% | 3.10 |
| 32 | 15.33% | 4.60 |
| 100 | 26.67% | 8.00 |
| 200 | 43.33% | 13.00 |
| 300 | 60.00% | 18.00 |
| 450 | 74.27% | 22.28 |

Offline rate is `min(0.01, p / 30 × 0.25)` visits/second, with exact fractional
storage, **150 base capacity**, **450 absolute maximum** after skills, and one
token per hosted visit. This is 25% of the base opportunity rate, rather than
25% of actual welcomes after gap protection or missed/expired opportunities.
More attraction improves rate; capacity determines how long returns can accrue.
The curve keeps early footprint/rarity differences modest while leaving useful
rate growth across a roughly 10–15 adult garden.

Five one-time, explicitly claimed milestones provide finite early funding:
first eligible movement 30; first hosted visitor 30; three hosted visitors 60;
first activity-grown seedling 30; first activity-grown adult 90. Total **240
tokens**. Claims write the wallet ledger and durable receipts but do not count
as visitors. Development adult grants do not satisfy earned-growth milestones.

## Accounting and compatibility

- Four daily quantities have independent availability, first-readable current-day
  enrolment baselines, device-replacement baselines and monotonic earned watermarks.
  Nil is unavailable, not zero. Lower corrections never reissue earned quantities.
- Wider upload consent is explicit. Existing iOS journals remain steps-only until
  the player enables optional quantities and workouts. Saved request bytes/UUIDs
  are retried unchanged. New daily fields are optional for older clients.
- Workouts are eligible only after workout upload enrolment, within the observed
  seven-day reconciliation window. Manual `true` is excluded; `false` and absent
  metadata remain distinct and eligible, without proving authenticity. Future
  workouts are excluded. The first processed UUID and its provenance are frozen.
- The client provides active intervals, excludes explicit pauses, and uses typed
  multisport segments instead of the parent. Unsupported transitions receive no
  water. With no timestamped pause detail, duration is spread proportionally over
  the elapsed interval. Parent and segments are never both rewarded.
- A per-owner/day covered-interval union deduplicates sources, types and later
  overlapping imports. First accepted eligible classification wins; within a
  batch ordering is start/source/UUID and segment start/end/type. Late edits do
  not reclassify settled time. All launch workout rates and plant coefficients
  are equal across types. Crossing midnight splits by the account calendar,
  including daylight-saving boundaries; fractional microseconds/water carry.
- Duration beyond the shared daily cap is covered and cannot become backlog.
  Historical optional data does not receive a retroactive initial grant. Existing
  rule-pinned daily buckets keep their conversion rules; new buckets use the
  configuration effective at their accounting boundary.
- Activity sync allows 1 MiB, at most 500 workout identities / 2,000 segments per
  request and 256 segments per record. iOS durably chunks uploads and skips an
  invalid/oversized individual workout without blocking other readable activity.
- Health observer/background delivery is best effort. Foreground/manual sync is
  the recovery path. Apple SDK compilation and real-device behaviour need Mac
  and iPhone acceptance; portable Windows checks do not establish either.

## Apply to an existing local Docker installation

From the repository root, with Docker healthy:

```powershell
docker compose -f backend/compose.yaml build api migrate
docker compose -f backend/compose.yaml run --rm migrate
docker compose -f backend/compose.yaml run --rm api forest publish-launch-balance
docker compose -f backend/compose.yaml up -d api
docker compose -f backend/compose.yaml ps
```

Build **migrate explicitly**: it is in the tools profile. There is no startup
migration. Publication is atomic and repeat-safe, preserves accounts, layouts,
growth, balances, old pack definitions and every owned plant's pinned profiles.
It reduces Moonwillow clearance to 0.95 and replaces offers with version 10;
already owned packs remain openable with their old pinned definitions.

For the existing verified test username, obtain new stored sprouts without
spending tokens (local/test only):

```powershell
docker compose -f backend/compose.yaml exec api forest grant-activity-test-plants isaac_auth_test --dry-run
docker compose -f backend/compose.yaml exec api forest grant-activity-test-plants isaac_auth_test
```

The grant is repeat-safe per species/account and does not reset counters. Old
plants retain their old behaviour, including after storage/replanting. Opening an
**old** pack also retains old behaviour; use these granted sprouts or newly
purchased version-10 packs to test workout growth. A pre-update adult Moonwillow
with Sleeping Dew can still boost the new sprouts.

Native build and hands-on flow: [B8_ACTIVITY_ACCEPTANCE.md](../frontend/B8_ACTIVITY_ACCEPTANCE.md).
Executed validation and deployment status: [VALIDATION.md](VALIDATION.md).
