# Garden strategy previews and atomic draft saves

Source implementation: 17 November 2026. No schema migration or content publication
is required for this increment. Deploy the backend before using the updated editor.
Personal-game activation and native device acceptance remain separate.

## Prediction data

Owner garden DTOs add optional `strategyContext` version 1: the immutable cap
policy, today's accepted flights, game date, next context expiry, effective
visitor-rule version, level-adjusted base/maximum visitor capacity, flat-capacity
conversion and base welcome duration. Expiry is the earlier of the next local
midnight and a future visitor-rule publication. Daily flights are read even when
an attracting source is currently stored, so planting it can be predicted.

Owned plant `gardenSkills` already contains full pinned effect definitions. The
native decoder now retains them. Owned items add `strategyRules` from their exact
immutable definition/skill binding, including canonical workout expansion and
Morning Rain eligibility. Cosmetic items explicitly carry empty effects.
Historical profiles, neutral copies and earlier percentages are preserved.

## Read-only verification

`POST /v1/me/garden/preview` accepts the same typed, exact-number body as an edit.
It locks owner/garden in the normal order, checks ownership, catalogue/layout
versions, supported clients, capacity and complete mixed geometry, then evaluates
the proposed final membership using the real `SkillSnapshot` resolver.

It returns `totalAttractionMicroUnits`, `skillSummary`, `offlineCapacity`,
`context` and a SHA-256 `fingerprint`. It does not settle visitors/daily grants,
change placements or growth, advance versions, grant progression, or retain a
request/receipt. This route does not call the mutating garden-read path.

The client sends the fingerprint as optional `expectedStrategyFingerprint` on
`POST /v1/me/garden/edits`. Inside the write transaction, the server settles due
daily boundaries, revalidates the final layout and checks the proof using the
same post-lock boundary as visitor accounting. Changed relevant inputs produce
409 `strategy_changed` before any partial edit commits. Successful replay still
precedes present-day validation and uses the original UUID/body.

Legacy requests may omit the proof. Null/absent proof fields are omitted from
historical request hashes. Complete mixed saves now permit up to 200 distinct
actions total, retaining one action per copy and the 64 KiB exact-JSON body bound.
A save is never split into partially committed batches.

## Validation

`tests/test_garden_strategy.py` covers read-only previews, identical preview/save
results, proof rejection, ownership, stale layouts, growth changes, batch limits
and legacy hash compatibility. `scripts/export_garden_strategy_contract.py`
exports 87 deterministic pure resolver cases for the unchanged Swift evaluator.
The cases cover all Woodland species, all fifteen items, mixed stages, duplicate
sources, daily flights, step bands, legacy Sleeping Dew and shared caps.

See [native flows](../frontend/GARDEN_STRATEGY_ACCEPTANCE.md). No preview is a
reward, milestone/expedition completion, elapsed-time settlement or water grant.
