"""Select expensive validation without leaving required workflows pending."""

import json
import os
import subprocess
from pathlib import Path

BACKEND = ("backend/", "assets/", "spec_examples/", "frontend/MovementForest/Resources/Fixtures/")
FRONTEND = (
    "frontend/", "assets/", "spec_examples/placement-cases.json", "tools/validate_items.py",
    "backend/src/forest_api/catalog_copy.py", "backend/src/forest_api/launch_balance.py",
    "backend/src/forest_api/data/",
)
COMMON = (".gitattributes", "tools/ci_changes.py", "tools/check_catalog_bytes.py")


def selected(paths, component):
    prefixes = BACKEND if component == "backend" else FRONTEND
    return any(p.startswith(prefixes + COMMON + (f".github/workflows/{component}.yml",)) for p in paths)


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if os.environ["GITHUB_EVENT_NAME"] == "workflow_dispatch":
        paths = None
    else:
        pr = event.get("pull_request")
        base = pr["base"]["sha"] if pr else event.get("before", "")
        head = pr["head"]["sha"] if pr else os.environ["GITHUB_SHA"]
        if not base or set(base) == {"0"}:
            paths = None
        else:
            try:
                paths = subprocess.check_output(
                    ["git", "diff", "--name-only", "-z", base, head]
                ).decode().split("\0")
            except subprocess.CalledProcessError:
                paths = None  # Fail open to validation if a force-push removed the base.
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        for component in ("backend", "frontend"):
            needed = paths is None or selected(paths, component)
            output.write(f"{component}={str(needed).lower()}\n")


if __name__ == "__main__":
    main()
