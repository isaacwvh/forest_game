"""Read-only bench package and real HTTP item contract verification; no Apple SDK claim."""

import hashlib
import json
import math
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def validate():
    package = ROOT / "assets/items/wooden-bench/v1"
    manifest = json.loads((package / "item-manifest.json").read_text(encoding="utf-8"))
    assert manifest["assetKind"] == "item" and manifest["exportUpAxis"] == "Y"
    assert manifest["units"] == "metres" and manifest["animation"] is None
    assert abs(manifest["bounds"]["min"][1]) < 0.00001
    assert math.hypot(0.8, 0.31) < 0.9, "Solid footprint must fit every rotation"
    for asset in manifest["assets"]:
        path = (package / asset["file"]).resolve()
        assert path.is_relative_to(package.resolve())
        data = path.read_bytes()
        assert len(data) == asset["bytes"]
        assert hashlib.sha256(data).hexdigest() == asset["sha256"]
        if path.suffix == ".usdz":
            with zipfile.ZipFile(path) as archive:
                assert archive.testzip() is None
                for entry in archive.infolist():
                    assert entry.compress_type == zipfile.ZIP_STORED
                    assert not entry.filename.startswith("/") and ".." not in Path(entry.filename).parts
                    header = struct.unpack("<4s5H3I2H", data[entry.header_offset:entry.header_offset + 30])
                    assert (entry.header_offset + 30 + header[-2] + header[-1]) % 64 == 0
        else:
            assert data[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack(">IIBB", data[16:26]) == (384, 448, 8, 6)
    fixture = json.loads((ROOT / "frontend/MovementForest/Resources/Fixtures/items-contract.json").read_text())
    stored = fixture["storedInventory"]
    assert stored["capacity"] == {"ownedItems": 2, "placedItems": 0, "storedItems": 2, "itemLimit": 50}
    assert len({v["ownedItemId"] for v in stored["items"]}) == 2
    for item in stored["items"]:
        assert item["description"] == "a basic bench, allows weary travelers to find rest in your garden"
        for key in ("modelKey", "thumbnailKey"):
            assert (ROOT / item[key]).is_file()
        assert item["clearanceRadius"] == 0.9
    placed = fixture["placeResult"]["garden"]
    assert len(placed["items"]) == 1 and placed["plants"] == []
    assert placed["items"][0]["placement"]["rotationDegrees"] == 90
    assert placed["totalAttractionMicroUnits"] == "0"
    assert fixture["storeResult"]["garden"]["items"] == []
    commerce = json.loads((ROOT / "frontend/MovementForest/Resources/Fixtures/item-commerce-contract.json").read_text())
    offer = commerce["summary"]["itemOffers"][0]
    assert offer["tokenCost"] == "550" and offer["itemId"] == "wooden-bench"
    assert all((ROOT / offer[key]).is_file() for key in ("modelKey", "thumbnailKey"))
    assert commerce["purchase"]["quantity"] == 2 and commerce["purchase"]["tokensSpent"] == "1100"
    assert len(set(commerce["purchase"]["ownedItemIds"])) == 2
    assert commerce["quote"]["tokenValue"] == "550" and commerce["quote"]["tokens"] == "137"
    assert commerce["sale"]["ownedItemId"] in commerce["purchase"]["ownedItemIds"]
    assert commerce["sale"]["tokenBalance"] == "1037" and commerce["sale"]["itemCapacity"]["ownedItems"] == 1
    project = (ROOT / "frontend/MovementForest.xcodeproj/project.pbxproj").read_text()
    assert "../assets/items/wooden-bench" in project
    assert "../assets/items/wooden-bench-v1.zip" not in project
    print("PASS: bench assets, footprint, alpha icon, bundle inclusion, HTTP placement, 550-token purchases and 137-token resale contract.")


if __name__ == "__main__":
    validate()
