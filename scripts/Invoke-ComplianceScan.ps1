# Purpose: LOCAL entrypoint. Thin wrapper: parse params, import the module, run the read-only Phase 1 pipeline (connect -> query -> evaluate), write a canonical JSON report, set exit code.

<#
.SYNOPSIS
    Runs a read-only IntuneOps compliance scan and writes a canonical result report.

.DESCRIPTION
    Connects to Microsoft Graph, queries Intune managed devices, evaluates each against the
    data-driven compliance rules, prints a console summary, and writes the canonical compliance
    result objects to JSON.

    By default this is fully read-only: no write scope is requested and nothing is mutated. The
    optional remediation stage (Phase 2) runs only when -Remediate is passed, and even then it is a
    dry-run unless -Execute is ALSO passed. The write scope (DeviceManagementConfiguration.ReadWrite
    .All) is requested only on the -Execute path. Notifications (Phase 3) are not included here.

    MOCK MODE: -GraphDataSourceMock sources managed devices from the JSON fixtures instead of live
    Graph, so the whole pipeline runs offline. In mock mode the remediation and notification stages
    default ON (still dry-run) so one flag demonstrates the full pipeline end to end. A Graph
    session is established only when a stage will actually call Graph: mock dry-run makes zero
    Graph calls so no sign-in happens; mock plus -Execute still signs in for real (device-code,
    with INTUNEOPS_TENANT_ID) because remediation and mail send are live writes either way.

.PARAMETER SettingsPath
    Path to the settings .psd1. Defaults to config/settings.example.psd1 in the repo.

.PARAMETER RulesPath
    Optional explicit path to compliance-rules.json. Defaults to the RulesPath in settings.

.PARAMETER Platform
    Optional platform filter (Windows, macOS, iOS, Android).

.PARAMETER AuthMode
    Auth mode passed to Connect-IntuneOps (DeviceCode by default for local dev).

.PARAMETER MaxDevices
    Optional cap on devices evaluated (0 = no cap).

.PARAMETER GraphDataSourceMock
    Source devices from the JSON fixtures instead of live Graph (offline mock mode). Defaults the
    remediation and notification stages ON in dry-run so the full pipeline is demonstrated; pass
    -Remediate:$false or -Notify:$false to trim it.

.PARAMETER FixturePath
    Optional explicit fixture file for -GraphDataSourceMock. Defaults to
    tests/fixtures/managedDevices/managedDevices.mock.json.

.PARAMETER Remediate
    Run the Phase 2 remediation stage after evaluation. Dry-run unless -Execute is also passed.

.PARAMETER Notify
    Run the Phase 3 notification stage. Renders and logs the emails unless -Execute is also passed
    (then they are sent via Graph Mail).

.PARAMETER UseHtml
    Send the HTML email template instead of plain text. Defaults to the setting UseHtmlEmail.

.PARAMETER MailSender
    Sender mailbox for notifications. Defaults to the setting MailSender.

.PARAMETER Execute
    Perform real changes: real remediation (with -Remediate) and/or real mail send (with -Notify).
    Without it, both stages are dry-run/render and no write scope (ReadWrite or Mail.Send) is
    requested.

.PARAMETER CsvPath
    Flat CSV report path. Defaults to reports/compliance-<timestamp>.csv.

.PARAMETER LogPath
    Run log file path. Defaults to logs/intuneops-<timestamp>.log.

.PARAMETER OutputPath
    Canonical JSON report path. Defaults to reports/compliance-<timestamp>.json.

.EXAMPLE
    ./scripts/Invoke-ComplianceScan.ps1

.EXAMPLE
    ./scripts/Invoke-ComplianceScan.ps1 -AuthMode DeviceCode -Platform Windows -MaxDevices 25

.EXAMPLE
    ./scripts/Invoke-ComplianceScan.ps1 -GraphDataSourceMock
    Full offline dry-run against the fixtures: evaluate, planned remediation, rendered
    notifications, and the report. No Graph sign-in, no SDK requirement, nothing changed.

.NOTES
    Exit codes: 0 all compliant; 1 one or more non-compliant; 2 partial (some signals unreadable);
    3 fatal (auth/config failure).
