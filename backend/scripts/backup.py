"""Application-only pg_dump, disposable restore verification, optional private GCS upload.

Run from a trusted operator machine with the migration URL in FOREST_DATABASE_URL.
The database must be in maintenance, or stopped for the first gate installation.
Requires Docker; off-site upload also requires an authenticated gcloud CLI.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from sqlalchemy.pool import NullPool

from forest_api import main as api_main  # noqa: F401 - complete model registry
from forest_api.maintenance import operator_connection
from forest_api.models import Base

# 17.12 understands internal column-version metadata from patched hosted servers.
CLIENT_IMAGE = "postgres:17.12-bookworm"


def command(args, **kwargs):
    return subprocess.check_output(args, stderr=subprocess.PIPE, **kwargs)


def row_sql(table):
    quoted = '"' + table.replace('"', '""') + '"'
    return (
        "SELECT digest FROM (SELECT "
        "encode(sha256(convert_to(to_jsonb(t)::text,'UTF8')),'hex') AS digest "
        f'FROM public.{quoted} t) rows ORDER BY digest COLLATE "C"'
    )


def summarize(rows):
    digest = hashlib.sha256()
    count = 0
    for row in rows:
        digest.update(row.strip().encode("ascii") + b"\n")
        count += 1
    return {"rows": count, "sha256": digest.hexdigest()}


def source_snapshot(connection, *, bootstrap_stopped, release):
    connection.execute(text("SET TRANSACTION READ ONLY"))
    connection.execute(text("SET LOCAL TIME ZONE 'UTC'"))
    connection.execute(text("SET LOCAL statement_timeout='60s'"))
    tables = set(
        connection.scalars(text("SELECT tablename FROM pg_tables WHERE schemaname='public'"))
    )
    expected = set(Base.metadata.tables) | {"alembic_version"}
    if bootstrap_stopped:
        expected.discard("runtime_control")
    if tables != expected:
        raise ValueError("Application backup table coverage differs; inspect the source schema")
    schema = connection.scalar(text("SELECT version_num FROM alembic_version"))
    if bootstrap_stopped:
        if schema != "0022_expedition_launch":
            raise ValueError("Bootstrap backup is only for the pre-control schema")
    else:
        control = connection.execute(
            text("SELECT maintenance,release FROM runtime_control WHERE id=1")
        ).one()
        if not control.maintenance or control.release != release:
            raise ValueError("Maintenance must be enabled for this release before backup")
    result = {
        table: summarize(connection.scalars(text(row_sql(table)))) for table in sorted(tables)
    }
    connection.commit()
    return schema, result


def verify_restore(archive, expected):
    name = "forest-backup-verify-" + uuid4().hex[:12]
    try:
        command(
            [
                "docker",
                "run",
                "--detach",
                "--name",
                name,
                "--network",
                "none",
                "--env",
                "POSTGRES_USER=forest",
                "--env",
                "POSTGRES_HOST_AUTH_METHOD=trust",
                CLIENT_IMAGE,
            ]
        )
        import time

        for attempt in range(60):
            try:
                command(["docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "forest"])
                break
            except subprocess.CalledProcessError:
                if attempt == 59:
                    raise
                time.sleep(0.5)
        command(
            [
                "docker",
                "exec",
                name,
                "psql",
                "-U",
                "forest",
                "-d",
                "postgres",
                "-v",
                "ON_ERROR_STOP=1",
                "-c",
                "DROP SCHEMA public CASCADE; CREATE ROLE forest_runtime;",
            ]
        )
        with archive.open("rb") as data:
            command(
                [
                    "docker",
                    "exec",
                    "--interactive",
                    name,
                    "pg_restore",
                    "-U",
                    "forest",
                    "-d",
                    "postgres",
                    "--exit-on-error",
                    "--no-owner",
                    "--no-acl",
                ],
                stdin=data,
            )
        for table, fingerprint in expected.items():
            output = (
                command(
                    [
                        "docker",
                        "exec",
                        name,
                        "psql",
                        "-X",
                        "-qAt",
                        "-U",
                        "forest",
                        "-d",
                        "postgres",
                        "-v",
                        "ON_ERROR_STOP=1",
                        "-c",
                        "SET TIME ZONE 'UTC'; " + row_sql(table),
                    ]
                )
                .decode()
                .splitlines()
            )
            if summarize(output) != fingerprint:
                raise ValueError("Restored table does not match the source fingerprint")
        actual = (
            command(
                [
                    "docker",
                    "exec",
                    name,
                    "psql",
                    "-X",
                    "-qAt",
                    "-U",
                    "forest",
                    "-d",
                    "postgres",
                    "-c",
                    "SELECT tablename FROM pg_tables WHERE schemaname='public'",
                ]
            )
            .decode()
            .splitlines()
        )
        if set(actual) != set(expected):
            raise ValueError("Restored table coverage differs")
    finally:
        # This generated name is the only resource this function removes.
        subprocess.run(
            ["docker", "rm", "--force", "--volumes", name], capture_output=True, check=False
        )


def upload(archive, report_path, bucket, release):
    if not re.fullmatch(r"gs://[a-z0-9][a-z0-9._-]+", bucket):
        raise ValueError("Specify a bucket origin, without an object path")
    metadata = json.loads(
        command(["gcloud", "storage", "buckets", "describe", bucket, "--raw", "--format=json"])
    )
    if metadata.get("iamConfiguration", {}).get("publicAccessPrevention") != "enforced":
        raise ValueError("Backup bucket must enforce public access prevention")
    if not metadata.get("iamConfiguration", {}).get("uniformBucketLevelAccess", {}).get("enabled"):
        raise ValueError("Backup bucket must enforce uniform bucket access")
    if metadata.get("versioning", {}).get("enabled"):
        raise ValueError("Disable versioning on the bounded-retention backup bucket")
    if int(metadata.get("retentionPolicy", {}).get("retentionPeriod", 0)) > 90 * 86400:
        raise ValueError("Bucket retention policy exceeds the backup retention bound")
    rules = metadata.get("lifecycle", {}).get("rule", [])
    if not any(
        rule.get("action", {}).get("type") == "Delete"
        and 1 <= rule.get("condition", {}).get("age", 0) <= 90
        and set(rule.get("condition", {})) == {"age"}
        for rule in rules
    ):
        raise ValueError(
            "Backup bucket needs an unconditional age-based deletion rule within 90 days"
        )
    destination = bucket + "/releases/" + release + "/" + archive.name
    command(["gcloud", "storage", "cp", str(archive), destination])
    # gcloud verifies upload checksums; download a separate object copy and
    # compare SHA-256 as well, before marking the release backup verified.
    downloaded = archive.with_suffix(".uploaded-check")
    try:
        command(["gcloud", "storage", "cp", destination, str(downloaded)])
        with downloaded.open("rb") as remote, archive.open("rb") as local:
            if (
                hashlib.file_digest(remote, "sha256").digest()
                != hashlib.file_digest(local, "sha256").digest()
            ):
                raise ValueError("Off-site backup checksum differs")
    finally:
        downloaded.unlink(missing_ok=True)
    return destination


def run_backup(
    url,
    output,
    release,
    *,
    bucket=None,
    bootstrap_stopped=False,
    allow_local_test=False,
    source_container=None,
):
    if not re.fullmatch(r"[a-zA-Z0-9_-]{1,80}", release):
        raise ValueError("Invalid release identifier")
    parsed = make_url(url)
    if parsed.drivername != "postgresql+psycopg":
        raise ValueError("Use the operator postgresql+psycopg URL")
    if allow_local_test:
        if parsed.host not in {"127.0.0.1", "localhost"}:
            raise ValueError("Local test mode only accepts loopback databases")
    elif parsed.query.get("sslmode") != "verify-full":
        raise ValueError("Hosted backups require certificate/hostname-verified TLS")
    if source_container and (
        not allow_local_test or not re.fullmatch(r"forest-image-[a-f0-9]+-db", source_container)
    ):
        raise ValueError("Source-container override is limited to generated image smoke databases")
    output = Path(output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid4().hex[:8]
    archive = output / ("forest-" + stamp + ".dump")
    report_path = archive.with_suffix(".json")
    engine = create_engine(
        url, poolclass=NullPool, hide_parameters=True, connect_args={"connect_timeout": 5}
    )
    try:
        with operator_connection(engine) as connection:
            schema, expected = source_snapshot(
                connection, bootstrap_stopped=bootstrap_stopped, release=release
            )
            environment = dict(os.environ)
            environment.update(
                PGHOST=parsed.host or "",
                PGPORT=str(parsed.port or 5432),
                PGDATABASE=parsed.database or "postgres",
                PGUSER=parsed.username or "",
                PGPASSWORD=parsed.password or "",
                PGCONNECT_TIMEOUT="10",
                PGSSLMODE=parsed.query.get("sslmode", "prefer"),
            )
            args = ["docker", "run", "--rm"]
            if source_container:
                args += ["--network", "container:" + source_container]
                environment.update(PGHOST="127.0.0.1", PGPORT="5432")
            for variable in (
                "PGHOST",
                "PGPORT",
                "PGDATABASE",
                "PGUSER",
                "PGPASSWORD",
                "PGCONNECT_TIMEOUT",
                "PGSSLMODE",
            ):
                args += ["--env", variable]
            ca = parsed.query.get("sslrootcert")
            if ca:
                certificate = Path(ca).resolve(strict=True)
                args += [
                    "--mount",
                    f"type=bind,source={certificate},target=/etc/forest-db/ca.crt,readonly",
                    "--env",
                    "PGSSLROOTCERT=/etc/forest-db/ca.crt",
                ]
            args += [
                CLIENT_IMAGE,
                "pg_dump",
                "--format=custom",
                "--schema=public",
                "--no-owner",
                "--no-acl",
            ]
            with archive.open("xb") as data:
                subprocess.run(
                    args, env=environment, stdout=data, stderr=subprocess.PIPE, check=True
                )
            if source_snapshot(
                connection, bootstrap_stopped=bootstrap_stopped, release=release
            ) != (schema, expected):
                raise ValueError("Source changed during backup")
            # Closing a NullPool connection releases the session migration lock.
        verify_restore(archive, expected)
        with archive.open("rb") as data:
            checksum = hashlib.file_digest(data, "sha256").hexdigest()
        report = {
            "verifiedRestore": True,
            "release": release,
            "schema": schema,
            "createdAt": datetime.now(UTC).isoformat(),
            "archive": archive.name,
            "sha256": checksum,
            "tables": expected,
            "offsite": None,
        }
        if bucket:
            report["offsite"] = upload(archive, report_path, bucket, release)
        report_text = json.dumps(report, indent=2) + "\n"
        if bucket:
            pending = report_path.with_suffix(".pending.json")
            pending.write_text(report_text, encoding="utf-8")
            command(["gcloud", "storage", "cp", str(pending), report["offsite"] + ".json"])
            pending.replace(report_path)
        else:
            report_path.write_text(report_text, encoding="utf-8")
        return {
            "status": "verified",
            "receipt": str(report_path),
            "tables": len(expected),
            "offsite": report["offsite"],
        }
    finally:
        engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--release", required=True)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--bucket")
    target.add_argument("--local-only", action="store_true")
    parser.add_argument("--bootstrap-stopped", action="store_true")
    parser.add_argument("--allow-local-test", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--source-container", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        print(
            json.dumps(
                run_backup(
                    os.environ["FOREST_DATABASE_URL"],
                    args.output,
                    args.release,
                    bucket=args.bucket,
                    bootstrap_stopped=args.bootstrap_stopped,
                    allow_local_test=args.allow_local_test,
                    source_container=args.source_container,
                )
            )
        )
    except Exception as error:
        if args.allow_local_test and isinstance(error, subprocess.CalledProcessError):
            print((error.stderr or b"").decode(errors="replace"))
        print(json.dumps({"status": "failed", "kind": type(error).__name__}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
