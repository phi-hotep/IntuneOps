# Purpose: PRIVATE. Build the remediation action plan from compliance results + rules. Pure and deterministic (no Graph, no I/O beyond resolving script paths), so it is fully unit-testable.

function Resolve-IntuneOpsRemediationPlan {
    <#
    .SYNOPSIS
        Translates compliance results and rules into a concrete, ordered remediation plan.

    .DESCRIPTION
        Separates the "what should happen" decision (pure) from the "make it happen" execution
        (Graph). For every enabled check that has at least one non-compliant device it emits plan
        actions according to the check's configured action:

          - 'Automated': ONE aggregate action per check (the Intune proactive remediation script is
            a tenant-level object assigned to a group, not a per-device artifact). The action lists
            the affected device ids for reporting, plus the resolved detection/remediation script
            paths and assignment target.
          - 'Nudge': ONE action per affected device (the nudge is per user/device).

        Script paths in the rules are resolved against the repository root and existence-checked so
        the dry-run transcript can show real paths and flag a missing script before any execute run.

    .PARAMETER Results
        Compliance result objects from Test-IntuneOpsCompliance.

    .PARAMETER Config
        The merged config object from Get-IntuneOpsConfig (Rules + RepositoryRoot).

    .EXAMPLE
        $plan = Resolve-IntuneOpsRemediationPlan -Results $results -Config $config

    .OUTPUTS
        PSCustomObject[] plan actions (Kind = 'Automated' | 'Nudge').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [Parameter(Mandatory)]
        [object]$Config
    )

    # Map a rules key to the check name emitted by Test-IntuneOpsCompliance.
    $checkNameByRule = @{
        diskEncryption = 'DiskEncryption'
        osVersion      = 'OSVersion'
        antivirus      = 'Antivirus'
    }

    $rules = $Config.Rules
    $root  = $Config.RepositoryRoot
    $plan  = [System.Collections.Generic.List[object]]::new()

    foreach ($ruleKey in $checkNameByRule.Keys) {
        if (-not $rules.checks.PSObject.Properties[$ruleKey]) { continue }
        $rule = $rules.checks.$ruleKey
        if (-not $rule.enabled) { continue }

        $checkName = $checkNameByRule[$ruleKey]
        $action = if ($rule.PSObject.Properties['action'] -and $rule.action) { [string]$rule.action } else { 'Nudge' }

        # Which devices are non-compliant specifically on THIS check.
        $affected = @(
            $Results | Where-Object {
                @($_.Checks | Where-Object { $_.Check -eq $checkName -and $_.Status -eq 'NonCompliant' }).Count -gt 0
            }
        )
        if ($affected.Count -eq 0) { continue }

        if ($action -eq 'Automated') {
            if (-not $rule.PSObject.Properties['remediation'] -or -not $rule.remediation) {
                # Misconfigured: Automated with no remediation block. Fall back to nudge so the
                # devices are still surfaced rather than silently dropped.
                foreach ($dev in $affected) {
                    $plan.Add((New-NudgeAction -Device $dev -Check $checkName))
                }
                continue
            }

            $rem = $rule.remediation
            $detectionPath   = Resolve-ScriptPath -Root $root -Path ([string]$rem.detectionScriptPath)
            $remediationPath = Resolve-ScriptPath -Root $root -Path ([string]$rem.remediationScriptPath)

            $target = if ($rem.PSObject.Properties['assignmentTarget'] -and $rem.assignmentTarget) { [string]$rem.assignmentTarget } else { 'AllDevices' }

            $plan.Add([pscustomobject]@{
                Kind                     = 'Automated'
                Check                    = $checkName
                DisplayName              = [string]$rem.displayName
                Description              = [string]$rem.description
                Publisher                = if ($rem.PSObject.Properties['publisher']) { [string]$rem.publisher } else { 'IntuneOps' }
                DetectionScriptPath      = $detectionPath.Path
                RemediationScriptPath    = $remediationPath.Path
                ScriptsExist             = ($detectionPath.Exists -and $remediationPath.Exists)
                RunAsAccount             = if ($rem.PSObject.Properties['runAsAccount']) { [string]$rem.runAsAccount } else { 'system' }
                RunAs32Bit               = [bool]($rem.PSObject.Properties['runAs32Bit'] -and $rem.runAs32Bit)
                EnforceSignatureCheck    = [bool]($rem.PSObject.Properties['enforceSignatureCheck'] -and $rem.enforceSignatureCheck)
                AssignmentTarget         = $target
                DailyScheduleTime        = if ($rem.PSObject.Properties['dailyScheduleTime']) { [string]$rem.dailyScheduleTime } else { '01:00:00' }
                AffectedDeviceIds        = @($affected.DeviceId)
                AffectedDeviceCount      = $affected.Count
            })
        }
        else {
            foreach ($dev in $affected) {
                $plan.Add((New-NudgeAction -Device $dev -Check $checkName))
            }
        }
    }

    return $plan.ToArray()
}

function New-NudgeAction {
    # Builds a per-device nudge action, extracting the reason for the specific failing check.
    param([object]$Device, [string]$Check)
    $checkResult = @($Device.Checks | Where-Object { $_.Check -eq $Check }) | Select-Object -First 1
    [pscustomobject]@{
        Kind       = 'Nudge'
        Check      = $Check
        DeviceId   = $Device.DeviceId
        DeviceName = $Device.DeviceName
        OwnerUpn   = $Device.OwnerUpn
        Reason     = if ($checkResult) { $checkResult.Reason } else { 'Non-compliant.' }
    }
}

function Resolve-ScriptPath {
    # Resolves a rules-relative script path against the repo root and reports existence.
    param([string]$Root, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Path = $null; Exists = $false }
    }
    $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path -Path $Root -ChildPath $Path }
    [pscustomobject]@{ Path = $full; Exists = (Test-Path -LiteralPath $full) }
}
