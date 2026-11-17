"""Prepare real Foundation models for Swift validation on Linux.

Only the unrelated simd import/orientation helper and asset-provider interface
are adapted. The shipped evaluator, draft logic and wire models run unchanged.
Run the emitted immutable source with an official Swift toolchain.
"""
from pathlib import Path
import hashlib
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--typecheck-store", action="store_true", help="Also include the real editor with interface stubs for typechecking only.")
args = parser.parse_args()
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT.parent / "backend/.local-strategy-validation/portable"
OUT.mkdir(parents=True, exist_ok=True)
parts = []
for filename in ["GardenModels.swift", "AssetManifest.swift", "GardenAPIModels.swift",
                 "ItemModels.swift", "PlacementGeometry.swift", "GardenStrategy.swift", "GardenDraft.swift"]:
    source = (ROOT / "MovementForest/Models" / filename).read_text(encoding="utf-8")
    source = source.replace("import simd", "")
    if filename == "AssetManifest.swift":
        source = source[:source.index("enum AssetOrientation")]
    parts.append(source)
collection = (ROOT / "MovementForest/Models/CollectionModels.swift").read_text(encoding="utf-8")
parts.append(collection[collection.index("struct APIInventoryCapacity"):collection.index("struct APIPlantSaleQuote")])
parts.append("protocol AssetCatalogProviding { var species: [SpeciesManifest] { get } }")
# The actual skill-group comparison code has no dependency on SwiftUI.
view = (ROOT / "MovementForest/Features/Garden/GardenStrategyPanel.swift").read_text(encoding="utf-8")
parts.append(view[view.index("struct GardenSkillGroup"):view.index("struct GardenActionImpact")])
checks = (ROOT / "MovementForestTests/GardenStrategyTests.swift").read_text(encoding="utf-8")
parts.append(checks[checks.index("// Shared behavioral checks"):])
if args.typecheck_store:
    client = (ROOT / "MovementForest/Services/APIClient.swift").read_text(encoding="utf-8")
    parts.append(client[client.index("@MainActor\nprotocol GardenServing"):client.index("struct APIGardenRepository")])
    journal = (ROOT / "MovementForest/Services/PendingGardenEditStore.swift").read_text(encoding="utf-8")
    parts.append(journal[journal.index("struct PendingGardenEdit"):journal.index("struct PendingGardenEditStore")])
    cache = (ROOT / "MovementForest/Services/AccountDiskStore.swift").read_text(encoding="utf-8")
    parts.append(cache[cache.index("struct ConfirmedGardenCache"):cache.index("struct PendingActivityOperation")])
    parts.append((ROOT / "scripts/strategy_store_stubs.swift").read_text(encoding="utf-8"))
    parts.append((ROOT / "MovementForest/Services/GardenEditorStore.swift").read_text(encoding="utf-8").replace("import Combine", ""))
parts.append((ROOT / "scripts/strategy_validation_main.swift").read_text(encoding="utf-8"))
source = "\n".join(parts).replace("\r\n", "\n").encode("utf-8")
filename = "main-" + hashlib.sha256(source).hexdigest()[:16] + ".swift"
path = OUT / filename
if not path.exists():
    path.write_bytes(source)
(OUT / "source.txt").write_text(filename, encoding="utf-8", newline="\n")
print(path)
