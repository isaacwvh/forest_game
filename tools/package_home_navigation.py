"""Package the five approved Home concepts; masters stay outside the app bundle."""
from pathlib import Path
import hashlib
import json
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "output/concepts/home-floating-v3/sources"
TARGET = ROOT / "assets/home-navigation/v1"
NAMES = ["shop", "catalog", "packs", "milestones", "expedition"]


def main():
    TARGET.mkdir(parents=True, exist_ok=True)
    entries = []
    for name in NAMES:
        source = SOURCE / f"{name}.png"
        with Image.open(source) as original:
            assert original.mode == "RGBA", f"Missing transparency: {source}"
            image = original.resize((128, 128), Image.Resampling.LANCZOS)
            assert image.getchannel("A").getextrema() == (0, 255)
            destination = TARGET / f"{name}.png"
            image.save(destination, optimize=True)
        data = destination.read_bytes()
        entries.append({"id": name, "file": destination.name, "width": 128, "height": 128,
                        "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                        "sourceSha256": hashlib.sha256(source.read_bytes()).hexdigest()})
    (TARGET / "manifest.json").write_text(json.dumps({"version": 1, "icons": entries}, indent=2) + "\n", encoding="utf-8")
    print(f"Packaged {len(entries)} transparent Home navigation icons ({sum(x['bytes'] for x in entries):,} bytes).")


if __name__ == "__main__":
    main()
