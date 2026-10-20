"""Portable asset/project checks. Does NOT compile Swift or validate RealityKit."""
from pathlib import Path
import hashlib
import json
import math
import plistlib
import struct
import subprocess
import sys
import uuid
import zipfile
import xml.etree.ElementTree as ET
import argparse

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
STAGES = ["sprout", "seedling", "young", "adult"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--allow-local-project-settings", action="store_true",
                        help="Allow Xcode's local signing edits; still check source inclusion.")
    args = parser.parse_args()
    if not args.allow_local_project_settings:
        subprocess.run([sys.executable, str(ROOT / "scripts/generate_project.py"), "--check"], check=True)
    project_text = (ROOT / "MovementForest.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    for folder in ["MovementForest", "MovementForestTests", "MovementForestUITests"]:
        for source in (ROOT / folder).rglob("*.swift"):
            require(source.relative_to(ROOT).as_posix() in project_text, f"Source missing from project: {source}")
    catalog = {}
    models = 0
    for species_id in ["oak", "moonwillow"]:
        package = REPO / "assets" / species_id / "v1"
        manifest = json.loads((package / f"{species_id}.json").read_text(encoding="utf-8"))
        require(manifest["speciesId"] == species_id, "Species identity mismatch")
        require(manifest["stageOrder"] == STAGES and manifest["initialStage"] == "sprout", "Stage contract mismatch")
        require(manifest["units"] == "metres" and manifest["authoringUpAxis"] == "Z", "Unsupported asset convention")
        expected = {(stage, variant) for stage in STAGES for variant in manifest["variantIds"]}
        actual = {(asset["stage"], asset["variant"]) for asset in manifest["assets"]}
        require(actual == expected and len(actual) == len(manifest["assets"]), "Incomplete asset matrix")
        for asset in manifest["assets"]:
            model = (package / asset["file"]).resolve()
            thumb = (package / asset["thumbnail"]).resolve()
            require(model.is_relative_to(package.resolve()) and thumb.is_relative_to(package.resolve()), "Unsafe path")
            data = model.read_bytes()
            require(len(data) == asset["bytes"], f"Size mismatch: {model}")
            require(hashlib.sha256(data).hexdigest() == asset["sha256"], f"Checksum mismatch: {model}")
            with zipfile.ZipFile(model) as archive:
                require(archive.testzip() is None, f"USDZ CRC failure: {model}")
                require(any(name.endswith((".usdc", ".usda", ".usd")) for name in archive.namelist()), "USD stage missing")
                require(all(not name.startswith("/") and ".." not in Path(name).parts for name in archive.namelist()), "Unsafe archive")
            png = thumb.read_bytes()
            require(png[:8] == b"\x89PNG\r\n\x1a\n", f"Invalid PNG: {thumb}")
            width, height, depth, colour = struct.unpack(">IIBB", png[16:26])
            require(width > 0 and height > 0 and colour in [4, 6], f"Thumbnail lacks alpha channel: {thumb}")
            catalog[(species_id, manifest["assetVersion"], asset["stage"], asset["variant"])] = asset
            models += 1
    fixture = json.loads((ROOT / "MovementForest/Resources/Fixtures/sample-garden.json").read_text())
    require(fixture["isSample"] is True, "Fixture must be labelled sample")
    require(len(fixture["plants"]) == 15, "Expected 15-plant sample")
    require(fixture["gardenUnitMetres"] == 1 and fixture["width"] == 10 and fixture["depth"] == 10, "Development scale mismatch")
    ids = set()
    for plant in fixture["plants"]:
        uuid.UUID(plant["id"])
        require(plant["id"] not in ids, "Duplicate plant identity")
        ids.add(plant["id"])
        require((plant["speciesId"], plant["assetVersion"], plant["growthStage"], plant["variantId"]) in catalog, "Unknown fixture asset")
        for field, upper in [("x", fixture["width"]), ("y", fixture["depth"]), ("rotationDegrees", 360)]:
            value = plant[field]
            require(math.isfinite(value) and 0 <= value <= upper, "Invalid placement")
        require(plant["rotationDegrees"] < 360, "Yaw must be less than 360")
    editor = json.loads((ROOT / "MovementForest/Resources/Fixtures/editor-contract.json").read_text(encoding="utf-8"))
    require(editor["catalogue"]["isFixture"] is True, "Editor contract must use synthetic catalogue data")
    require(editor["emptyGarden"]["plants"] == [], "Expected empty starter garden")
    stored = editor["inventory"]["plants"][0]
    placed = editor["plantResult"]["garden"]["plants"][0]
    request = editor["plantRequest"]
    require(stored["plantId"] == placed["plantId"] == request["actions"][0]["plantId"], "Editor fixture ownership differs")
    require(stored["placement"] is None and placed["placement"] is not None, "Editor fixture membership differs")
    require(editor["plantResult"]["requestId"] == request["requestId"], "Editor fixture receipt differs")
    require("../spec_examples/placement-cases.json" in project_text, "Shared placement cases missing from Xcode project")
    for species in editor["catalogue"]["species"]:
        for variant in species["variants"]:
            for stage, references in variant["stages"].items():
                asset = catalog[(species["speciesId"], variant["assetCatalogVersion"], stage, variant["variantId"])]
                prefix = f"assets/{species['speciesId']}/v1/"
                require(references["modelKey"] == prefix + asset["file"], "API model key differs from bundle")
                require(references["thumbnailKey"] == prefix + asset["thumbnail"], "API thumbnail key differs from bundle")
    config = ROOT / "MovementForest/Configuration"
    info = plistlib.loads((config / "Info.plist").read_bytes())
    entitlements = plistlib.loads((config / "MovementForest.entitlements").read_bytes())
    require(bool(info.get("NSHealthShareUsageDescription")), "Missing Health read explanation")
    require("NSCameraUsageDescription" not in info, "Non-AR baseline should not request camera")
    require(entitlements == {"com.apple.developer.healthkit": True}, "Unexpected entitlements")
    ET.parse(ROOT / "MovementForest.xcodeproj/xcshareddata/xcschemes/MovementForest.xcscheme")
    sources = list((ROOT / "MovementForest").rglob("*.swift"))
    require(len(sources) >= 15, "Source set incomplete")
    # Catch accidental platform creep and health payload logging in this baseline.
    for source in sources:
        text = source.read_text(encoding="utf-8")
        require("import SwiftData" not in text and "RealityView {" not in text, f"Check iOS16 availability: {source}")
        if "Services/Health" in source.as_posix():
            require("print(" not in text and "NSLog(" not in text, f"Health logging found: {source}")
    print(f"PASS: {models} USDZs/checksums/archives, {models} alpha PNGs, 15 fixture plants, plists, shared scheme, {len(sources)} Swift source references.")
    print("PASS: synthetic B3 editor contract, owned-copy identity, bundled API asset keys and shared geometry resource.")
    print("Swift compilation, native UI, imported axes, animation, and real HealthKit remain Mac/iPhone checks.")


if __name__ == "__main__":
    main()
