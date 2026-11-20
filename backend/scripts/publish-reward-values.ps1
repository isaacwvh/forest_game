$ErrorActionPreference = 'Stop'

function Invoke-CheckedDocker {
    & docker @args
    if ($LASTEXITCODE -ne 0) {
        throw "Docker command failed: $args"
    }
}

Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    Invoke-CheckedDocker compose up -d --wait --wait-timeout 90 db

    # Copy a binary dump without PowerShell redirect/encoding conversion.
    New-Item -ItemType Directory -Path '.\backups' -Force | Out-Null
    $rewardBackup = ".\backups\before-reward-pricing-$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').dump"
    Invoke-CheckedDocker compose exec -T db pg_dump -U forest -d forest -Fc -f /tmp/before-reward-pricing.dump
    Invoke-CheckedDocker compose cp db:/tmp/before-reward-pricing.dump $rewardBackup
    Write-Host "Database backup: $rewardBackup"

    Invoke-CheckedDocker compose build api shop maintenance

    @'
from sqlalchemy import text
from forest_api.main import create_app
from forest_api.expedition_items import publish_items, TOKEN_VALUES
from forest_api.item_models import ItemValueDefinition

assert TOKEN_VALUES[("worldseed-orrery", 1)] == 5500, "Updated backend image required"
database = create_app().state.database
try:
    with database.sessions.begin() as session:
        session.execute(text("SELECT pg_advisory_xact_lock(591417021)"))
        publish_items(session)
    # Verify committed definitions, not just pending transaction changes.
    with database.sessions() as session:
        for item_id, version in TOKEN_VALUES:
            value = session.get(ItemValueDefinition, (item_id, version))
            tokens = value.token_value * value.resale_basis_points // 10000
            print(f"{item_id}: value {value.token_value}, resale {tokens} tokens")
finally:
    database.engine.dispose()
'@ | docker compose run --rm --no-deps -T api python -
    if ($LASTEXITCODE -ne 0) { throw 'Reward valuation publication failed.' }

    Invoke-CheckedDocker compose up -d --wait --wait-timeout 90
    Invoke-RestMethod -Uri 'http://127.0.0.1:8000/health/ready' -TimeoutSec 10
}
finally {
    Pop-Location
}
