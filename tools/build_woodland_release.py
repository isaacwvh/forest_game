"""Compile the approved workbook and existing asset manifests; never edits Excel."""

import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zipfile
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "outputs/plant-planning/Plant_Game_Data_Balanced_2026-11-10.xlsx"
OUTPUT = ROOT / "backend/src/forest_api/data/woodland-v1.json"
STAGES = ("sprout", "seedling", "young", "adult")
WORKOUTS = ("cycling", "hiking", "running", "strength_training", "swimming", "walking", "yoga")
COPY = {
    "sleeping_dew": "All plants gain 8% more water.",
    "misty_step": "Steps give 12.5% more water.",
    "sweet_berries": "Garden attraction increases by 4%.",
    "gathering_dew": "Plants gain 1.75% more water per Dew Fern, up to 7%.",
    "nurturing_seal": "Stored visitor capacity increases by 15%.",
    "forest_chorus": "Garden attraction increases by 1% per distinct species, up to 9%.",
    "whispering_welcome": "Herbs gain 6% more step water.",
    "dewlit_path": "Steps give 4% more water, or 8% with a Heart Leaf.",
    "nurse_canopy": "Sprouts and seedlings gain 11.5% more water.",
    "sweet_ascent": "Each flight climbed today adds 1% garden attraction, up to 10%.",
    "swift_stride": "Running workouts give 10% more water.",
    "iron_resolve": "Workouts give 8% more water.",
    "first_drops": "The first 2,000 steps each day give 10% more step water.",
    "afterglow_reserve": "Active-energy water increases by 5%. Stored visitor capacity increases by 8%.",
    "humble_company": "Common plants give 12% more attraction.",
    "sapphire_stride": "Steps after the first 2,000 each day give 15% more step water.",
    "scarlet_invitation": "Flowering plants give 8% more attraction.",
    "layered_haven": "Stored visitor capacity increases by 20%.",
    "golden_swirl": "Plants gain 2% more water per tree, up to 8%.",
    "root_network": "Trees give 4% more attraction, or 6% with a groundcover.",
    "understory_accord": "Ferns and fungi gain 7.5% more water, or 10% with a tree.",
}
# Workbook labels -> shipped artwork. Display names use the actual artwork labels.
ALIASES = {"regular": "standard", "autumn gold": "autumn-gold",
           "pink lightning": "pink-lightning", "lantern": "gold-glow"}
SPECIFIC = {("starcap", "blue"): "blue-gold", ("berry-shrub", "blue"): "red-berry"}


