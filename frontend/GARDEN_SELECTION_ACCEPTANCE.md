# Overlapping garden selection

Frontend-only change. Existing model geometry, placement clearance, asset files,
backend contracts and saved state are unchanged.

Each object-selection tap makes one RealityKit collision query for all hits.
Hits are ordered nearest first and resolved through their parents to a placed
plant or decoration. Multiple mesh hits belonging to one object get one turn.

- A single-object tap selects immediately, including repeated taps.
- The first overlapping tap selects the nearest object. Repeated taps within
  24 screen points of the initial tap and two seconds of the previous tap cycle
  through the same objects, then wrap. There is no wait before selection.
- Each tap queries its current location. Objects outside that tap's hits cannot
  be selected through cycling. Changed hit membership starts at nearest again.
- The initial candidate order is retained while cycling, so small depth changes
  from finger movement or wind cannot reorder an active sequence.
- Empty ground, a distant tap, a pause, selection dismissal, camera movement,
  scene changes and deactivation interrupt the sequence. Visitor taps and editor
  placement taps keep their existing priority and interrupt object cycling.

## Local validation — 21 November 2026

Passed on Windows:

- `python frontend/scripts/validate_frontend.py`: full portable project, resource,
  asset, contract and contrast checks; generated Xcode project is current.
- `python frontend/scripts/check_swift_syntax.py`: all 115 Swift files parse.
- 170 shared behavioral assertions executed against the actual selection source
  with the existing Swift 6.0.3 toolchain through WSL. These same assertions run
  from `GardenRendererTests.testOverlappingSelectionPolicy` in hosted XCTest.
- Python validation helper compilation and frontend diff whitespace checks.

Portable reproduction: run `python frontend/scripts/prepare_selection_validation.py`,
then run its emitted `main.swift` with a Foundation-capable Swift toolchain.
The local WSL toolchain's existing Foundation SDK shim emits an SDKSettings.json
warning; the assertions complete successfully with exit code zero.

Apple SDK compilation, hosted XCTest, RealityKit execution and device response
times cannot be verified on Windows. The new hosted renderer regression covers
actual collision queries, nested ownership, front/back cycling, callbacks, camera
and dismissal resets, distinct hits and empty taps. Run
`bash frontend/scripts/test-mac.sh` on a Mac for the native suite and builds.
No push or remote CI run was performed.

## iPhone acceptance

1. Tap isolated flowers and exposed parts of trees: selection remains immediate
   and repeated taps keep the same object selected.
2. Tap a flower under the oak where both selection boxes overlap. The oak can
   select first; the next nearby tap selects the flower. Continue to verify wrap.
3. Repeat with overlapping decorations, including objects with several meshes.
4. Tap empty ground, dismiss the selection, move/zoom/orbit the camera, pause for
   over two seconds or use Select object. The next overlapping tap starts nearest.
5. Confirm Edit movement/rotation and butterfly collection retain their behavior.
6. In a populated garden on a supported iPhone, check tap responsiveness and
   camera smoothness. This change performs no additional per-frame work.
