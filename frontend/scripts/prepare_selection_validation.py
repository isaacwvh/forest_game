"""Prepare the real selection policy and shared checks for portable Swift.

Run the emitted main.swift with a Swift toolchain. No RealityKit or Apple SDK
coverage is claimed; the same checks also run in GardenRendererTests on iOS.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".validation-tools/selection"
OUT.mkdir(parents=True, exist_ok=True)
policy = (ROOT / "MovementForest/Rendering/GardenSelectionCycle.swift").read_text(encoding="utf-8")
checks = (ROOT / "MovementForestTests/GardenSelectionChecks.swift").read_text(encoding="utf-8")
main = '''
let count = try GardenSelectionChecks.run()
print("PASS: \\(count) shared garden selection assertions using real Swift source.")
'''
(OUT / "main.swift").write_text(policy + "\n" + checks + main, encoding="utf-8")
print(OUT / "main.swift")
