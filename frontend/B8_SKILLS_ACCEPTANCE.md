# Sleeping Dew device acceptance

Run backend/SKILLS_API.md's existing-server upgrade and named-account grant,
then build this source in Xcode. Preserve local signing/auth settings. Run
`bash frontend/scripts/test-mac.sh` for native tests and Release simulator build.
Windows asset/contract checks and Swift parsing do not substitute for those runs.

1. Sign in to the same game account. Refresh, enter Edit → Storage, and verify
   one fully grown Standard Moonwillow. Its skill must still be inactive.
2. Keep a non-adult recipient planted, with room remaining before maturity.
   Plant the granted Moonwillow. After server confirmation, expand Active skills:
   Sleeping Dew, +4% water, fully grown Moonwillow source; aggregate Water +4%.
3. Walk and use Activity → Sync now. The recipient gains confirmed growth; its
   recap includes the actual additional water from garden skills. Controlled
   fixture expectation: 1,000 eligible steps at the development neutral Oak rate
   gives 10.4 water rather than 10, before any remaining-maturity clamp.
4. Refresh/sync again without new eligible steps. Growth and recaps must not be
   granted again. Relaunch and confirm the saved skill state and storage/growth.
5. Store the Moonwillow. Only after confirmation should Active skills clear.
   New eligible activity then uses neutral growth. Replant to restore +4%.
6. If another adult Moonwillow with behaviour v2 is available, place it too:
   Sleeping Dew stays +4%, with shared-source detail. Store one: +4% remains.
   Store the last: the aura ends. A legacy v1 Moonwillow emits no skill.
7. Inspect an immature v2 Moonwillow: description is visible but requires full
   growth. Maturing during one upload does not boost any recipient in that upload;
   its post-credit summary shows the skill ready for the next upload.
8. Check cached/offline viewing, cancelled/rejected placement, sign-out/account
   switching and delayed responses: no optimistic activation or other-account
   state. Old receipts cannot replace a newer confirmed garden.
9. Expand/collapse with visitors present: no camera/viewport jump and no visitor
   session reset solely from the inline disclosure. Check portrait/landscape,
   largest Dynamic Type, Dark Mode, VoiceOver and Reduce Motion.

Attraction/capacity/count/condition/percentage-limit combinations use synthetic
automated profiles; Sleeping Dew is the only newly assigned real species skill.
The current app still uploads steps only. Extra metric/workout permissions and
personal daily boosts are not enabled by this delivery.
