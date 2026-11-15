# Garden items stages 1–4 — native acceptance

Source implementation: 15 November 2026. Portable checks pass; this guide does not
claim an Xcode build, XCTest run, simulator capture or iPhone acceptance.

## Setup

Follow [backend activation and one-time bench grant](../backend/ITEMS.md). Open the
updated project with sibling assets present. Run `frontend/scripts/test-mac.sh`
for hosted XCTest and Debug/Release/InternalRelease checks before device acceptance.
`ItemTests` uses the real synthetic HTTP `items-contract.json`, never personal data.

## Verify

1. Sign in to the intended account. Check existing plants, wallet, unopened packs,
   discoveries and milestones remain intact. Inventory has Plants, Items and Packs.
2. Items shows the stored Wooden Bench, Common rarity, its supplied icon and exact
   description. No growth bars, watering controls or empty skill section appears.
3. Open Edit → Storage → Items → bench details → Place. The inspector and storage
   dismiss before placement begins. Confirm ground contact, scale and icon/model
   agreement. No missing-wind error should appear for the static bench.
4. Position by tap/drag and numeric X/Y; rotate by slider. Clearance changes colour
   appropriately. Overlap with a plant/item and board-edge overflow reject Apply.
   Choose clear ground and Apply. Confirm a single saved bench.
5. Select it by tapping the model or through Garden objects. Move, rotate and store
   it. Replant it. The same owned ID persists and item capacity does not change.
6. Relaunch and verify placement. Interrupt a save, reconnect and retry: the exact
   pending request is reused, with no second copy or second edit. Rejected edits
   recover clearly. Switch accounts and verify no item/cache/pending state leaks.
7. Verify cached offline viewing; mutations require a connected confirmed state.
   Test missing artwork/reload without losing ownership.
8. Check plant placement near the bench, existing adult previews, growth effects,
   butterflies, activity sync and pack opening still work.
9. Use large Dynamic Type, VoiceOver and Reduce Motion. Item details, storage and
   position/rotation controls remain reachable without relying on model tapping.
10. Measure mixed-garden frame rate/memory/loading at the intended limits. Test
    several copies sharing one asset. Source checks are not device performance proof.

## Capacity invariant

The shared backend grant rejects a whole reward if all copies do not fit. No item
or other reward component is granted, and no event claim should be consumed.
Event item-claim UI and resale are later increments; neither is represented as a
working button here. The first-bench CLI grant uses the same tested capacity guard.

## Portable checks

```text
python tools/validate_items.py
python frontend/scripts/validate_frontend.py
python frontend/scripts/check_swift_syntax.py
```

These verify resources, contracts, source inclusion and syntax only. Record native
results explicitly when executed. No remote CI was requested or run.
