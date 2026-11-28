# Go release-content iPhone playtest

The `forestivity-go-release` project has a separate database volume. Its API and
worker listen on `127.0.0.1:18100` and `127.0.0.1:18101`. The Windows playtest
installation has a copy of the `iphone-go-test` garden from the earlier fixture
test. Subsequent progress belongs to the release copy.

## Resume on Windows

Start Docker Desktop and run these commands from the Go worktree root:

```powershell
docker --context desktop-linux compose -f backend-go/compose.yaml -f backend-go/compose.release.yaml up --build --wait
Invoke-RestMethod http://127.0.0.1:18100/health/ready
tailscale serve status
```

If the tailnet-only `9443` route is absent and port 9443 is free, restore it:

```powershell
tailscale serve --bg --https=9443 http://127.0.0.1:18100
Invoke-RestMethod https://zenbook.tail0db887.ts.net:9443/health/ready
```

Both readiness checks should return `status: ready`. For a worker check, run
`Invoke-RestMethod -Method Post http://127.0.0.1:18101/tasks/shop` and expect `ready`.

## Open the playtest on iPhone

1. On the Mac, open `frontend/MovementForest.xcodeproj` from the `codex/go-iphone-test`
   checkout. In that checkout's ignored `frontend/MovementForest/Configuration/Local.xcconfig`, set:

   ```xcconfig
   FOREST_GAME_API_URL = https:/$()/zenbook.tail0db887.ts.net:9443
   FOREST_DEBUG_MANUAL_CONNECTION = YES
   ```

2. Build **Debug** and run on the iPhone. A separate bundle identifier keeps this
   test installation's settings and Keychain separate. Clear any HealthKit fixture
   arguments for real activity testing. The Debug build setting keeps manual mode
   active when the app launches from the Home Screen.
3. On the iPhone connected to the same Tailscale network, go to **Settings → Developer
   tools → Garden connection**. Enter `https://zenbook.tail0db887.ts.net:9443` and a fresh
   30-minute bearer token for `iphone-go-test`. Generate the token on the Windows host
   from the Go worktree:

   ```powershell
   docker --context desktop-linux compose -f backend-go/compose.yaml -f backend-go/compose.release.yaml exec -T api /forest dev-token iphone-go-test
   ```


## What to verify

| Check | Expected result |
| --- | --- |
| Connection and relaunch | The copied garden opens at layout version 3 before new edits. Force-quit and open from the iPhone Home Screen. The same test profile and garden load. If the token expired, reissue it for the same subject. |
| Garden edit and recovery | Move or rotate a plant, save, and reopen the garden. Repeat a save while briefly disabling the connection, reconnect, and retry any pending action. The confirmed layout contains the edit once. |
| Rotating Shop | Three common items appear alongside any scheduled featured item. Buy one, compare the token delta with its price, and confirm the item appears in storage. Place, rotate, and store it. If a featured offer is available, its remaining allowance updates after purchase. |
| Woodland packs | See Standard, Enchanted, and Premium Woodland and inspect the odds before spending. Buy and open a token-priced pack. Its receipt, plant, and remaining pack count agree after relaunch. If an old pack is in inventory, its odds still open under its original version. |
| Milestones | Claim **New Beginnings** if available. Verify the pack and any shown currency arrive once. A return visit shows the claim recorded. |
| Observatory expedition | Confirm the current UTC run is visible. Open three packs after the run begins to complete its pack-opening quest. Claim the reward and confirm it appears once. Real activity evidence should appear after a qualifying sync. |
| HealthKit and visitors | Enable activity, record a short walk or workout after enrolment, and sync. Check the credited quantities, growth, and recap, then sync again and confirm unchanged totals if there is no new activity. Welcome a visitor and check the receipt and balance. |

Use one Shop purchase or reward claim for a disconnect test. If the app received
the first confirmation, use its receipt to check the final balance and inventory.
If it retained a pending request, reconnect and retry that request from the app.

For a fresh profile, use the same command with a new subject and connect with that
token. Reissue a token for `iphone-go-test` when returning to the copied garden.
Use a signed staging build and authorized test credentials for managed iOS sign-in and
session acceptance.

To stop the release stack after testing and keep the garden volume:

```powershell
tailscale serve --https=9443 off
docker --context desktop-linux compose -f backend-go/compose.yaml -f backend-go/compose.release.yaml stop
```

## Local operator commands

From the Go worktree root, start or resume the release project:

```powershell
docker --context desktop-linux compose -f backend-go/compose.yaml -f backend-go/compose.release.yaml up --build --wait
```

The release container runs `publish-release --apply`. The command publishes the
versioned Woodland catalogue and offers, item catalogue, milestone policy, and
recurring Observatory template. It then prepares the current UTC Shop week and
prepares the next week on Sunday. A fresh first expedition starts at publication time within the current UTC
month. Future months recur automatically. The Go publisher supports fresh local
schemas and the Go development fixture. It preserves the latter's balances,
placements, possessions, and pinned definitions while adding release content.

Use the same Compose files with `run --rm --no-deps release` followed by a command:

| Command | Effect |
| --- | --- |
| `publish-release` | Preview the complete release in a rolled-back transaction. |
| `publish-woodland --apply` | Publish the launch economy, visitor rules, Woodland catalogue, and packs. |
| `publish-item-catalogue --apply` | Publish the items, skill and value definitions, and rotating Shop release. |
| `activate-milestones --apply` | Activate the versioned milestone policy after Woodland. |
| `publish-expedition --month YYYY-MM-01 --apply` | Assign the recurring template starting in a future UTC month. Add `--start-now` for the first partial current month. |
| `prepare-shop --apply` | Prepare the current Shop week and the next week on Sunday UTC. |
| `preview-shop --week YYYY-MM-DD` | Read the saved Shop plan for a Monday UTC. |
| `fund-release-test --subject SUBJECT --apply` | Credit an existing local development account with 20,000 test tokens once. |

Write commands preview unless `--apply` is present. The embedded release data was
generated from the tracked Python publishers. To regenerate it, set
`FOREST_DATABASE_URL` to a fresh disposable loopback `postgresql+psycopg` database
named `forest_go_reference_*` and run `backend-go/scripts/export-release-reference.py`
using the Python backend's development environment. The Go runtime and release
commands use only the embedded data.
