# Connected F4 editor — setup and acceptance

**Current integration:** F5 now adds growth/Health uploads and cached viewing.
Use [F5_ACCEPTANCE.md](F5_ACCEPTANCE.md) for the up-to-date end-to-end flow.
The F4-only descriptions below are the historical editor acceptance baseline.

F4 uses the existing B1–B3 API. No growth, Health uploads or visitor rewards are
enabled. The connected editor currently runs in Debug with development tokens.
Native compilation, XCTest and physical-device acceptance must run on the Mac.

## Prepare the backend and private address

1. Follow `backend/README.md` to start PostgreSQL/API, migrate and seed the
   development catalogue. Use the documented account walkthrough to provision
   one account and stored starter. Do not reset your existing database.
2. Generate a development token for that same identity. Tokens expire after
   30 minutes. Keep the signing secret on the backend computer.
3. Use a private HTTPS address reachable from the Mac and iPhone. With Tailscale
   connected on the authorised devices, `tailscale serve 8000` on Windows can
   proxy the existing loopback API. Enable tailnet HTTPS if prompted. Keep the
   computer awake and API running. This does not require changing database or
   Adminer port bindings, router forwarding or the API's loopback binding.
4. From the Mac or iPhone, check `https://YOUR-PRIVATE-API/health/ready` first.
   Readiness only proves connectivity; authenticated reads are checked in-app.

## Build and connect

1. Copy/clone the complete repository, including `spec_examples/` and `assets/`.
2. On the Mac, run `bash frontend/scripts/test-mac.sh`. It executes Debug unit/UI
   tests and builds Release. Preserve local signing settings as described in
   `XCODE_SETUP.md`. Do not regenerate the project merely to open it.
3. Build Debug on the phone. Open Settings → Garden connection.
4. Enter the private HTTPS API origin and bearer token; choose Connect and load
   garden. Readiness is unauthenticated; `/v1/me` verifies the token/account.
5. Dismiss Settings. Expect your real garden, usually initially empty, rather
   than the 15-plant sample. New accounts have one stored standard oak sprout.
6. Choose Edit → Storage → starter. Tap/drag to position it, or use Position…
   for exact X/Y and yaw. Valid release or Apply submits one request.

Only HTTPS origins are accepted. URLs cannot contain paths, credentials, queries
or fragments. The app does not silently fall back to sample data after a saved
connection fails. Disconnect explicitly to return to the sample garden.

`--fixture-health` skips automatic saved-connection restoration during UI tests.
Manual connection still works with that launch argument. It never uploads Health.

## Database-backed walkthrough

Use Adminer Select data, or read-only queries. Match `owned_plants.id` to the
starter's ID and `garden_placements.plant_id`. Inspect garden versions and
`api_requests` without logging credentials or modifying records.

| Action | Expected app and database evidence |
| --- | --- |
| Plant at X=3.201, Y=4.609, yaw=35.12 | One placement with those exact values; garden layout/state versions advance once |
| Close and reopen app | Same ID and transform returned by the API |
| Move to X=5.001, Y=6.002 | Same placement/plant; yaw and growth unchanged |
| Rotate to 359.99 | X/Y unchanged; rotation saved |
| Attempt X=0.899 for the current 0.9 fixture radius | Invalid locally; nothing submitted; confirmed transform restored |
| Place at X=0.900 | Exact lower edge is valid; preview and request agree |
| Store | Placement row removed; owned copy, profiles and growth retained |
| Replant | Same owned ID, no new award |
| Restart the API and reopen | Confirmed layout remains in PostgreSQL |

The 0.9 radius and 10×10 board are development fixtures, not approved balance.
Use disposable test fixtures for multiple plants, swaps or overlap scenarios;
there is no public plant-grant endpoint and sample IDs are never sent to the API.

## Failure and recovery checks

- Cut the connection during submission. The app must show Save not confirmed,
  disable further edits and retain one request. Retry uses the same UUID/body.
- Kill/relaunch the app with an unresolved save. Restore and resolve that request
  before allowing another mutation. Do not uninstall: that removes app data.
- Let the token expire. Enter a replacement for the same account and origin;
  the saved operation resumes without a new request ID.
- Make an edit with another authenticated client. The next stale app edit must
  fail, refresh authoritative state and require a new player action.
- Return to foreground after another client changes the garden. Cancel an
  unsent candidate before refreshing; never overwrite a newer layout with an
  old replay receipt.
- Disconnect with an unresolved save, then reconnect to its original account.
  Recover it. A different account/server must never receive that operation.
- Reject or lose connectivity on refresh after a successful save. Keep editing
  disabled until current state is loaded; do not resend with a new request ID.
- A malformed journal or idempotency conflict pauses editing. Inspect the shown
  request ID and app-container journal against `api_requests`; do not delete it
  merely to dismiss the message. Reconnect after resolving the discrepancy.

The automated Swift tests inject lost acknowledgements, rejection, expired
credentials, write/cleanup failures, relaunch, duplicate submission and pagination.
They do not replace testing the real phone/network/Windows API together.

## Native interaction and rendering

- Drag through canopy: the anchor follows the ground plane, preserving initial
  grab offset. Dragging off-board cannot commit the last valid position.
- View mode orbits; Move mode moves the selected plant. Multi-touch cancellation
  must not commit a partial edit. Two-finger pan and pinch remain camera controls.
- Candidate circles match catalogue radius, scale with zoom and hide on exit.
  Text/icon communicates validity alongside colour.
- Adult preview displays the same variant at the candidate anchor with an explicit
  label. It does not change stage, radius, growth or submitted fields.
- Repeated moves/rotations preserve the same loaded plant entity and camera;
  unrelated wind animation does not restart. The renderer test checks reuse.
- Missing assets show a selectable placeholder and error, preserving ownership.
- Use Plants and position/rotation forms with VoiceOver and large text. Check
  portrait/landscape, small devices and all controls around safe areas.
- Check Reduce Motion, tab/settings transitions and background/foreground.
- Record a 10-minute editing session for memory/thermal/performance behaviour.

## Acceptance record

| Check | Evidence/result |
| --- | --- |
| Mac Debug tests and Release build | Pending |
| Authenticated iPhone → Windows API | Pending |
| Place/move/rotate/store/replant and DB inspection | Pending |
| Reopen/API restart persistence | Pending |
| Interrupted save / token replacement / stale client | Pending |
| Ground dragging / adult preview / entity reuse | Pending |
| VoiceOver / Dynamic Type / landscape / Reduce Motion | Pending |

Complete this record before accepting F4 as device-validated. B4–B5 and F5 can
reuse `APIClient`, token-provider boundary, API DTOs and the confirmed-state store.
