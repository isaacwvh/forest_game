# Garden items stages 1–5 — native acceptance

Source implementation: 15 November 2026. Portable checks pass; this guide does not
claim an Xcode build, XCTest run, simulator capture or iPhone acceptance.

## Setup

Follow [backend activation and one-time bench grant](../backend/ITEMS.md). Open the
updated project with sibling assets present. Run `frontend/scripts/test-mac.sh`
for hosted XCTest and Debug/Release/InternalRelease checks before device acceptance.
`ItemTests` and `ItemCommerceTests` use real synthetic HTTP fixtures, never personal
data. Stage 5 requires migration `0019_item_commerce` and explicit
`forest publish-item-shop --apply` publication; migration alone leaves offers unpublished.

## Verify

1. Sign in to the intended account. Check existing plants, wallet, unopened packs,
   discoveries and milestones remain intact. Inventory has Plants, Items and Packs;
   switching tabs retains the same Inventory title and header styling.
2. Items shows the stored Wooden Bench, Common rarity, its supplied icon and exact
   description. Cards use the plant image size and frame design. Details open in a
   smaller centered journal popup, with no sheet dragging or pull-to-refresh.
   The popup expands for accessible text; Place and Sell share equal button sizes,
   and the 137-token sell value appears on its own row. No growth bars,
   watering controls or empty skill section appears.
3. Open Edit → Storage → Items → bench details → Place. The inspector and storage
   dismiss before placement begins. Confirm ground contact, scale and icon/model
   agreement. No missing-wind error should appear for the static bench.
4. Position by tap/drag and numeric X/Y; rotate by slider. Clearance changes colour
   appropriately. Overlap with a plant/item and board-edge overflow reject Apply.
   Choose clear ground and Apply. Confirm a single saved bench.
5. Select it by tapping the model or through Garden objects. Move, rotate and store
   it. Replant it. The same owned ID persists and item capacity does not change.
   Compare the selection popup, action icons, position sheet, rotation slider and
   Cancel/Apply flow with plants: they use the same controls and styling.
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
11. Open Shop. Packs appear first, followed by Decorations with a permanent
    550-token Wooden Bench. Inspect the description even when funds are insufficient.
    Confirm a two-copy purchase costs 1,100 tokens, creates separate stored copies,
    and refreshes wallet and item counts. Cancel spends nothing. Full inventory or
    insufficient funds blocks purchase; no partial purchase is granted.
12. Inspect a placed bench: show its 137-token resale value and the instruction to
    store it first. Store it, inspect again, cancel the sale confirmation once,
    then confirm sale. Exactly one copy disappears and 137 tokens are credited.
    The previously gifted bench has the same resale value. Plants and other copies
    remain unchanged.
13. Interrupt purchase/sale responses, relaunch and recover the saved request.
    Confirm no duplicate copies, debit or credit. Repeat after backend response
    compaction, then verify wallet reconciliation. Account switching must not send
    a previous account's saved request. A failed local journal save sends nothing.

## Capacity invariant

The shared backend grant rejects a whole reward if all copies do not fit. No item
or other reward component is granted, and no event claim should be consumed.
Event item-claim UI remains a later increment. Shop purchases and the first-bench
CLI grant use the same tested capacity guard. Selling a stored item frees one slot;
placing or storing a copy does not change total ownership.

## Portable checks

```text
python tools/validate_items.py
python frontend/scripts/validate_frontend.py
python frontend/scripts/check_swift_syntax.py
```

These verify resources, contracts, source inclusion and syntax only. Record native
results explicitly when executed. No remote CI was requested or run.
