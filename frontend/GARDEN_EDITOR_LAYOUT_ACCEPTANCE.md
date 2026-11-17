# Compact garden editor and action-impact acceptance

Implemented locally on 17 November 2026. This supersedes the expanded editor
skills panel, inactive-skill disclosure and independent Save footer described in
GARDEN_STRATEGY_ACCEPTANCE.md. Gameplay rules and backend contracts are unchanged.

## Edit draft badge — 18 November 2026

Home no longer shows an unfinished-draft banner. A small red exclamation badge
appears in the corner of Edit while an unsubmitted draft has changes. Edit resumes
that draft; saving, discarding or undoing to the saved layout clears the badge.
VoiceOver announces Unsaved garden changes on Edit without an extra focus target.
A hosted UI regression covers backgrounding with a draft, resuming and saving.

## Compact impact follow-up

If stored now appears at the top, below the metrics, on an almost transparent
background over the garden. The bottom selection popup keeps its original
controls. Both impact boxes use intrinsic collapsed height, compact insets and a
tappable summary; expanded details use their measured height within a bound.
First/last qualifying-source explanations are absent. Native regression coverage
checks compact height and that the storage preview stays above the popup.

For a simple conditional test, plant a mature Moonbell, then place/store a Heartleaf
companion (a sprout qualifies). Dewlit Path changes from +4% to +8% step water and
back; the mature source stays active in both states. Refresh Storage after a test
grant. No backend code or schema change is needed for this layout follow-up.

## User test flow

1. Open Edit. Expect Undo/Redo, Edit garden and X, plus the compact Attraction,
   Visitor storage and Skills row. The skills list must start closed.
2. Open Skills, expand a multi-component skill, then X. Repeat from Home's garden
   information button. The two entries use the same layout; Edit identifies its
   draft/placement preview. Camera and selection remain intact after dismissal.
3. Verify that immature-only skills are absent. A mature conditional skill stays
   active before its companion or step threshold is met. Understory Accord says
   water to ferns and fungi directly in its bonus label.
4. Open Storage and inspect a mature plant. A separate If planted box sits above
   Place, outside the scrolling profile. First source: green + skill name.
   Equivalent duplicate source: no additional skill row. Place previews the same
   outcome above Apply. Applying changes the draft and shows the red Unsaved
   changes marker in the navigation header.
5. With Scarlet Invitation already supplied, plant an immature flowering plant.
   Expect its net attraction including the existing flowering bonus, with no
   additional skill/effect row merely for receiving that bonus. Repeat for an
   additional fern/fungus receiving Understory Accord.
6. With Golden Swirl supplied by mature Amberfan, reach four total trees (count
   Amberfan itself). Inspect the fourth tree: If stored shows red −2% water
   (Golden Swirl), plus the exact attraction loss. Details shows the percentage
   and qualifying-count transitions. With five trees, storing one must leave
   Golden Swirl unchanged. Reverse the steps to check green placement gains.
7. Supply Sleeping Dew from two mature plants. Storing one does not lose the
   skill; storing the last shows red − Sleeping Dew. If the remaining source is
   weaker, show the decrease with the skill name in brackets instead of claiming
   the skill is lost. Undo/Redo must restore all counts and previews.
8. Repeat with items: first/duplicate/last Rainharp, Mailbox capacity, welcome-time
   items, and Hollow Log Library. Adding/removing a distinct plant species can
   strengthen/weaken the Library's skill even though the plant is not its source.
   Previewing never grants water or consumes an item.
9. Try Replace with a stored plant and an item. The inspector and placement
   preview include the removed object. Cancel leaves the old garden intact.
10. Select a plant, expand several impact details, rotate, and open Position.
    Tools and Save must remain separate from contextual scrolling. Repeat on a
    small portrait iPhone, largest Dynamic Type and with VoiceOver. Compact
    landscape geometry is covered by hosted layout tests; the app remains
    portrait-only.
    Place remains reachable when inspector details expand. Signs and labels must
    communicate gains/losses without depending on colour.
11. Undo everything: Unsaved changes disappears and Save disables. Redo, save,
    reopen, and confirm persistence. Close with a draft still offers Save,
    Discard and Keep editing. Existing pending/offline recovery remains intact.

## Validation

Portable project/resource/contract, Swift syntax, real Foundation behavior,
editor-store typechecking, design detection and backend suite results are recorded
in VALIDATION.md after execution. Shared behavioral regressions execute both in
GardenStrategyTests and the portable Swift runner. Native dock bounds and editor
sheet/footer UI regressions are included for the Mac run.

Apple SDK compilation, XCTest/UI execution, native rendering, VoiceOver and
physical-device appearance require a Mac/iPhone. They cannot run on this Windows
host. Run bash frontend/scripts/test-mac.sh on a Mac before native acceptance.
No push or remote CI is needed for the local checks.
