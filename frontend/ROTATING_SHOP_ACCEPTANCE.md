# Rotating shop and fifteen items — native acceptance

Use a disposable backend migrated to `0020_item_rotations`, with the item catalogue
published explicitly. Never advance the clock or inject test funds in a personal
game. `ItemRotationTests` uses the synthetic real-HTTP contract exported by
`test_export_real_http_rotation_contract` when
`FOREST_EXPORT_ITEM_ROTATIONS_CONTRACT=1`.

1. Run `scripts/test-mac.sh` on a Mac: XCTest plus Debug, Release and InternalRelease
   builds. Run `ItemRotationTests`, `ItemTests` and `ItemCommerceTests` explicitly
   when diagnosing import/contract issues.
2. Verify all fifteen icons and metre-scale models, especially asymmetric lamp and
   pitchfork pivots and the large picnic footprint. Confirm mixed plant/item
   collision rejection and valid movement, rotation and storage.
3. Verify five loops: honey drip, foxfire, harp droplets, mycelium pulses and kite
   breeze. Static items must not require wind. Test repeated clones, preview exit,
   storage/removal, backgrounding and Reduce Motion without leaked playbacks.
4. Packs remain first in Shop. Each day shows three distinct Commons and only its
   saved Rare/Epic features. Check all seven days against the persisted preview,
   including overlap and Common-only days.
5. Keep Shop open through reset using only an isolated injected backend clock.
   Confirm a new fetch, disabled/dismissed expired confirmations and correct new
   stock. Close before another reset and reopen after it. Test foreground refresh,
   offline expiry, reconnect/retry and a refresh deferred by purchase recovery.
6. Change device wall time/display timezone. Countdown duration and server purchase
   availability must not change. Check Singapore activity midnight separately from
   the 08:00 shop reset.
7. Buy a featured copy. Another device/request cannot bypass its one-copy limit;
   selling it does not restore allowance. Interrupt a successful purchase, expire
   the offer, relaunch and recover the exact original receipt without spending again.
8. Place/store every skill item and compare active skills and growth factors.
   Duplicate copies apply once. Check energy/workout separation, species diversity,
   shared caps, garden attraction and visitor storage with existing plant skills.
9. Verify the kite gives a new default butterfly 24 seconds. Existing visible
   opportunities keep their expiry when the kite moves or is stored. Confirm every
   advertised scheduled butterfly fits its complete window inside the lease.
10. Keep harp/plant placed across several account-local midnights with the server
    stopped between visits. Restart and enter Garden: each eligible date grants
    2.5 once per plant. Repeat reads/relaunch, duplicate harps, store/replant, mature
    plants and DST boundaries. Garden information shows confirmed daily totals.
11. Verify old benches, wallets, discoveries, milestones and pending receipts survive
    upgrade. Check account isolation, VoiceOver, Dynamic Type and unavailable art.
12. Measure memory, loading and frame rate with the intended mixed-garden limits,
    including several animated copies. Portable hashes and syntax checks do not
    establish device performance.
