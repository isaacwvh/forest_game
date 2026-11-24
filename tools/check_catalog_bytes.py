"""Check canonical catalogue bytes in the working tree AND Git index."""

import hashlib
import json
import subprocess
from pathlib import Path

ASSET = "assets/journal/v1/catalog-descriptions.json"
MANIFEST = "assets/journal/v1/journal.json"


def check(data, manifest, label):
    expected = json.loads(manifest)["catalogDescriptions"]
    if b"\r" in data or len(data) != expected["bytes"] or hashlib.sha256(data).hexdigest() != expected["sha256"]:
        raise SystemExit(f"{label}: catalogue bytes must be LF and match the manifest")


def main():
    check(Path(ASSET).read_bytes(), Path(MANIFEST).read_bytes(), "Working tree")
    check(
        subprocess.check_output(["git", "show", f":{ASSET}"]),
        subprocess.check_output(["git", "show", f":{MANIFEST}"]),
        "Git index",
    )
    print("PASS: working tree and Git index contain the approved LF catalogue bytes")


if __name__ == "__main__":
    main()
