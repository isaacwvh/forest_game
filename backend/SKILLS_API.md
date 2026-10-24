# Garden skills and caps — B8 first increment

Sleeping Dew is Moonwillow's first assigned skill: an adult placed Standard or
Golden source grants +4% combined activity-derived water to all planted copies.
Duplicates share `moonwillow_sleeping_dew` and select one strongest effect. Adults
continue emitting while their own growth is capped. Stored and immature sources
are inactive. No time, weather, currency or visitor-rate effect is implied.

## Authoritative contract

Owner garden reads, edit receipts and sync receipts include `skillSummary`:

- `policyVersion`, immutable cap values, `activeSkills`, per-copy `growthFactors`.
- Effect identity/name/description, destination, operation, exact magnitude string,
  selected source/profile version, eligible source IDs and recipient IDs.
- Effective per-metric/water factors and growth cap-reached flags.

Plant/inventory DTOs include `gardenSkills` from the owned copy's pinned profile.
Catalogue behaviour profiles expose the same declarative definitions. Catalogue
defaults cannot tell whether an old owned copy has Sleeping Dew: profile v1 copies
remain neutral. Old receipt JSON can omit the new optional frontend fields.

Growth-credit context records the policy, caps, resolved source provenance,
pre-credit stage, factors, actual award, fractions and `skillBonusGrowthMicroUnits`.
The latter is the difference from a neutral settlement using the same input,
initial remainder and maturity limit. Recaps aggregate that confirmed incremental
skill contribution; showing/dismissing a recap never grants growth.

## Components and caps

Behaviour schema 1 remains neutral. Schema 2 supports adult activation, optional
placed-count conditions, species/variant/stage/all-pinned-tags selectors, fixed
or capped per-copy magnitudes, and strongest-per-group stacking. Growth routes to
`activity` (one canonical metric) or `water`; visitors route independently to
`attraction_plant`, `attraction_garden` or `offline_capacity`. Flat operations are
implemented only for those visitor destinations. Unknown components fail closed
in Python and database INSERT validation; no configuration executes code.

`skill_policies` stores immutable required limits. `b8-caps-v1` gives +150% per
activity metric and +150% combined water (maximum ×6.25 across layers), +50% plant
and +50% garden attraction with final ×2 unmodified-attraction ceiling, a shared
flat attraction budget min(+10 points, 25% unmodified attraction), and +200%
capacity plus at most +10 flat visits within final min(absolute limit, ×3 base).
Flat attraction enters after all percentage multiplication. Capacity floors only
at the final result. Empty attraction stays zero; lowering capacity preserves
earned visits. Existing offline-rate caps remain; rate skills are unsupported.

Each upload freezes one placed-source/stage/profile snapshot for every date and
recipient. Reaching adult during that upload activates only subsequent uploads.
Only newly credited activity is affected; replay returns the original receipt.
Per-recipient filtering happens before strongest-group selection. Ties use effect
ID, profile ID/version and source UUID. Cached selector/count results and bulk
profile reads keep database/network operations outside resolver loops.

Visitor contexts persist skill provenance and effective attraction/capacity.
Elapsed time settles under the old context before membership/stage changes.
Future visitor-rule publications can select an existing validated cap policy;
the normal rule boundary supplies prospective settlement. Daily base conversion
versions remain pinned independently of credit-time skill policy.

## Explicit existing-server upgrade

From the backend directory, with the existing game database available:

```powershell
docker compose build
docker compose run --rm migrate
docker compose run --rm api forest seed-skills-dev
docker compose run --rm api forest grant-adult-moonwillow YOUR_GAME_USERNAME --dry-run
docker compose run --rm api forest grant-adult-moonwillow YOUR_GAME_USERNAME
docker compose up -d --wait --wait-timeout 90 api
```

Use `forest seed-dev` first only if the development collection has never been
seeded. `seed-skills-dev` is explicit and repeat-safe; it publishes Woodland v3
and Moonwillow v2 without re-enabling retired offers on reruns. Existing packs
keep their contracts; new packs pin `dev_moonwillow_behaviour` v2.

Host-based equivalents, using the configured existing database:

```powershell
.venv/Scripts/python.exe -m alembic upgrade head
.venv/Scripts/python.exe -m forest_api.cli seed-skills-dev
.venv/Scripts/python.exe -m forest_api.cli grant-adult-moonwillow YOUR_GAME_USERNAME
```

The named-account grant locks account/garden/catalogue, uses unique acquisition
reference `development_grant/sleeping-dew-adult-v1`, reads terminal maturity from
the pinned growth profile, leaves the copy in storage and does not increment
earned first-maturity counters. Reruns return the same plant without resetting
its later placement or progress. Development publication/grants refuse other
environments. Alembic never seeds personal account data or auto-runs at startup.
Downgrading past B8 refuses while schema-2 profiles exist rather than silently
stranding live data.

## Verification

```powershell
$env:FOREST_TEST_DATABASE_URL='YOUR_ISOLATED_POSTGRES_ADMIN_URL'
.venv/Scripts/python.exe -m pytest -q
.venv/Scripts/python.exe scripts/smoke_skills.py
```

The smoke command creates/drops a random `forest_test_skills_*` database, uses
real Uvicorn HTTP, confirms 10→10.4 water, restarts before receipt replay, stores
the source, then confirms subsequent neutral growth. Optional
`--export-frontend-contract` writes synthetic `skills-contract.json` for native
decoding/cached-round-trip checks. It never uses a personal database/account.

This increment implements skill/cap infrastructure and its first real skill.
Personal baseline/marginal-band rewards, wider daily metric/workout uploads,
weather, fixed-water grants and stateful one-use skills remain later increments;
supporting a destination does not enable an unimplemented activity input.
