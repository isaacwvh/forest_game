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
    asset_ids = json.loads((ROOT / "MovementForest/Resources/Fixtures/asset-index.json").read_text())
    require(len(asset_ids) == len(set(asset_ids)) and asset_ids, "Invalid asset index")
    for species_id in asset_ids:
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
    for folder in ["packs", "butterfly"]:
        require(f"../assets/{folder}" in project_text, f"Presentation resources missing: {folder}")
    pack_bytes = 0
    pack_dimensions = set()
    for part in ["sealed", "opened", "top-strip"]:
        png = (REPO / f"assets/packs/woodland/v1/woodland-pack-{part}.png").read_bytes()
        require(png[:8] == b"\x89PNG\r\n\x1a\n", "Invalid pack PNG")
        width, height, _, colour = struct.unpack(">IIBB", png[16:26])
        require(colour in [4, 6] and max(width, height) <= 1536, "Pack image budget/alpha mismatch")
        pack_dimensions.add((width, height))
        pack_bytes += len(png)
    require(len(pack_dimensions) == 1, "Pack layers must share an aligned canvas")
    require(pack_bytes <= 5 * 1024 * 1024, "Pack theme exceeds 5 MiB compressed budget")
    visitor = json.loads((REPO / "assets/butterfly/v1/butterfly.json").read_text())
    require(visitor["assetType"] == "visitor" and visitor["visitorId"] == "butterfly", "Invalid visitor manifest")
    require(visitor["animation"]["loop"] and visitor["placement"]["rootMotion"] is False, "Invalid wing/flight boundary")
    for asset in visitor["assets"]:
        path = (REPO / "assets/butterfly/v1" / asset["file"]).resolve()
        require(path.is_relative_to((REPO / "assets/butterfly/v1").resolve()), "Unsafe visitor path")
        data = path.read_bytes()
        require(len(data) == asset["bytes"] <= 10 * 1024 * 1024, "Visitor size mismatch/budget")
        require(hashlib.sha256(data).hexdigest() == asset["sha256"], "Visitor checksum mismatch")
        with zipfile.ZipFile(path) as archive:
            require(archive.testzip() is None, "Visitor USDZ CRC failure")
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
    collection = json.loads((ROOT / "MovementForest/Resources/Fixtures/collection-contract.json").read_text(encoding="utf-8"))
    bought, opened = collection["exchange"], collection["opening"]
    require(len(bought["packs"]) == bought["quantity"] == 2, "Collection pack quantity mismatch")
    require(int(collection["summary"]["tokenBalance"]) - int(bought["tokensSpent"]) == int(bought["tokenBalance"]), "Collection exchange accounting mismatch")
    require(opened["tokenBalance"] == bought["tokenBalance"] and opened["economyVersion"] > bought["economyVersion"], "Opening wallet mismatch")
    require(opened["ownedPackId"] in {p["ownedPackId"] for p in bought["packs"]}, "Opening source pack mismatch")
    require(opened["ownedPackId"] not in {p["ownedPackId"] for p in collection["packs"]["packs"]}, "Opened pack is still unopened")
    award = opened["plant"]
    require(award["growthStage"] == "sprout" and award["growthMicroUnits"] == "0" and award["placement"] is None, "Collection must award a stored sprout")
    for offer in collection["summary"]["offers"]:
        pack = offer["pack"]
        require(pack["isFixture"] and pack["totalWeight"] == sum(p["weight"] for p in pack["rarities"]), "Collection probability total mismatch")
        field = "species" if pack["schemaVersion"] == 2 else "outcomes"
        require(all(p[field] or p["weight"] == 0 for p in pack["rarities"]), "Empty positive-weight rarity")
        if pack["schemaVersion"] == 2:
            members = [s for pool in pack["rarities"] for s in pool["species"]]
            require(len(members) == len({s["speciesId"] for s in members}), "Duplicate weighted species")
            require(all(sum(v["weight"] for v in s["variants"]) > 0 for s in members), "Empty variant distribution")
    woodland = next(offer["pack"] for offer in collection["summary"]["offers"] if offer["offerId"] == "woodland")
    require(woodland["schemaVersion"] == 2 and len(woodland["rarities"][0]["species"]) == 2, "Expected equal Oak/Moonwillow test pool")
    require({s["speciesId"] for s in collection["catalogue"]["species"]} == {"oak", "moonwillow"}, "Species catalogue fixture mismatch")
    variants = {v["variantId"]: v for s in collection["catalogue"]["species"] if s["speciesId"] == award["speciesId"] for v in s["variants"]}
    variant = variants[award["variantId"]]
    asset = catalog[(award["speciesId"], variant["assetCatalogVersion"], "sprout", award["variantId"])]
    require(award["thumbnailKey"] == f"assets/{award['speciesId']}/v1/" + asset["thumbnail"], "Collection award asset mismatch")
    skills = json.loads((ROOT / "MovementForest/Resources/Fixtures/skills-contract.json").read_text(encoding="utf-8"))
    summary = skills["plantedGarden"]["skillSummary"]
    require(summary["policyVersion"] == "b8-caps-v1", "Unknown skills fixture policy")
    require(summary["caps"]["activityBonus"] == summary["caps"]["waterBonus"] == "1.5", "Growth cap fixture mismatch")
    require(len(summary["activeSkills"]) == 1 and summary["activeSkills"][0]["id"] == "sleeping_dew", "Expected one Sleeping Dew aura")
    require(all(row["waterFactor"] == "1.04" for row in summary["growthFactors"]), "Sleeping Dew factor mismatch")
    require(skills["storedGarden"]["skillSummary"]["activeSkills"] == [], "Stored source still emits skills")
    mature = next(p for p in skills["inventory"]["plants"] if p["speciesId"] == "moonwillow")
    require(mature["growthStage"] == "adult" and mature["placement"] is None, "Missing stored mature test source")
    require(next(p for p in skills["syncResult"]["garden"]["plants"] if p["speciesId"] == "oak")["growthMicroUnits"] == "10400000", "Expected confirmed 4% growth")
    config = ROOT / "MovementForest/Configuration"
    info = plistlib.loads((config / "Info.plist").read_bytes())
    require(info["UISupportedInterfaceOrientations"] == ["UIInterfaceOrientationPortrait"], "Portrait-only contract differs")
    require(info["UIUserInterfaceStyle"] == "Light", "Light appearance contract differs")
    entitlements = plistlib.loads((config / "MovementForest.entitlements").read_bytes())
    require(bool(info.get("NSHealthShareUsageDescription")), "Missing Health read explanation")
    require("NSCameraUsageDescription" not in info, "Non-AR baseline should not request camera")
    require(entitlements == {"com.apple.developer.healthkit": True,
                             "com.apple.developer.healthkit.background-delivery": True},
            "Unexpected entitlements")
    apple_entitlements = plistlib.loads((config / "MovementForestApple.entitlements").read_bytes())
    require(apple_entitlements == {"com.apple.developer.healthkit": True,
                                  "com.apple.developer.healthkit.background-delivery": True,
                                  "com.apple.developer.applesignin": ["Default"]}, "Invalid optional Apple entitlement")
    require(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"] == ["$(FOREST_AUTH_CALLBACK_SCHEME)"],
            "Auth callback scheme differs from configuration")
    require(set(info["ForestAuth"]) == {"SupabaseURL", "PublishableKey", "GameAPIURL", "CallbackScheme",
                                       "GoogleEnabled", "AppleEnabled"}, "Missing auth configuration fields")
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
    print("PASS: real synthetic collection exchange/opening accounting, pack consumption, probabilities and bundled award thumbnail.")
    print("PASS: HTTP-derived Sleeping Dew source/activation/storage, +4% growth and versioned cap contract.")
    print(f"PASS: F8 portrait/light configuration, butterfly checksum/archive, three aligned pack PNGs ({pack_bytes:,} bytes).")
    print("Swift compilation, native UI, imported axes, animation, and real HealthKit remain Mac/iPhone checks.")


if __name__ == "__main__":
    main()
