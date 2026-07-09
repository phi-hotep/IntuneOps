# Purpose: root module loader. Dot-sources all Private then Public function files and exports the Public set.

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scoped run state. The log path is set by the entrypoint (or Initialize) so that every
# function can call Write-IntuneOpsLog without threading a path parameter through the pipeline.
# Never store secret material here.
$script:IntuneOpsLogPath = $null
$script:IntuneOpsModuleRoot = $PSScriptRoot

# Phase 1 read-only delegated scopes. Kept in one place so Connect-IntuneOps and the docs agree.
# Write scopes are intentionally absent in Phase 1 and are added only with the remediation and
# notification phases.
$script:IntuneOpsDefaultScopes = @(
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementConfiguration.Read.All'
)

# Phase 2 remediation scope set: the read scopes plus the single write scope needed to create and
# assign proactive remediation scripts (deviceHealthScripts). Requested only when a caller actually
# intends to execute remediation (-Execute); dry-run stays on the read-only default set. The
# privileged on-demand trigger scope (DeviceManagementManagedDevices.PrivilegedOperations.All) is
# deliberately NOT included: v1 remediation is assignment-only (see PLAN.md section 4).
$script:IntuneOpsRemediationScopes = @(
    'DeviceManagementManagedDevices.Read.All'
    'DeviceManagementConfiguration.Read.All'
    'DeviceManagementConfiguration.ReadWrite.All'
)

# Phase 3 notification scope. Requested only when notifications are actually SENT (-Notify plus
# -Execute); rendering-only dry-run never requests it. For app-only send this Application permission
# is constrained to a single sender mailbox by an Application Access Policy (see README).
$script:IntuneOpsMailSendScope = 'Mail.Send'

# Dot-source Private helpers first (Public functions depend on them), then Public functions.
$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
$publicFiles  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Failed to load IntuneOps function file '$($file.Name)': $($_.Exception.Message)"
    }
}

# Export the Public function names (one function per Public/*.ps1 file, by convention) plus the
# two operational helpers the thin entrypoints drive directly: the logging sink and the config
# loader. Those two stay in Private/ because they are infrastructure, not pipeline stages, but
# scripts/ and runbooks/ call them before and between stages, so they must be visible outside the
# module. Keep this list in sync with FunctionsToExport in IntuneOps.psd1.
$entrypointHelpers = @('Write-IntuneOpsLog', 'Get-IntuneOpsConfig')
Export-ModuleMember -Function (@($publicFiles.BaseName) + $entrypointHelpers)