#>
[CmdletBinding()]
param(
    [string]$SettingsPath,
    [string]$RulesPath,
    [ValidateSet('Windows', 'macOS', 'iOS', 'Android')]
    [string]$Platform,
    [ValidateSet('DeviceCode', 'Interactive', 'ManagedIdentity', 'AppCertificate', 'AppSecret')]
    [string]$AuthMode = 'DeviceCode',
    [int]$MaxDevices = 0,
    [switch]$GraphDataSourceMock,
    [string]$FixturePath,
    [switch]$Remediate,
    [switch]$Notify,
    [switch]$UseHtml,
    [string]$MailSender,
    [switch]$Execute,
    [string]$LogPath,
    [string]$OutputPath,
    [string]$CsvPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')

if (-not $SettingsPath) { $SettingsPath = Join-Path $repoRoot 'config/settings.example.psd1' }
if (-not $LogPath)      { $LogPath      = Join-Path $repoRoot "logs/intuneops-$timestamp.log" }
if (-not $OutputPath)   { $OutputPath   = Join-Path $repoRoot "reports/compliance-$timestamp.json" }
if (-not $CsvPath)      { $CsvPath      = Join-Path $repoRoot "reports/compliance-$timestamp.csv" }

# Import the module fresh so edits during development are always picked up.
$modulePath = Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1'
Import-Module $modulePath -Force

# Point the module-scoped logger at this run's log file. Setting a module-scoped variable from
# outside the module is done by running a scriptblock in the module's session state.
& (Get-Module IntuneOps) { param($p) $script:IntuneOpsLogPath = $p } $LogPath

try {
    # Mock mode is the demo mode: default the remediation and notification stages ON (still
    # dry-run) so one flag shows the full pipeline. Explicit switches still win, and -Execute
    # remains the only gate for real changes.
    if ($GraphDataSourceMock) {
        if (-not $PSBoundParameters.ContainsKey('Remediate')) { $Remediate = $true }
        if (-not $PSBoundParameters.ContainsKey('Notify'))    { $Notify = $true }
    }

    $execRemediation = $Remediate -and $Execute
    $execNotify      = $Notify -and $Execute
    $stageParts = @("scan$(if ($GraphDataSourceMock) {'(MOCK devices)'})")
    if ($Remediate) { $stageParts += "remediate($(if ($execRemediation) {'EXECUTE'} else {'dry-run'}))" }
    if ($Notify)    { $stageParts += "notify($(if ($execNotify) {'SEND'} else {'render'}))" }
    Write-IntuneOpsLog -Message "IntuneOps starting: $($stageParts -join ' + ')." -Level Info

    # 1) Config
    $config = Get-IntuneOpsConfig -SettingsPath $SettingsPath -RulesPath $RulesPath

    # 2) Connect. Scopes are composed by what will actually be EXECUTED: read-only by default,
    # plus the config write scope only when remediation executes, plus Mail.Send only when
    # notifications are actually sent. Dry-run/render stages never add a write scope.
    # A session is established only when some stage will actually call Graph: with the mock data
    # source the device read is local, so dry-run needs no sign-in at all, while -Execute still
    # signs in for real (remediation create/assign and mail send are live writes either way).
    $needsGraphSession = (-not $GraphDataSourceMock) -or $execRemediation -or $execNotify
    if ($needsGraphSession) {
        $scopeSet = @(& (Get-Module IntuneOps) { $script:IntuneOpsDefaultScopes })
        if ($execRemediation) { $scopeSet += (& (Get-Module IntuneOps) { $script:IntuneOpsRemediationScopes }) }
        if ($execNotify)      { $scopeSet += (& (Get-Module IntuneOps) { $script:IntuneOpsMailSendScope }) }
        $scopeSet = @($scopeSet | Select-Object -Unique)
        $context = Connect-IntuneOps -AuthMode $AuthMode -Scopes $scopeSet
        Write-IntuneOpsLog -Message "Signed in as '$($context.Account)' (app-only: $($context.IsAppOnly)); scopes requested: $($scopeSet -join ', ')." -Level Info
    }
    else {
        Write-IntuneOpsLog -Message 'Mock dry-run: devices come from fixtures and no stage will call Graph, so no Graph session is established and no scope is requested.' -Level Info
    }

    # 3) Query + normalize
    $deviceParams = @{ MaxDevices = $MaxDevices }
    if ($Platform)            { $deviceParams['Platform'] = $Platform }
    if ($GraphDataSourceMock) { $deviceParams['GraphDataSourceMock'] = $true }
    if ($FixturePath)         { $deviceParams['FixturePath'] = $FixturePath }
    $devices = Get-IntuneOpsDevice @deviceParams

    if (@($devices).Count -eq 0) {
        Write-IntuneOpsLog -Message "No devices to evaluate. Exiting cleanly." -Level Warning
        exit 0
    }

    # 4) Evaluate (pure)
    $results = @($devices | Test-IntuneOpsCompliance -Rules $config.Rules)

    # Console summary
    Write-Host ''
    Write-Host 'Compliance summary' -ForegroundColor Cyan
    $results |
        Select-Object DeviceName, Platform, OsVersion, OverallStatus,
            @{ n = 'FailingChecks'; e = { (@($_.Checks | Where-Object { $_.Status -notin 'Compliant', 'Unknown' }).Check) -join ', ' } } |
        Format-Table -AutoSize | Out-String | Write-Host

    $nonCompliant = @($results | Where-Object { $_.OverallStatus -eq 'NonCompliant' })
    $remediationOutcomes = @()
    $notificationOutcomes = @()

    # 5) Remediation stage (Phase 2), opt-in. Dry-run unless -Execute. Per-rule automated vs nudge.
    if ($Remediate) {
        if ($nonCompliant.Count -eq 0) {
            Write-IntuneOpsLog -Message "Remediation requested but no non-compliant devices; nothing to do." -Level Info
        }
        else {
            $remediationOutcomes = @($nonCompliant | Invoke-IntuneOpsRemediation -Config $config -Execute:$Execute)
            Write-Host ''
            Write-Host "Remediation outcomes ($(if ($execRemediation) {'EXECUTE'} else {'DRY-RUN'}))" -ForegroundColor Cyan
            $remediationOutcomes | Select-Object Kind, Check, Target, Result, AffectedDeviceCount | Format-Table -AutoSize | Out-String | Write-Host
        }
    }

    # 6) Notification stage (Phase 3), opt-in. Render + log unless -Execute (then send via Mail.Send).
    if ($Notify) {
        if ($nonCompliant.Count -eq 0) {
            Write-IntuneOpsLog -Message "Notifications requested but no non-compliant devices; nothing to notify." -Level Info
        }
        else {
            $notifyParams = @{ Config = $config; Execute = $Execute; UseHtml = $UseHtml }
            if ($MailSender) { $notifyParams['MailSender'] = $MailSender }
            $notificationOutcomes = @($nonCompliant | Send-IntuneOpsNotification @notifyParams)
            Write-Host ''
            Write-Host "Notification outcomes ($(if ($execNotify) {'SEND'} else {'RENDER'}))" -ForegroundColor Cyan
            $notificationOutcomes | Select-Object Device, To, ContentType, Result | Format-Table -AutoSize | Out-String | Write-Host
        }
    }

    # 7) Report from the ONE canonical result object: JSON (direct) + CSV (flat projection) + summary.
    $summary = Write-IntuneOpsReport -Result $results -JsonPath $OutputPath -CsvPath $CsvPath `
        -RemediationOutcome $remediationOutcomes -NotificationOutcome $notificationOutcomes

    # Exit code chosen by the report summary. Non-compliance is a signal (1), not a crash.
    switch ($summary.RecommendedExitCode) {
        1 { Write-IntuneOpsLog -Message "Result: one or more devices non-compliant." -Level Warning }
        2 { Write-IntuneOpsLog -Message "Result: some signals could not be evaluated." -Level Warning }
        default { Write-IntuneOpsLog -Message "Result: all evaluated devices compliant." -Level Success }
    }
    exit $summary.RecommendedExitCode
}
catch {
    Write-IntuneOpsLog -Message "Fatal: $($_.Exception.Message)" -Level Error
    exit 3
}
