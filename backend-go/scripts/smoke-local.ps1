$ErrorActionPreference = 'Stop'
$compose = Join-Path $PSScriptRoot '../compose.yaml'
$api = 'http://127.0.0.1:18000'
$worker = 'http://127.0.0.1:18001'

function Assert-Equal($actual, $expected, [string]$message) {
    if ($actual -ne $expected) { throw "$message (expected $expected, got $actual)" }
}

Assert-Equal (Invoke-RestMethod "$api/health/ready").status 'ready' 'The Go API must be ready'
$token = docker compose -f $compose exec -T api /forest dev-token ("go-smoke-" + [Guid]::NewGuid())
if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Could not issue a local development token' }
$headers = @{ Authorization = "Bearer $token"; 'X-Forest-Recovery' = '1'; 'X-Forest-Item-Rotations' = '1'; 'X-Forest-Snapshot' = '1'; 'X-Forest-Items' = '1' }
$body = @{ requestId = [Guid]::NewGuid(); gameTimezone = 'Asia/Singapore' } | ConvertTo-Json
$account = Invoke-RestMethod "$api/v1/accounts/bootstrap" -Headers $headers -Method Post -ContentType 'application/json' -Body $body
$replay = Invoke-RestMethod "$api/v1/accounts/bootstrap" -Headers $headers -Method Post -ContentType 'application/json' -Body $body
Assert-Equal $replay.starterPlantId $account.starterPlantId 'An account retry must return the same starter'
Assert-Equal (Invoke-RestMethod "$api/v1/me" -Headers $headers).userId $account.profile.userId 'Authenticated owner must match'
Assert-Equal (Invoke-RestMethod "$api/v1/catalog" -Headers $headers).isFixture $true 'The local catalogue must be a development fixture'
Assert-Equal (Invoke-RestMethod "$api/v1/me/inventory" -Headers $headers).plants.Count 1 'New account must have one starter'
Assert-Equal (Invoke-RestMethod "$api/v1/me/account-summary" -Headers $headers).wallet.tokenBalance '0' 'A new wallet must start at zero'
Assert-Equal (Invoke-RestMethod "$api/v1/me/activity" -Headers $headers).activitySteps '0' 'The initial activity total must be zero'
Assert-Equal (Invoke-RestMethod "$api/v1/me/garden/snapshot" -Headers $headers).garden.gardenId $account.gardenId 'The initial snapshot must match the account garden'
Assert-Equal (Invoke-RestMethod "$api/v1/me/home-attention" -Headers $headers).unopenedPackCount 0 'The compact Home read must match a new account'
Assert-Equal (Invoke-RestMethod "$api/v1/me/visitors" -Headers $headers).claimableVisits '0' 'The first visitor read must not grant past income'
$gardenEdit = @{
    requestId = [Guid]::NewGuid()
    catalogVersion = 'development-woodland-v2'
    expectedLayoutVersion = 0
    actions = @(@{ action = 'plant'; plantId = $account.starterPlantId; x = 2; y = 2; rotationDegrees = 0 })
}
$preview = Invoke-RestMethod "$api/v1/me/garden/preview" -Headers $headers -Method Post -ContentType 'application/json' -Body ($gardenEdit | ConvertTo-Json -Depth 5)
Assert-Equal $preview.totalAttractionMicroUnits '2000000' 'The planted starter must contribute its sprout attraction'
$gardenEdit.expectedStrategyFingerprint = $preview.fingerprint
$save = Invoke-RestMethod "$api/v1/me/garden/edits?knownInventoryStateVersion=0" -Headers $headers -Method Post -ContentType 'application/json' -Body ($gardenEdit | ConvertTo-Json -Depth 5)
Assert-Equal $save.garden.layoutVersion 1 'A valid garden edit must advance the layout'
$savedGarden = Invoke-RestMethod "$api/v1/me/garden/snapshot?catalogVersion=development-woodland-v2" -Headers $headers
Assert-Equal $savedGarden.garden.plants[0].plantId $account.starterPlantId 'A new snapshot must show the planted starter'
Assert-Equal (Invoke-RestMethod "$api/v1/me/visitors" -Headers $headers).totalAttractionMicroUnits '2000000' 'The visitor context must include the same planted starter'
$installation = [Guid]::NewGuid()
$reading = [DateTimeOffset]::UtcNow
$enrolBody = @{ requestId = [Guid]::NewGuid(); installationId = $installation; observedAt = $reading.ToString('o'); steps = 100 }
$enrolled = Invoke-RestMethod "$api/v1/activity/enrolments" -Headers $headers -Method Post -ContentType 'application/json' -Body ($enrolBody | ConvertTo-Json)
$syncBody = @{
    requestId = [Guid]::NewGuid()
    installationId = $installation
    deviceId = $enrolled.device.deviceId
    observedAt = [DateTimeOffset]::UtcNow.ToString('o')
    days = @(@{ gameDate = $reading.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd'); steps = 1100 })
    workoutsAvailable = $true
    workouts = @(@{
        workoutId = [Guid]::NewGuid()
        originalType = 37
        start = $reading.AddMinutes(-2).ToString('o')
        end = $reading.AddMinutes(-1).ToString('o')
        durationMilliseconds = 60000
        sourceBundleIdentifier = 'local.synthetic.tracker'
        wasUserEntered = $true
    })
}
$sync = Invoke-RestMethod "$api/v1/activity/sync" -Headers $headers -Method Post -ContentType 'application/json' -Body ($syncBody | ConvertTo-Json -Depth 5)
Assert-Equal $sync.activitySteps '1000' 'Sync must credit only steps above the device baseline'
Assert-Equal $sync.garden.plants[0].growthMicroUnits '10000000' 'Accepted step water must grow the planted starter'
Assert-Equal $sync.workouts[0].status 'manual_excluded' 'Manual workout evidence must be recorded and excluded from growth'
$shop = Invoke-RestMethod "$api/v1/me/collection?view=shop" -Headers $headers
Assert-Equal ($shop.offers | Where-Object offerId -eq 'woodland').offerVersion 2 'Shop must return the active Woodland offer'
Assert-Equal (Invoke-RestMethod "$api/v1/pack-definitions/woodland/versions/2" -Headers $headers).schemaVersion 2 'Woodland must publish species-weighted odds'
Assert-Equal (Invoke-RestMethod "$api/v1/me/packs" -Headers $headers).packs.Count 0 'A new account must have no unopened packs'
Assert-Equal (Invoke-RestMethod "$api/v1/me/pack-openings?latest=true" -Headers $headers).openings.Count 0 'A new account must have no opening history'
Assert-Equal (Invoke-RestMethod "$worker/tasks/shop" -Method Post).status 'ready' 'Shop task must complete'
Assert-Equal (Invoke-RestMethod "$worker/tasks/history" -Method Post).status 'ok' 'History task must finish its supported pass'

Write-Output 'PASS: local Go API, baseline migrations, account replay, garden preview and edit, activity sync and workout receipts, visitor context, Shop, pack reads, and both Go worker endpoints.'
