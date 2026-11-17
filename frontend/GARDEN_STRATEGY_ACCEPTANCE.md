# Garden strategy editor acceptance

Source implementation: 17 November 2026. Run `scripts/test-mac.sh` on Mac for
Xcode/XCTest/Debug/Release/InternalRelease acceptance. Portable Swift execution
checks the real calculator and store with interface-only Linux stubs; it does not
validate SwiftUI observation, RealityKit, HealthKit, native disk protection or UI.

## Behavior

Edit opens a local garden draft. Attraction and Garden skills remain visible in
the bounded top panel. Expand skills for all components, source/recipient detail,
count-based requirements and shared caps. Contextual If planted/If placed/If
stored previews explain the next action. Apply and drag release only update the
draft. Adult appearance preview never changes skill eligibility.

Undo/Redo operate on whole actions. Replace chooses a stored plant/item and
validates its actual footprint; cancel preserves the existing object. Storage
includes copies removed within this draft and excludes copies already added.
Repeated moves/rotations normalize to one final action per copy.

Save garden syncs activity once for a membership-changing batch, refreshes all
owned inventory pages, re-evaluates the draft, verifies with the backend and
submits one atomic request. Changed strategy after sync needs review and another
Save. Current geometry, account/device guards and durable pending-request recovery
remain authoritative. A time-out never creates a replacement request ID.

Close offers Save garden, Discard changes and Keep editing. Backgrounding cancels
only the unfinished placement gesture; applied draft changes survive in an
account/server-scoped local draft file. Browsing offers Resume draft. Neither
resuming nor restoring a draft automatically submits anything. An external layout
or catalogue change requires resetting the draft to the new saved garden.

This supersedes the historical F4/F8 rule that every applied gesture saves, and
the rule that leaving Edit always discards all unsent placement work.

## User flows

1. Open Edit and expand Garden skills. Read attraction, existing effects and source
   detail. Collapse the panel and confirm the garden and controls remain usable.
2. Inspect a stored adult Moonwillow. Check If planted, then Place and move it.
   Apply: attraction/skills change immediately, but browsing/account state remains
   saved until Save garden. Undo and Redo restore both placement and effects.
3. With two equivalent adult Moonwillows, store one in the draft. Sleeping Dew
   remains. Store the last: it disappears. With 4% and 8% sources, removing the
   8% source falls back to 4%. Undo restores the stronger effect.
4. With adult Duskwand, add a new species: Forest Chorus increases until its cap.
   Add a duplicate species: the species-count bonus stays unchanged. Compare
   immature sources, conditional companions and each Afterglow component.
5. Inspect/place/store a skill item. Verify Skep attraction, Mailbox visitor
   storage and Rainharp future reset eligibility. Earned visits are preserved if
   capacity falls. No water is granted by previewing or applying a draft.
6. Move and rotate a plant without changing membership. Attraction and skills
   remain unchanged. Toggle adult appearance on an immature plant: it stays
   immature for calculations. Invalid placements cannot be applied or saved.
7. Replace a plant with a stored plant or item. Test cancel, different radii,
   invalid overlap and valid repositioning. Undo restores the original copy.
   Test exchanging two planted positions through store/replant within one draft.
8. Apply several edits, then Save garden. Verify every change commits once and
   survives relaunch. Cut the connection after submitting and retry the saved
   edit. Confirm the original UUID/body and one final layout are retained.
9. Create a draft, background/kill/relaunch, then Resume draft. Discard it once.
   Repeat after another device changes layout, or a stored copy is sold. Expect
   explicit review/reset, never an overwrite or a missing owned copy.
10. Let sync mature a source or change daily flights before saving. Verify the
    revised strategy is shown for review. Cross game-day midnight and verify
    context refresh, Morning Rain and daily-skill expiry use server rules.
11. Check small iPhone portrait, landscape, largest Dynamic Type, VoiceOver and
    Reduce Motion. All actions remain reachable in bounded panels. No panel
    change resets the camera, scene identity or unrelated animations. Newly added
    strategy copy uses labels, spacing and arrows without dot separators.

## Commands

```text
python frontend/scripts/validate_frontend.py
python frontend/scripts/check_swift_syntax.py
python frontend/scripts/prepare_strategy_validation.py
```

The last command creates an immutable console source under the ignored backend
validation directory. Execute it with an official Swift toolchain, passing the
absolute `garden-strategy-contract.json` path. The console executes all 87 backend
reference cases in both orders and pure draft normalization/round-trip checks.
`prepare_strategy_validation.py --typecheck-store` additionally includes the real
editor with interface stubs for a portable `swiftc -typecheck` check. Hosted store
execution, observation and disk behavior require Mac XCTest. The suite includes `GardenStrategyTests` and the updated editor/item/UI tests.

Native layout, hosted XCTest, Apple SDK builds and device acceptance remain
pending until actually executed on a Mac/iPhone. No push or remote CI is required.
