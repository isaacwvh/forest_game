"""Windows validation using a dedicated test cluster; never loads the game .env.

Run from repo root. Requires bundled .local-postgres tools/cluster. Additional
arguments select pytest tests; --smoke additionally runs real HTTP walkthroughs.
"""

import os
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[2]
pg_ctl = root / "backend/.local-postgres/pgsql/bin/pg_ctl.exe"
cluster = root / "backend/.local-postgres/b6-validation"
environment = dict(os.environ)
environment["FOREST_TEST_DATABASE_URL"] = (
    "postgresql+psycopg://forest@127.0.0.1:55437/postgres?connect_timeout=5"
)
args = sys.argv[1:]
smoke = "--smoke" in args
export = "--export-frontend-contract" in args
args = [arg for arg in args if arg not in {"--smoke", "--export-frontend-contract"}]
subprocess.run(
    [
        str(pg_ctl),
        "start",
        "-D",
        str(cluster),
        "-l",
        str(cluster / "validation.log"),
        "-o",
        "-p 55437 -h 127.0.0.1",
        "-w",
    ],
    check=True,
)
try:
    result = subprocess.run(
        [sys.executable, "-m", "pytest", *(args or ["backend/tests", "-q"])],
        cwd=root,
        env=environment,
    )
    if result.returncode:
        sys.exit(result.returncode)
    if smoke:
        for script in ("smoke_activity.py", "smoke_visitors.py"):
            subprocess.run(
                [
                    sys.executable,
                    str(root / "backend/scripts" / script),
                    *(
                        ["--export-frontend-contract"]
                        if export and script == "smoke_visitors.py"
                        else []
                    ),
                ],
                cwd=root,
                env=environment,
                check=True,
            )
finally:
    subprocess.run([str(pg_ctl), "stop", "-D", str(cluster), "-m", "fast", "-w"], check=True)
