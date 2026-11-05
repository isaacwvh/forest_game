# Floating garden environment — 6 November 2026

Integrates the user's approved island model and mountain/mist image as decorative
RealityKit scenery. Cloud movement is deferred. No game data, rules or APIs change.

## Preserved behavior

- The usable planting rectangle keeps its dimensions and world Y=0 surface.
  The model uses a top-centre pivot; its underside is never moved up to ground.
- Plant transforms, metre scale, clearance, picking, selection, dragging, editing,
  camera framing/controls, lighting, visitors and receipt-driven effects are unchanged.
- Header, bottom navigation, overlays and the mounted Garden/Edit viewport are unchanged.
- Scenery has no collision shapes. Failed/pending island imports retain the previous
  flat surface; failed/pending background imports retain the sage background.
- Asset imports are asynchronous and cached per renderer. A late import targets
  the latest board, and terminal renderer cleanup cancels imports and releases scenery.

Only the USDZ, background PNG and small checksum manifest are bundled from
`assets/garden-environment/v1`; editable Blender files and review renders stay out
of the app. The backdrop is an unlit, camera-relative rectangle behind the garden;
it preserves image proportions and adds no motion or touch/accessibility targets.

## Executed on Windows

- `python -X utf8 frontend/scripts/validate_frontend.py`
- `python -X utf8 frontend/scripts/check_swift_syntax.py`
- `python -X utf8 frontend/scripts/generate_project.py --check`
- Exported USDZ checks: Y-up/metres, actual top Y=0 and 10×10 footprint, all decoration
  below ground, embedded texture, no camera/light, archive CRC and 64-byte alignment.
- Byte comparison against the pre-integration working tree: existing Models,
  Services, App, Features, Configuration and backend source unchanged. The original
  renderer differs only in board artwork and four decorative environment hooks.

The four new `GardenEnvironmentTests` cases have been syntax-parsed, not executed.
Portable validation is not an Apple SDK typecheck, native XCTest or screenshot check.

## Required Mac/iPhone acceptance

Run `bash frontend/scripts/test-mac.sh` from the repository root. It runs native
XCTest/UI tests and Debug, public Release and InternalRelease builds locally.

1. Confirm both Garden and Edit show the approved island and static mountains/clouds.
   No blank/black background, flipped image, seam, stretched mountains or edge gaps.
2. Orbit fully, pan, zoom and reset. The island must have finished sides; the
   background stays fixed in the viewport. Check initial framing on small and
   large portrait iPhones and after returning from other tabs/settings.
3. Select, move, rotate, place and store plants, including near garden edges.
   Trunks stay on the same flat surface and all placement/clearance rules stay intact.
4. Check an empty garden and a full 20-plant garden; inspect selection popups,
   loading/offline notices, visitors and growth effects over the scenery.
5. Verify the existing VoiceOver camera actions and visitor targets, Dynamic Type,
   Reduce Motion, tab switching and background/foreground return. Scenery adds no
   accessibility focus targets or motion.
6. Check cold launch, a second visit and repeated Garden/Edit switches on device
   for loading hitches, memory growth or new rendering/performance errors.

Native checks are pending. No native or CI results are claimed for this handoff.
