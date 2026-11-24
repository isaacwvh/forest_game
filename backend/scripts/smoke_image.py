"""Exercise the shipped image on a private disposable Docker network."""

import argparse
import json
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from uuid import uuid4


def docker(*args, **kwargs):
    return (
        subprocess.check_output(["docker", *args], stderr=subprocess.STDOUT, **kwargs)
        .decode()
        .strip()
    )


def http(base, path, *, method="GET", expected=200, body=None, headers=None):
    request = urllib.request.Request(
        base + path,
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Content-Type": "application/json", **(headers or {})},
    )
    try:
        response = urllib.request.urlopen(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        body = json.load(response)
        if response.code != expected:
            raise AssertionError(f"{path}: expected {expected}, received {response.code}")
        return body


def run(image):
    prefix = "forest-image-" + uuid4().hex[:12]
    network, database = prefix + "-net", prefix + "-db"
    names = [database, prefix + "-api", prefix + "-worker"]
    admin = "postgresql+psycopg://forest:ci-admin-only@db:5432/postgres"
    runtime = "postgresql+psycopg://forest_runtime:ci-runtime-only@db:5432/postgres"
    common = [
        "--network",
        network,
        "--env",
        "FOREST_ENVIRONMENT=test",
        "--env",
        "FOREST_AUTH_MODE=development",
        "--env",
        "FOREST_DEV_AUTH_SECRET=container-smoke-only-secret-32-characters",
        "--env",
        "FOREST_DB_POOL_SIZE=1",
        "--env",
        "FOREST_DB_MAX_OVERFLOW=0",
    ]

    def operator(*args):
        return docker(
            "run",
            "--rm",
            *common,
            "--env",
            "FOREST_DATABASE_URL=" + admin,
            image,
            "python",
            "scripts/cloud.py",
            *args,
        )

    docker("network", "create", network)
    try:
        docker(
            "run",
            "--detach",
            "--name",
            database,
            "--network",
            network,
            "--network-alias",
            "db",
            "--publish",
            "127.0.0.1::5432",
            "--env",
            "POSTGRES_USER=forest",
            "--env",
            "POSTGRES_PASSWORD=ci-admin-only",
            "postgres:17-bookworm",
        )
        for attempt in range(60):
            try:
                docker("exec", database, "pg_isready", "-h", "127.0.0.1", "-U", "forest")
                break
            except subprocess.CalledProcessError:
                if attempt == 59:
                    raise
                time.sleep(0.5)
        docker(
            "exec",
            database,
            "psql",
            "-U",
            "forest",
            "-d",
            "postgres",
            "-v",
            "ON_ERROR_STOP=1",
            "-c",
            "CREATE ROLE anon; CREATE ROLE authenticated; CREATE ROLE service_role; "
            "CREATE ROLE forest_runtime LOGIN PASSWORD 'ci-runtime-only';",
        )
        operator("migrate", "--bootstrap-stopped")
        docker(
            "run",
            "--rm",
            *common,
            "--env",
            "FOREST_DATABASE_URL=" + admin,
            image,
            "forest",
            "seed-dev",
        )
        urls = []
        for name, factory in zip(
            names[1:],
            ["forest_api.main:create_app", "forest_api.worker_app:create_app"],
            strict=True,
        ):
            docker(
                "run",
                "--detach",
                "--name",
                name,
                *common,
                "--publish",
                "127.0.0.1::8000",
                "--env",
                "FOREST_DATABASE_URL=" + runtime,
                image,
                "uvicorn",
                factory,
                "--factory",
                "--host",
                "0.0.0.0",
                "--port",
                "8000",
                "--no-access-log",
            )
            port = docker("port", name, "8000/tcp").rsplit(":", 1)[1]
            base = "http://127.0.0.1:" + port
            urls.append(base)
            for attempt in range(60):
                try:
                    http(base, "/health/live")
                    break
                except (OSError, ValueError, AssertionError):
                    if attempt == 59:
                        raise
                    time.sleep(0.5)
        api, worker = urls
        http(api, "/health/ready")
        http(api, "/v1/me", expected=503)
        assert http(worker, "/tasks/history", method="POST")["reason"] == "maintenance"
        operator("maintenance", "off")
        http(api, "/v1/me", expected=401)
        from forest_api.auth import issue_development_token
        from forest_api.config import Settings

        token = issue_development_token(
            Settings(
                _env_file=None,
                environment="test",
                database_url=admin,
                auth_mode="development",
                dev_auth_secret="container-smoke-only-secret-32-characters",
            ),
            "image-smoke",
        )
        authorization = {"Authorization": "Bearer " + token}
        http(
            api,
            "/v1/accounts",
            method="POST",
            headers=authorization,
            body={
                "requestId": str(uuid4()),
                "username": "image_smoke",
                "displayName": "Image Smoke",
                "gameTimezone": "UTC",
            },
        )
        http(api, "/v1/me", headers=authorization)
        # Unknown paths return FastAPI's JSON 404, not task execution on the API.
        http(api, "/tasks/history", method="POST", expected=404)
        assert http(worker, "/tasks/shop", method="POST")["status"] == "ready"
        assert http(worker, "/tasks/history", method="POST")["status"] == "ok"
        assert http(worker, "/tasks/history", method="POST")["status"] == "ok"
        operator("maintenance", "on", "--release", "image-smoke")
        http(api, "/health/ready")
        http(api, "/v1/me", expected=503)
        assert http(worker, "/tasks/shop", method="POST")["reason"] == "maintenance"
        port = docker("port", database, "5432/tcp").rsplit(":", 1)[1]
        import os

        environment = dict(os.environ)
        environment["FOREST_DATABASE_URL"] = (
            "postgresql+psycopg://forest:ci-admin-only@127.0.0.1:" + port + "/postgres"
        )
        with tempfile.TemporaryDirectory(prefix="forest-backup-smoke-") as output:
            subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("backup.py")),
                    "--output",
                    output,
                    "--release",
                    "image-smoke",
                    "--local-only",
                    "--allow-local-test",
                    "--source-container",
                    database,
                ],
                env=environment,
                check=True,
            )
        print(
            "PASS: built image migrations/grants, restricted runtime, health, "
            "API/worker separation, passes and maintenance"
        )
    except Exception:
        for name in names[1:]:
            try:
                print(docker("logs", "--tail", "50", name))
            except subprocess.CalledProcessError:
                pass
        raise
    finally:
        for name in reversed(names):
            subprocess.run(
                ["docker", "rm", "--force", "--volumes", name], capture_output=True, check=False
            )
        subprocess.run(["docker", "network", "rm", network], capture_output=True, check=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    run(parser.parse_args().image)
