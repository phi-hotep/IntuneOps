# Purpose: PUBLIC. Select the per-rule remediation action (automated Intune script vs nudge) for non-compliant devices. Dry-run by default; requires -Execute to mutate tenant state.

function Invoke-IntuneOpsRemediation {
    <#
    .SYNOPSIS
        Executes (or dry-runs) the remediation plan derived from compliance results.

    .DESCRIPTION
        The Phase 2 remediation engine. It builds a plan with Resolve-IntuneOpsRemediationPlan and
        then, per action, either logs what WOULD happen (dry-run) or performs it (-Execute).

        SAFETY MODEL (all three layers apply):
          1. Dry-run is the default. Without -Execute this function makes ZERO state-changing Graph
             calls. It logs the exact target, action, and script that would run and executes nothing.
             -Execute is the primary, explicit gate for real changes.
          2. SupportsShouldProcess: even with -Execute, -WhatIf short-circuits every write, and each
             mutation is individually guarded by ShouldProcess. ConfirmImpact is Medium (not High)
             so an unattended -Execute run in Azure Automation does not deadlock on a confirmation
             prompt; interactive users can still add -Confirm to be prompted per action.

        Two per-rule paths (selected in the rules file):
          - Automated: create the Intune proactive remediation (deviceHealthScript) if missing and
            assign it to the configured target. Idempotent: existing script/assignment is reused, so
            the workflow is safe to re-run. Assignment is the trigger (Intune runs it on schedule);
            per-device on-demand trigger is out of scope for v1.
          - Nudge: flag the affected device/user. In Phase 2 this only records the flag; the actual
            email is Phase 3. Nudge changes no tenant state in either dry-run or execute.

    .PARAMETER ComplianceResult
        Compliance result object(s) from Test-IntuneOpsCompliance. Accepts pipeline input; all piped
        results are collected before the plan is built (Automated actions aggregate across devices).

    .PARAMETER Config
        The merged config object from Get-IntuneOpsConfig (Rules + RepositoryRoot).

    .PARAMETER Execute
        Perform real changes. WITHOUT this switch the function is a pure dry-run and mutates nothing.

    .EXAMPLE
        $results | Invoke-IntuneOpsRemediation -Config $config
        Dry-run: logs what would happen, changes nothing.

    .EXAMPLE
        $results | Invoke-IntuneOpsRemediation -Config $config -Execute
        Performs the remediation (create + assign proactive remediation scripts).

    .EXAMPLE
        $results | Invoke-IntuneOpsRemediation -Config $config -Execute -WhatIf
        Even with -Execute, -WhatIf reports each action and changes nothing.

    .OUTPUTS
        PSCustomObject[] outcome records (one per action).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$ComplianceResult,

        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter()]
        [switch]$Execute
    )

    begin {
        $collected = [System.Collections.Generic.List[object]]::new()
    }

    process {
        $collected.Add($ComplianceResult)
    }

    end {
        $plan = Resolve-IntuneOpsRemediationPlan -Results $collected.ToArray() -Config $Config
        $mode = if ($Execute) { 'Execute' } else { 'DryRun' }

        if ($plan.Count -eq 0) {
            Write-IntuneOpsLog -Message 'No remediation actions required (no matching non-compliance).' -Level Info
            return
        }

        Write-IntuneOpsLog -Message "Remediation stage: $($plan.Count) planned action(s). Mode=$mode." -Level Info
        if (-not $Execute) {
            Write-IntuneOpsLog -Message 'DRY-RUN: no tenant state will be changed. Re-run with -Execute to apply.' -Level Warning
        }

        foreach ($action in $plan) {
            switch ($action.Kind) {

                'Automated' {
                    $targetDesc = "proactive remediation '$($action.DisplayName)' -> assign to $($action.AssignmentTarget)"

                    if (-not $action.ScriptsExist) {
                        Write-IntuneOpsLog -Message "Cannot remediate '$($action.DisplayName)': a script file is missing (detection='$($action.DetectionScriptPath)', remediation='$($action.RemediationScriptPath)')." -Level Error
                        [pscustomobject]@{
                            Kind = 'Automated'; Check = $action.Check; Target = $action.DisplayName
                            Mode = $mode; Result = 'Failed'; Detail = 'Remediation script file missing.'
                            AffectedDeviceCount = $action.AffectedDeviceCount
                        }
                        continue
                    }

                    if (-not $Execute) {
                        Write-IntuneOpsLog -Message "WOULD ensure $targetDesc exists and is assigned; detection='$($action.DetectionScriptPath)', remediation='$($action.RemediationScriptPath)', runAs=$($action.RunAsAccount), affects $($action.AffectedDeviceCount) device(s)." -Level Info
                        [pscustomobject]@{
                            Kind = 'Automated'; Check = $action.Check; Target = $action.DisplayName
                            Mode = 'DryRun'; Result = 'WouldCreateAndAssign'
                            Detail = "assign to $($action.AssignmentTarget); detection='$($action.DetectionScriptPath)'; remediation='$($action.RemediationScriptPath)'"
                            AffectedDeviceCount = $action.AffectedDeviceCount
                        }
                        continue
                    }

                    # Execute path: guarded by ShouldProcess so -WhatIf still short-circuits.
                    if (-not $PSCmdlet.ShouldProcess($targetDesc, 'Create (if missing) and assign proactive remediation')) {
                        [pscustomobject]@{
                            Kind = 'Automated'; Check = $action.Check; Target = $action.DisplayName
                            Mode = 'Execute'; Result = 'SkippedByWhatIf'; Detail = 'ShouldProcess declined.'
                            AffectedDeviceCount = $action.AffectedDeviceCount
                        }
                        continue
                    }

                    try {
                        $existing = Get-IntuneOpsHealthScript -DisplayName $action.DisplayName
                        if ($existing) {
                            $scriptId = [string]$existing.id
                            $createResult = 'AlreadyExists'
                            Write-IntuneOpsLog -Message "Proactive remediation '$($action.DisplayName)' already exists (id=$scriptId); reusing (idempotent)." -Level Info
                        }
                        else {
                            $created = New-IntuneOpsHealthScript -Action $action
                            $scriptId = [string]$created.id
                            $createResult = 'Created'
                        }

                        $assign = Set-IntuneOpsHealthScriptAssignment -HealthScriptId $scriptId -Action $action

                        [pscustomobject]@{
                            Kind = 'Automated'; Check = $action.Check; Target = $action.DisplayName
                            Mode = 'Execute'; Result = "$createResult+$($assign.AssignmentResult)"
                            Detail = "id=$scriptId; target=$($assign.TargetType)"
                            AffectedDeviceCount = $action.AffectedDeviceCount
                        }
                    }
                    catch {
                        Write-IntuneOpsLog -Message "Automated remediation failed for '$($action.DisplayName)': $($_.Exception.Message)" -Level Error
                        [pscustomobject]@{
                            Kind = 'Automated'; Check = $action.Check; Target = $action.DisplayName
                            Mode = 'Execute'; Result = 'Failed'; Detail = $_.Exception.Message
                            AffectedDeviceCount = $action.AffectedDeviceCount
                        }
                    }
                }

                'Nudge' {
                    # Nudge never mutates tenant state (the email is Phase 3). Dry-run and execute
                    # differ only in the log verb.
                    if (-not $Execute) {
                        Write-IntuneOpsLog -Message "WOULD nudge '$($action.DeviceName)' (owner $($action.OwnerUpn)) for $($action.Check): $($action.Reason)" -Level Info
                        $result = 'WouldNudge'
                    }
                    else {
                        Write-IntuneOpsLog -Message "FLAG (nudge) '$($action.DeviceName)' (owner $($action.OwnerUpn)) for $($action.Check). Notification deferred to Phase 3." -Level Info
                        $result = 'Flagged'
                    }
                    [pscustomobject]@{
                        Kind = 'Nudge'; Check = $action.Check; Target = $action.DeviceName
                        Mode = $mode; Result = $result; Detail = $action.Reason
                        AffectedDeviceCount = 1
                    }
                }
            }
        }
    }
}
