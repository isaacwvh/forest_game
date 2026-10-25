# Scheduled visitor acceptance

First apply backend/VISITOR_RESCALE.md, then on a Mac run
`bash frontend/scripts/test-mac.sh` for XCTest/UI and a Release simulator build.
Install over the existing iPhone app, preserving login, pending requests and local
settings. The backend explicitly requires the updated client for active arrivals.

1. Reconnect the same account. Verify the converted wallet and stored return retain
   their prior pack purchasing power. Exchange prices should be Woodland 1,200 /
   guaranteed Moonwillow 2,400. Unclaimed milestone rewards should be
   300/300/600/300/900, with previously claimed objectives still claimed.
2. Open a populated garden. At A=50 the target is 220/hour (mean 16.36 seconds,
   ordinary interval 8.18–24.55 seconds); the floor is 120/hour. A first-ever tutorial
   visitor appears within five seconds; reopening must not award another tutorial.
   Existing accounts with previous visitors use ordinary timing.
3. Keep the garden open through several heartbeats. Upcoming arrivals should become
   visible without waiting for the next heartbeat. Multiple due butterflies should
   be visible and individually tappable, with distinct positions and continuous
   flight through network refreshes. Tap a later arrival before the first one.
4. Tap once/repeatedly, lose network during confirmation, relaunch and reconnect.
   The original request must recover exactly once. No future scheduled butterfly
   should appear early or become claimable before its confirmed issuedAt.
5. Leave the garden or background the app, then return. No screenful of missed
   active visitors should be replayed. End/resume must preserve unfinished waiting
   progress without providing an immediate visitor on every re-entry.
6. Grow, store or place plants while active. Check the displayed active target
   changes with confirmed attraction, obsolete future arrivals disappear and due
   visitors are not assigned overlapping lanes. An empty garden creates none.
7. Leave inactive for a measured period. At A=50, one hour adds 55 visits; at A=300,
   180. Base storage is 1,500, maximum after skills 4,500. Collection retains
   fractional production and does not duplicate after replay/relaunch.
8. Try a mature/high-attraction garden: at A=300 the mean interval is five seconds,
   tapering toward 3.75 seconds at the upper limit. Check tapping comfort, frame
   rate, VoiceOver and distinct Reduce Motion positions in portrait/landscape.

Arrival targets assume a healthy active session. Missed/expired butterflies do
not award tokens. The tenfold base-rate rescale preserves nominal prices/rate
ratios; replacement of old gap protection changes realised active earning averages.
Record measured arrivals separately from successful welcomes.