def rows(archive, number):
    ns = {"m": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    shared = ["".join(si.itertext()) for si in ET.fromstring(
        archive.read("xl/sharedStrings.xml")).findall("m:si", ns)]
    result = {}
    for row in ET.fromstring(archive.read(f"xl/worksheets/sheet{number}.xml")).findall(
            "m:sheetData/m:row", ns):
        cells = {}
        for cell in row.findall("m:c", ns):
            value = cell.find("m:v", ns)
            if value is not None:
                text = value.text
                cells[re.sub(r"\d", "", cell.attrib["r"])] = (
                    shared[int(text)] if cell.attrib.get("t") == "s" else text)
        result[int(row.attrib["r"])] = cells
    return result


def decimal(value):
    return format(Decimal(value).quantize(Decimal("0.000001")).normalize(), "f")


def compile_release():
    with zipfile.ZipFile(SOURCE) as archive:
        plants, skills = rows(archive, 1), rows(archive, 2)
    manifests = {}
    for path in sorted((ROOT / "assets").glob("*/v1/*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        if "speciesId" in data:
            manifests[re.sub(r"[^a-z0-9]", "", data["speciesId"])] = (path, data)
    species = []
    for number in range(7, 37):
        row = plants[number]
        path, manifest = manifests[row["P"]]
        identity = manifest["speciesId"]
        weights = json.loads(re.sub(r'([\w -]+):', r'"\1":', row["Q"]))
        weights = {SPECIFIC.get((identity, k), ALIASES.get(k, k)): int(Decimal(str(v))*10000)
                   for key, v in weights.items() for k in [key.strip()]}
        assert set(weights) == set(manifest["variantIds"]), (identity, weights)
        assert sum(weights.values()) == 10000
        multipliers = json.loads(row["N"])
        conversions = {}
        for metric in multipliers:
            normalization = {"steps": "1000", "walking_running_distance_km": "0.7",
                             "active_energy_kcal": "30", "flights_climbed": "15"}.get(metric, "10")
            conversions[metric] = {"normalisation": normalization, "water_micro_units": 10000000}
        effects = []
        for skill_number in range(7, 29):
            skill = skills[skill_number]
            key = skill["A"]
            if key != row["O"]:
                continue
            scope = skill["D"]
            metric = skill["E"] if skill["E"] != "None" else None
            target = skill["F"]
            recipients = {"whispering_welcome": {"tags": ["herb"]},
                          "nurse_canopy": {"stages": ["sprout", "seedling"]},
                          "humble_company": {"tags": ["common"]},
                          "scarlet_invitation": {"tags": ["flowering"]},
                          "root_network": {"tags": ["tree"]},
                          "understory_accord": {"tags": ["understory"]}}.get(key)
            magnitude = {"type": "fixed", "value": decimal(skill["I"])}
            if key == "sleeping_dew":
                magnitude["value"] = "0.08"
            selectors = {"gathering_dew": {"species": ["dewfern"]},
                         "golden_swirl": {"tags": ["tree"]}, "forest_chorus": {}}
            if key in selectors:
                magnitude = {"type": "per_species" if key == "forest_chorus" else "per_copy",
                             "value": decimal(skill["J"]), "maximum": decimal(skill["L"]),
                             "selector": selectors[key]}
            if key == "sweet_ascent":
                magnitude = {"type": "daily_flights", "value": "0.01", "maximum": "0.1"}
            effect = {"componentVersion": 2, "id": key + "_" + scope,
                      "name": skill["B"], "description": COPY[key],
                      "system": "growth" if scope in {"activity", "water"} else "visitors",
                      "scope": scope, "metric": metric, "target": target,
                      "recipients": recipients, "magnitude": magnitude,
                      "stackingGroup": "moonwillow_sleeping_dew" if key == "sleeping_dew" else "skill_"+key}
            if key in {"first_drops", "sapphire_stride"}:
                effect["stepBand"] = "first_2000" if key == "first_drops" else "after_2000"
            expanded = []
            if metric == "workout_minutes.*":
                expanded = [{**effect, "id": effect["id"]+"_"+kind,
                             "metric": "workout_minutes."+kind} for kind in WORKOUTS]
            else:
                expanded = [effect]
            effects.extend(expanded)
            conditional = {"dewlit_path": {"species": ["heartleaf"]},
                           "root_network": {"tags": ["groundcover"]},
                           "understory_accord": {"tags": ["tree"]}}
            if key in conditional:
                effects.append({**effect, "id": effect["id"]+"_companion",
                                "condition": {"selector": conditional[key]},
                                "magnitude": {"value": decimal(skill["K"])}})
        species.append({"id": identity, "name": "Moonwillow" if identity == "moonwillow" else row["A"],
                        "rarity": row["B"].lower(), "description": row["R"],
                        "radius": decimal(row["E"]), "tags": row["D"].split(", "),
                        "attraction": {s: int(Decimal(plants[number][col]).quantize(
                            Decimal("0.000001"))*1000000) for s, col in zip(STAGES, "FGHI")},
                        "growth": {s: int(Decimal(plants[number][col]))*1000000
                                   for s, col in zip(STAGES, "JKLM")},
                        "behaviour": {"schemaVersion": 3, "metricMultipliers": multipliers,
                                      "conditionalModifiers": [], "gardenEffects": effects,
                                      "conversionRates": conversions},
                        "variants": weights, "assets": manifest["assets"], "assetManifest": path.relative_to(ROOT).as_posix()})
    return {"version": "woodland-v1", "packVersion": 20,
            "sourceSha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(), "species": species,
            "packs": [{"id": "woodland", "name": "Standard Woodland", "currency": "tokens",
                       "cost": 1200, "weights": [7500, 2000, 450, 50]},
                      {"id": "select-woodland", "name": "Enchanted Woodland", "currency": "tokens",
                       "cost": 4800, "weights": [1000, 6000, 2700, 300]},
                      {"id": "premium-woodland", "name": "Premium Woodland", "currency": "gems",
                       "cost": 5, "weights": [100, 400, 7500, 2000]}]}


if __name__ == "__main__":
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(compile_release(), ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    print("Compiled 30-species Woodland release")
