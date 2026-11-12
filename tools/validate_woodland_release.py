"""Read-only release, resource-size and pack-economy verification."""

import hashlib
import json
import struct
from collections import Counter
from fractions import Fraction
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def validate():
    data = json.loads((ROOT / "backend/src/forest_api/data/woodland-v1.json").read_text(encoding="utf-8"))
    assert len(data["species"]) == 30
    assert Counter(p["rarity"] for p in data["species"]) == {
        "common": 10, "rare": 10, "epic": 7, "legendary": 3}
    index = json.loads((ROOT / "frontend/MovementForest/Resources/Fixtures/asset-index.json").read_text())
    assert set(index) == {p["id"] for p in data["species"]}
    selected = set()
    for plant in data["species"]:
        manifest_path = ROOT / plant["assetManifest"]
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert plant["assets"] == manifest["assets"]
        assert set(plant["variants"]) == set(manifest["variantIds"])
        assert sum(plant["variants"].values()) == 10000
        selected.add(manifest_path)
        for asset in manifest["assets"]:
            model = manifest_path.parent / asset["file"]
            thumb = manifest_path.parent / asset["thumbnail"]
            assert model.stat().st_size == asset["bytes"]
            assert hashlib.sha256(model.read_bytes()).hexdigest() == asset["sha256"]
            assert struct.unpack(">II", thumb.read_bytes()[16:24]) == (384, 448)
            selected.update((model, thumb))
    plant_size = sum(p.stat().st_size for p in selected)
    for pack in data["packs"]:
        assert sum(pack["weights"]) == 10000 and min(pack["weights"]) > 0
        dimensions = []
        for part in ("sealed", "opened", "top-strip"):
            path = ROOT / f"assets/packs/{pack['id']}/v1/{pack['id']}-pack-{part}.png"
            assert path.is_file()
            dimensions.append(struct.unpack(">II", path.read_bytes()[16:24]))
            selected.add(path)
        assert dimensions[0] == dimensions[1]
        fresh, adult = Fraction(0), Fraction(0)
        for rarity, chance, base in zip(("common", "rare", "epic", "legendary"), pack["weights"],
                                      (240, 480, 720, 960), strict=True):
            species = [p for p in data["species"] if p["rarity"] == rarity]
            for plant in species:
                for variant, weight in plant["variants"].items():
                    multiplier = {("oak", "blue"): 12500, ("oak", "vined"): 15000,
                                  ("moonwillow", "golden"): 15000}.get((plant["id"], variant), 10000)
                    probability = Fraction(chance, 10000*len(species))*Fraction(weight, 10000)
                    fresh += probability*(base*multiplier//40000)
                    adult += probability*(base*multiplier//20000)
        print(f"PASS {pack['name']}: {pack['cost']} {pack['currency']}; "
              f"variant-weighted resale {float(fresh):.3f} sprout / {float(adult):.3f} adult tokens")
    for folder in ("butterfly", "garden-environment", "quantity-icons-v1/png-128", "journal/v1"):
        selected.update(p for p in (ROOT / "assets" / folder).rglob("*") if p.suffix in {".json", ".png", ".usdz"})
    print(f"PASS 30 species, 47 variants, 188 models and thumbnails: {plant_size/1e6:.2f} MB plants; "
          f"{sum(p.stat().st_size for p in selected)/1e6:.2f} MB selected resources")


if __name__ == "__main__":
    validate()
