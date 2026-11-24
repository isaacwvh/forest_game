"""Release configuration, backup validation and CI selection regression checks."""

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load(relative):
    spec = importlib.util.spec_from_file_location(Path(relative).stem, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize(
    "path,backend,frontend",
    [
        ("frontend/MovementForest/Features/ProfileScreen.swift", False, True),
        ("backend/src/forest_api/history.py", True, False),
        ("backend/src/forest_api/catalog_copy.py", True, True),
        ("backend/src/forest_api/launch_balance.py", True, True),
        ("backend/src/forest_api/data/garden-items-v1.json", True, True),
        ("tools/validate_items.py", False, True),
        (".gitattributes", True, True),
        ("frontend/MovementForest/Resources/Fixtures/editor-contract.json", True, True),
        ("IMPLEMENTATION_PLAN.md", False, False),
    ],
)
def test_ci_selection_covers_shared_inputs_without_deploying_swift(path, backend, frontend):
    ci = load("tools/ci_changes.py")
    assert ci.selected([path], "backend") is backend
    assert ci.selected([path], "frontend") is frontend


def test_catalogue_bytes_enforce_lf_and_manifest():
    checker = load("tools/check_catalog_bytes.py")
    data = (ROOT / checker.ASSET).read_bytes()
    manifest = (ROOT / checker.MANIFEST).read_bytes()
    checker.check(data, manifest, "test")
    with pytest.raises(SystemExit):
        checker.check(data.replace(b"\n", b"\r\n"), manifest, "test")


def test_cloud_commands_separate_identities_and_pin_secrets():
    cloud = load("backend/deploy/cloud_run.py")
    config = cloud.configuration(ROOT / "backend/deploy/production.example.json")
    commit, image = "a" * 40, "example@sha256:" + "b" * 64
    api, worker = cloud.commands(config, image, commit, "deploy")
    assert "--max=1" in api and "--concurrency=4" in api
    assert "--max=1" in worker and "--concurrency=1" in worker
    assert "--no-traffic" in api and "--no-traffic" in worker
    assert "--allow-unauthenticated" in api
    assert "--no-allow-unauthenticated" in worker and "--invoker-iam-check" in worker
    for cmd in (api, worker):
        secret = next(value for value in cmd if value.startswith("--set-secrets="))
        assert "forest-runtime-database-url:1" in secret
        assert "forest-migration" not in secret
        assert "forest-db-ca:1" in secret
        assert ":latest" not in secret
    jobs = cloud.commands(config, image, commit, "jobs")
    assert all("--max-retries=0" in cmd and "--parallelism=1" in cmd for cmd in jobs)
    assert any("forest-migration-database-url:1" in value for value in jobs[0])
    assert all("forest-migration-database-url" not in value for value in jobs[2])


@pytest.mark.parametrize(
    "field,value",
    [
        ("runtime_version", "latest"),
        ("api_account", "forest-migrator@forest-game-prod.iam.gserviceaccount.com"),
        ("runtime_secret", "forest-migration-database-url"),
        ("auth_jwks_url", "https://wrong.example/keys"),
    ],
)
def test_cloud_configuration_rejects_unsafe_release_settings(tmp_path, field, value):
    cloud = load("backend/deploy/cloud_run.py")
    config = json.loads((ROOT / "backend/deploy/production.example.json").read_text())
    config[field] = value
    path = tmp_path / "config.json"
    path.write_text(json.dumps(config))
    with pytest.raises(ValueError):
        cloud.configuration(path)


def test_backup_receipt_rejects_unverified_or_old_exports(tmp_path):
    cloud = load("backend/deploy/cloud_run.py")
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps({"createdAt": "2020-01-01T00:00:00+00:00"}))
    with pytest.raises(ValueError):
        cloud.backup_receipt(path, "a" * 40)
