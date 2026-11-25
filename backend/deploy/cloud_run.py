"""Reviewable Cloud Run release stages. Prints commands unless --execute is supplied.

Project, identities, secrets, IAM and Artifact Registry are provisioned separately.
See backend/CLOUD_RUN.md for the first cutover and subsequent release order.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from smoke_hosted import run as hosted_smoke  # noqa: E402

SCHEMA = "0023_cloud_runtime"


def configuration(path):
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    required = json.loads(Path(__file__).with_name("production.example.json").read_text())
    if set(config) != set(required):
        raise ValueError("Configuration keys must match production.example.json")
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", config["project"]):
        raise ValueError("Invalid project ID")
    if config["region"] != "asia-southeast1":
        raise ValueError("This release configuration is scoped to Singapore")
    for key, value in config.items():
        if key.endswith("_version"):
            valid = re.fullmatch(r"[1-9][0-9]*", value)
        elif key.endswith("_account"):
            valid = re.fullmatch(
                r"[a-z][a-z0-9-]+@" + re.escape(config["project"]) + r"\.iam\.gserviceaccount\.com",
                value,
            )
        elif key.startswith("auth_"):
            valid = re.fullmatch(r"https://[a-z0-9.-]+/[a-zA-Z0-9/._-]+", value)
        else:
            valid = re.fullmatch(r"[a-z][a-z0-9-]+", value)
        if not valid:
            raise ValueError("Invalid configuration field: " + key)
    if (
        len(
            {
                config[k]
                for k in ("api_account", "worker_account", "migration_account", "scheduler_account")
            }
        )
        != 4
    ):
        raise ValueError("Use separate service identities")
    if config["runtime_secret"] == config["migration_secret"]:
        raise ValueError("Runtime and migration credentials must be separate")
    if config["auth_jwks_url"] != config["auth_issuer"] + "/.well-known/jwks.json":
        raise ValueError("JWKS URL does not match the issuer")
    return config


def base(config):
    return [shutil.which("gcloud") or "gcloud", "--project=" + config["project"], "--quiet"]


def secrets(config, privileged=False):
    kind = "migration" if privileged else "runtime"
    return (
        "--set-secrets=FOREST_DATABASE_URL="
        + config[kind + "_secret"]
        + ":"
        + config[kind + "_version"]
        + ",/etc/forest-db/ca.crt="
        + config["ca_secret"]
        + ":"
        + config["ca_version"]
    )


def environment(config, commit, worker=False):
    values = {
        "FOREST_ENVIRONMENT": "production",
        "FOREST_AUTH_MODE": "jwks",
        "FOREST_AUTH_ISSUER": config["auth_issuer"],
        "FOREST_AUTH_AUDIENCE": "authenticated",
        "FOREST_AUTH_JWKS_URL": config["auth_jwks_url"],
        "FOREST_AUTH_ALGORITHM": "ES256",
        "FOREST_DB_POOL_SIZE": "1" if worker else "2",
        "FOREST_DB_MAX_OVERFLOW": "0",
        "FOREST_DB_POOL_TIMEOUT_SECONDS": "3",
        "FOREST_DB_STATEMENT_TIMEOUT_MS": "15000",
        "FOREST_DB_LOCK_TIMEOUT_MS": "3000",
        "FOREST_MAINTENANCE_GATE_ENABLED": "true",
        "FOREST_RELEASE_COMMIT": commit,
        "FOREST_WORKER_BUDGET_SECONDS": "40",
        "FOREST_OPERATION_METRICS_ENABLED": "true",
    }
    if worker:
        values.update(
            FOREST_MAINTENANCE_RESPONSES_ENABLED="true",
            FOREST_MAINTENANCE_VISITORS_ENABLED="true",
            FOREST_MAINTENANCE_GROWTH_ENABLED="true",
            FOREST_MAINTENANCE_BATCH_LIMIT="500",
        )
    return "--set-env-vars=" + ",".join(k + "=" + v for k, v in values.items())


def job(config, image, commit, suffix, args, *, privileged):
    return base(config) + [
        "run",
        "jobs",
        "deploy",
        "forest-" + suffix,
        "--region=" + config["region"],
        "--image=" + image,
        "--service-account=" + config["migration_account" if privileged else "api_account"],
        "--tasks=1",
        "--parallelism=1",
        "--max-retries=0",
        "--task-timeout=300s",
        "--cpu=1",
        "--memory=512Mi",
        "--command=python",
        "--args=scripts/cloud.py," + ",".join(args),
        secrets(config, privileged),
        environment(config, commit),
    ]


def execute_job(config, suffix, *args):
    result = base(config) + [
        "run",
        "jobs",
        "execute",
        "forest-" + suffix,
        "--region=" + config["region"],
        "--wait",
    ]
    if args:
        result.append("--args=scripts/cloud.py," + ",".join(args))
    return result


def commands(config, image, commit, action, *, first_deploy=False, bootstrap_stopped=False):
    region = "--region=" + config["region"]
    if action == "jobs":
        return [
            job(
                config, image, commit, "migrate", ["migrate", "--release", commit], privileged=True
            ),
            job(config, image, commit, "control", ["maintenance", "status"], privileged=True),
            job(config, image, commit, "preflight", ["preflight"], privileged=False),
            job(config, image, commit, "prepare-shop", ["prepare-shop"], privileged=True),
        ]
    if action in {"pause", "resume"}:
        return [
            base(config)
            + ["scheduler", "jobs", action, config[k], "--location=" + config["region"]]
            for k in ("history_schedule", "shop_schedule")
        ]
    if action in {"gate-on", "gate-off"}:
        return [
            execute_job(
                config,
                "control",
                "maintenance",
                "on" if action == "gate-on" else "off",
                "--release",
                commit,
            )
        ]
    if action == "migrate":
        return [
            execute_job(
                config,
                "migrate",
                "migrate",
                "--release",
                commit,
                *(["--bootstrap-stopped"] if bootstrap_stopped else []),
            )
        ]
    if action == "prepare-shop":
        return [execute_job(config, "prepare-shop")]
    if action == "verify":
        return [execute_job(config, "preflight", "preflight", "--allow-maintenance")]
    if action == "deploy":
        result = []
        for worker in (False, True):
            service = config["worker_service" if worker else "api_service"]
            cmd = base(config) + [
                "run",
                "deploy",
                service,
                region,
                "--image=" + image,
                "--service-account=" + config["worker_account" if worker else "api_account"],
                "--port=8000",
                "--cpu=1",
                "--memory=512Mi",
                "--cpu-throttling",
                "--min=0",
                "--max=1",
                "--concurrency=" + ("1" if worker else "4"),
                "--timeout=" + ("60s" if worker else "30s"),
                "--ingress=all",
                "--invoker-iam-check",
                "--no-allow-unauthenticated" if worker else "--allow-unauthenticated",
                "--command=uvicorn",
                "--args="
                + ("forest_api.worker_app:create_app" if worker else "forest_api.main:create_app")
                + ",--factory,--host,0.0.0.0,--port,8000,--no-access-log",
                "--startup-probe=httpGet.path="
                + ("/health/live" if worker else "/health/ready")
                + ",httpGet.port=8000,timeoutSeconds=8,periodSeconds=10,failureThreshold=12",
                "--liveness-probe=httpGet.path=/health/live,httpGet.port=8000,timeoutSeconds=2,periodSeconds=30,failureThreshold=3",
                "--tag=release-" + commit[:12],
                "--labels=commit=" + commit,
                secrets(config),
                environment(config, commit, worker),
            ]
            if not first_deploy:
                cmd.append("--no-traffic")
            result.append(cmd)
        return result
    if action == "promote":
        return [
            base(config)
            + [
                "run",
                "services",
                "update-traffic",
                config[k],
                region,
                "--to-tags=release-" + commit[:12] + "=100",
            ]
            for k in ("api_service", "worker_service")
        ]
    raise ValueError("Unknown release action")


def backup_receipt(path, commit, *, allow_local_backup=False):
    receipt = json.loads(Path(path).read_text())
    created = datetime.fromisoformat(receipt["createdAt"])
    now = datetime.now(UTC)
    if (
        receipt.get("verifiedRestore") is not True
        or receipt.get("release") != commit
        or not (
            str(receipt.get("offsite", "")).startswith("gs://")
            or (allow_local_backup and receipt.get("offsite") is None)
        )
        or not re.fullmatch(r"[a-f0-9]{64}", receipt.get("sha256", ""))
        or not timedelta(0) <= now - created <= timedelta(hours=6)
    ):
        raise ValueError(
            "Require a recent, restored backup for this release and either verified off-site "
            "storage or explicit --allow-local-backup"
        )
    archive = Path(path).with_name(receipt["archive"])
    import hashlib

    with archive.open("rb") as data:
        if hashlib.file_digest(data, "sha256").hexdigest() != receipt["sha256"]:
            raise ValueError("Backup archive differs from its receipt")
    return receipt


def invoke(command):
    subprocess.run(command, check=True)


def verify_image(image, commit):
    subprocess.run(["docker", "pull", "--quiet", image], check=True)
    metadata = json.loads(subprocess.check_output(["docker", "image", "inspect", image]))[0]
    if (
        metadata.get("Os") != "linux"
        or metadata.get("Architecture") != "amd64"
        or metadata.get("Config", {}).get("Labels", {}).get("org.opencontainers.image.revision")
        != commit
    ):
        raise ValueError(
            "The immutable image must be Linux amd64 and labeled with the tested commit"
        )


def service(config, key):
    return json.loads(
        subprocess.check_output(
            base(config)
            + [
                "run",
                "services",
                "describe",
                config[key],
                "--region=" + config["region"],
                "--format=json",
            ]
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=[
            "jobs",
            "pause",
            "gate-on",
            "migrate",
            "deploy",
            "prepare-shop",
            "verify",
            "promote",
            "open",
            "resume",
        ],
    )
    parser.add_argument("--config", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--first-deploy", action="store_true")
    parser.add_argument("--bootstrap-stopped", action="store_true")
    parser.add_argument("--backup-receipt")
    parser.add_argument(
        "--allow-local-backup",
        action="store_true",
        help="Accept a restore-verified local receipt for migration without a cloud backup copy",
    )
    parser.add_argument("--expected-user-id")
    parser.add_argument("--record", type=Path)
    args = parser.parse_args()
    config = configuration(args.config)
    if not re.fullmatch(r"[a-f0-9]{40}", args.commit):
        parser.error("Use the full tested commit SHA")
    pattern = (
        re.escape(config["region"] + "-docker.pkg.dev/" + config["project"])
        + r"/[a-z0-9/_-]+@sha256:[a-f0-9]{64}"
    )
    if not re.fullmatch(pattern, args.image):
        parser.error("Use an immutable Artifact Registry digest in this project and region")
    if args.action == "open" and not args.execute:
        print(
            json.dumps(
                {
                    "steps": [
                        "production preflight",
                        "gate off",
                        "real-token hosted smoke; close gate if it fails",
                    ]
                }
            )
        )
        return
    planned = (
        []
        if args.action == "open"
        else commands(
            config,
            args.image,
            args.commit,
            args.action,
            first_deploy=args.first_deploy,
            bootstrap_stopped=args.bootstrap_stopped,
        )
    )
    print(
        json.dumps(
            {
                "action": args.action,
                "commit": args.commit,
                "image": args.image,
                "schema": SCHEMA,
                "execute": args.execute,
                "commands": planned,
            },
            indent=2,
        )
    )
    if not args.execute:
        return
    verify_image(args.image, args.commit)
    verified_backup = None
    if args.action == "migrate":
        if not args.backup_receipt:
            parser.error("Migration requires --backup-receipt")
        verified_backup = backup_receipt(
            args.backup_receipt, args.commit, allow_local_backup=args.allow_local_backup
        )
    if args.action in {"promote", "open", "resume"}:
        invoke(
            execute_job(
                config,
                "preflight",
                "preflight",
                *([] if args.action == "resume" else ["--allow-maintenance"]),
            )
        )
    try:
        if args.action == "open":
            if not os.environ.get("FOREST_SMOKE_ACCESS_TOKEN") or not args.expected_user_id:
                raise ValueError(
                    "Supply a real smoke token and --expected-user-id before reopening"
                )
            invoke(commands(config, args.image, args.commit, "gate-off")[0])
            hosted_smoke(
                service(config, "api_service")["status"]["url"],
                token=os.environ["FOREST_SMOKE_ACCESS_TOKEN"],
                expected_user=args.expected_user_id,
            )
        else:
            for cmd in planned:
                invoke(cmd)
        if args.action == "deploy":
            policy = json.loads(
                subprocess.check_output(
                    base(config)
                    + [
                        "run",
                        "services",
                        "get-iam-policy",
                        config["worker_service"],
                        "--region=" + config["region"],
                        "--format=json",
                    ]
                )
            )
            if any(
                member in {"allUsers", "allAuthenticatedUsers"}
                for binding in policy.get("bindings", [])
                for member in binding.get("members", [])
            ):
                raise ValueError("Worker IAM includes a public principal")
        if args.action == "verify":
            candidate = next(
                t["url"]
                for t in service(config, "api_service")["status"]["traffic"]
                if t.get("tag") == "release-" + args.commit[:12]
            )
            hosted_smoke(candidate, mode="maintenance")
        if args.action == "resume":
            for name in (config["history_schedule"], config["shop_schedule"]):
                invoke(
                    base(config)
                    + ["scheduler", "jobs", "run", name, "--location=" + config["region"]]
                )
            print(
                "Verify both forced Scheduler attempts in Cloud Logging; "
                "their execution is asynchronous."
            )
        if args.record:
            record = {
                "action": args.action,
                "commit": args.commit,
                "image": args.image,
                "schema": SCHEMA,
                "completedAt": datetime.now(UTC).isoformat(),
            }
            if verified_backup is not None:
                record["backup"] = {
                    "receipt": str(Path(args.backup_receipt).resolve()),
                    "storage": "gcs" if verified_backup.get("offsite") else "local-only",
                    "sha256": verified_backup["sha256"],
                }
            if args.action in {"deploy", "promote", "open"}:
                record["services"] = {
                    k: service(config, k)["status"] for k in ("api_service", "worker_service")
                }
            args.record.parent.mkdir(parents=True, exist_ok=True)
            args.record.write_text(json.dumps(record, indent=2) + "\n")
    except Exception:
        if args.action in {"migrate", "deploy", "verify", "promote", "open", "resume"}:
            for cmd in commands(config, args.image, args.commit, "gate-on"):
                try:
                    invoke(cmd)
                except subprocess.CalledProcessError:
                    pass
            for cmd in commands(config, args.image, args.commit, "pause"):
                subprocess.run(cmd, check=False)
        raise


if __name__ == "__main__":
    main()
