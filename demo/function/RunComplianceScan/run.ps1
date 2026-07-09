# Purpose: DEMO Azure Function (HTTP trigger). Runs the real IntuneOps pipeline against the mock
# fixtures, permanently in DRY-RUN, and returns the canonical result objects as JSON. A wrapper
# only: no compliance, remediation, notification, or report logic lives here.

<#
SECURITY INVARIANT: this Function is structurally incapable of mutating tenant state.
  - The request object is never read. No query parameter, header, or body value influences ANY
    flag, so there is no code path from the web to -Execute. Do not "improve" this by accepting
    request options.
  - Invoke-IntuneOpsRemediation and Send-IntuneOpsNotification are called WITHOUT -Execute, which
    in this module means zero state-changing Graph calls by design.
  - The device data source is the mock fixtures; no Graph session is ever established.
Keep all three properties intact when editing this file.
#>

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Resolve the pipeline root. Deployed: the staged payload folder inside the Function app (created
# by Stage-FunctionPayload.ps1, mirrors the repo layout). Local func start: the repo root two
# levels above the app folder.
$appRoot     = Split-Path -Path $PSScriptRoot -Parent
$payloadRoot = Join-Path $appRoot 'IntuneOps'
$pipelineRoot = if (Test-Path -LiteralPath (Join-Path $payloadRoot 'src/IntuneOps/IntuneOps.psd1')) {
    $payloadRoot
}
else {
    Split-Path -Path (Split-Path -Path $appRoot -Parent) -Parent
}

$tempJsonPath = $null
try {
    # Import once per worker; warm invocations reuse the loaded module.
    if (-not (Get-Module -Name IntuneOps)) {
        Import-Module (Join-Path $pipelineRoot 'src/IntuneOps/IntuneOps.psd1')
    }

    # Same stages as scripts/Invoke-ComplianceScan.ps1 -GraphDataSourceMock, minus the exit codes
    # (an entrypoint 'exit' would kill the Functions host, so the module is driven directly).
    $config  = Get-IntuneOpsConfig -SettingsPath (Join-Path $pipelineRoot 'config/settings.example.psd1')
    $devices = Get-IntuneOpsDevice -GraphDataSourceMock -FixturePath (Join-Path $pipelineRoot 'tests/fixtures/managedDevices/managedDevices.mock.json')
    $results = @($devices | Test-IntuneOpsCompliance -Rules $config.Rules)

    $nonCompliant = @($results | Where-Object { $_.OverallStatus -eq 'NonCompliant' })
    $remediationOutcomes  = @($nonCompliant | Invoke-IntuneOpsRemediation -Config $config)
    $notificationOutcomes = @($nonCompliant | Send-IntuneOpsNotification -Config $config)

    # The report stage requires a JSON path; write it to the sandbox temp dir and return the
    # objects in-memory rather than depending on the disk artifact.
    $tempJsonPath = Join-Path ([System.IO.Path]::GetTempPath()) "intuneops-demo-$([guid]::NewGuid()).json"
    $summary = Write-IntuneOpsReport -Result $results -JsonPath $tempJsonPath `
        -RemediationOutcome $remediationOutcomes -NotificationOutcome $notificationOutcomes

    # Never leak server paths to the browser.
    $summary.JsonPath = $null
    $summary.CsvPath  = $null

    $stopwatch.Stop()
    $body = [pscustomobject]@{
        results       = $results
        remediation   = $remediationOutcomes
        notifications = $notificationOutcomes
        summary       = $summary
        meta          = [pscustomobject]@{
            mode           = 'mock-dry-run'
            dataSource     = 'fixtures'
            executed       = $false
            generatedAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            durationMs     = [int]$stopwatch.ElapsedMilliseconds
        }
    }

    $response = @{
        StatusCode = 200
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($body | ConvertTo-Json -Depth 10)
    }
}
catch {
    # Log the full error server-side; return only a safe message (no stack traces, no paths).
    Write-Error "IntuneOps demo scan failed: $($_.Exception.Message)`n$($_.ScriptStackTrace)" -ErrorAction Continue
    $response = @{
        StatusCode = 500
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = 'The compliance scan failed to run. Check the Function logs for details.' } | ConvertTo-Json)
    }
}
finally {
    if ($tempJsonPath -and (Test-Path -LiteralPath $tempJsonPath)) {
        Remove-Item -LiteralPath $tempJsonPath -Force -ErrorAction SilentlyContinue
    }
}

# HttpResponseContext exists only inside the Functions worker; the plain hashtable keeps this
# script drivable by a local test harness.
if ('HttpResponseContext' -as [type]) { $response = [HttpResponseContext]$response }
Push-OutputBinding -Name Response -Value $response
