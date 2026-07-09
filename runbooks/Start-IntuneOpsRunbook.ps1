# Purpose: AZURE AUTOMATION entrypoint. Reads Automation variables, forces managed-identity auth, runs the pipeline non-interactively, always writes a report artifact, and surfaces a run summary.

<#
.SYNOPSIS
    Azure Automation runbook that runs the IntuneOps compliance pipeline unattended.

.DESCRIPTION
    The unattended counterpart to scripts/Invoke-ComplianceScan.ps1. It authenticates with the
    Automation account's system-assigned MANAGED IDENTITY (no secrets), then runs the same module
    pipeline: query -> evaluate -> remediate -> notify -> report.

    Behaviour is controlled by Automation variables (all optional; safe dry-run defaults):
      IntuneOps-Execute    ('true'/'false')  perform real remediation and mail send. Default false.
      IntuneOps-Remediate  ('true'/'false')  run the remediation stage.               Default true.
      IntuneOps-Notify     ('true'/'false')  run the notification stage.              Default true.
      IntuneOps-MailSender  (UPN)            sender mailbox for notifications.
    Because the defaults are Remediate+Notify in DRY-RUN, a freshly imported runbook changes nothing
    until an operator sets IntuneOps-Execute to 'true'.

    Reports are written under the Automation sandbox temp directory and emitted to the output stream.

.NOTES
    Requires the Microsoft.Graph.Authentication and Microsoft.Graph.DeviceManagement modules imported
    into the Automation account, and Graph app roles assigned to the managed identity's service
    principal (see README). Exit is via throw on fatal error; non-compliance is reported, not thrown.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Helper: read an Automation variable if the cmdlet exists (it only exists inside Automation),
# otherwise return the provided default. Keeps the runbook testable outside Automation.
function Get-RunbookSetting {
    param([string]$Name, [object]$Default)
    if (Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue) {
        try {
            $value = Get-AutomationVariable -Name $Name -ErrorAction Stop
            if ($null -ne $value -and "$value" -ne '') { return $value }
        }
        catch { }
    }
    return $Default
}

# Locate the module. When published as part of a module package it is importable by name; when the
# repo is laid down on the sandbox, fall back to the relative path.
$moduleName = 'IntuneOps'
if (-not (Get-Module -ListAvailable -Name $moduleName)) {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1'
    Import-Module $modulePath -Force
}
else {
    Import-Module $moduleName -Force
}

$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$outDir = if ($env:TEMP) { $env:TEMP } else { '.' }
$jsonPath = Join-Path $outDir "intuneops-compliance-$timestamp.json"
$csvPath  = Join-Path $outDir "intuneops-compliance-$timestamp.csv"
$logPath  = Join-Path $outDir "intuneops-$timestamp.log"
& (Get-Module IntuneOps) { param($p) $script:IntuneOpsLogPath = $p } $logPath

# Resolve behaviour from Automation variables (safe defaults).
$doExecute   = ([string](Get-RunbookSetting -Name 'IntuneOps-Execute'   -Default 'false')).ToLower() -eq 'true'
$doRemediate = ([string](Get-RunbookSetting -Name 'IntuneOps-Remediate' -Default 'true')).ToLower()  -eq 'true'
$doNotify    = ([string](Get-RunbookSetting -Name 'IntuneOps-Notify'    -Default 'true')).ToLower()   -eq 'true'
$mailSender  = [string](Get-RunbookSetting -Name 'IntuneOps-MailSender' -Default '')

try {
    Write-IntuneOpsLog -Message "IntuneOps runbook starting (managed identity). Execute=$doExecute; Remediate=$doRemediate; Notify=$doNotify." -Level Info

    # Config: use the module's shipped settings by default; an operator can override via a settings
    # file staged on the sandbox. RulesPath inside settings resolves against the repo root.
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $settingsPath = Join-Path $repoRoot 'config/settings.example.psd1'
    $config = & (Get-Module IntuneOps) { param($p) Get-IntuneOpsConfig -SettingsPath $p } $settingsPath

    # Compose scopes by what will be executed (app-only ignores scopes, but we keep the intent clear).
    $scopeSet = @(& (Get-Module IntuneOps) { $script:IntuneOpsDefaultScopes })
    if ($doExecute -and $doRemediate) { $scopeSet += (& (Get-Module IntuneOps) { $script:IntuneOpsRemediationScopes }) }
    if ($doExecute -and $doNotify)    { $scopeSet += (& (Get-Module IntuneOps) { $script:IntuneOpsMailSendScope }) }
    $scopeSet = @($scopeSet | Select-Object -Unique)

    $context = Connect-IntuneOps -AuthMode ManagedIdentity -Scopes $scopeSet
    Write-IntuneOpsLog -Message "Connected app-only (tenant $($context.TenantId))." -Level Info

    $devices = Get-IntuneOpsDevice
    if (@($devices).Count -eq 0) {
        Write-IntuneOpsLog -Message "No managed devices returned; nothing to do." -Level Warning
        return
    }

    $results = @($devices | Test-IntuneOpsCompliance -Rules $config.Rules)
    $nonCompliant = @($results | Where-Object { $_.OverallStatus -eq 'NonCompliant' })

    $remediationOutcomes = @()
    if ($doRemediate -and $nonCompliant.Count -gt 0) {
        $remediationOutcomes = @($nonCompliant | Invoke-IntuneOpsRemediation -Config $config -Execute:$doExecute)
    }

    $notificationOutcomes = @()
    if ($doNotify -and $nonCompliant.Count -gt 0) {
        $notifyParams = @{ Config = $config; Execute = $doExecute }
        if ($mailSender) { $notifyParams['MailSender'] = $mailSender }
        $notificationOutcomes = @($nonCompliant | Send-IntuneOpsNotification @notifyParams)
    }

    $summary = Write-IntuneOpsReport -Result $results -JsonPath $jsonPath -CsvPath $csvPath `
        -RemediationOutcome $remediationOutcomes -NotificationOutcome $notificationOutcomes

    # Emit the summary to the runbook output stream for the Automation job record.
    Write-Output $summary
    Write-IntuneOpsLog -Message "Runbook complete. Recommended exit code: $($summary.RecommendedExitCode)." -Level Success
}
catch {
    Write-IntuneOpsLog -Message "Runbook fatal: $($_.Exception.Message)" -Level Error
    throw
}
