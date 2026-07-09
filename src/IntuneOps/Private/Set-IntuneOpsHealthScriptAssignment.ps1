# Purpose: PRIVATE. Idempotently assign a deviceHealthScript to its target (AllDevices/AllUsers/group). STATE-CHANGING: callers must gate behind -Execute and ShouldProcess.

function Set-IntuneOpsHealthScriptAssignment {
    <#
    .SYNOPSIS
        Ensures a deviceHealthScript is assigned to the configured target, creating the assignment
        only if an equivalent one does not already exist.

    .DESCRIPTION
        Idempotent assignment: reads the current assignments first and skips the POST when a matching
        target is already assigned, so re-running the workflow does not stack duplicate assignments.
        This is the "trigger" mechanism for v1: Intune runs the remediation on the assignment's daily
        schedule. Per-device on-demand triggering is out of scope (it needs the privileged operations
        scope; see PLAN.md section 4).

        State-changing when it POSTs; must be reached only on the -Execute path. Uses RAW
        Invoke-MgGraphRequest against the documented v1.0 endpoints.

    .PARAMETER HealthScriptId
        The id of the deviceHealthScript to assign.

    .PARAMETER Action
        The 'Automated' plan action (carries AssignmentTarget and DailyScheduleTime).

    .EXAMPLE
        $result = Set-IntuneOpsHealthScriptAssignment -HealthScriptId $id -Action $action

    .OUTPUTS
        PSCustomObject: AssignmentResult ('Assigned' | 'AlreadyAssigned'), TargetType.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HealthScriptId,

        [Parameter(Mandatory)]
        [object]$Action
    )

    # Resolve the assignment target object from the friendly config value.
    $targetValue = [string]$Action.AssignmentTarget
    switch -Regex ($targetValue) {
        '^(?i)alldevices$' { $targetObject = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' }; $targetType = 'AllDevices'; break }
        '^(?i)allusers$'   { $targetObject = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' }; $targetType = 'AllUsers'; break }
        default            { $targetObject = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $targetValue }; $targetType = "Group:$targetValue" }
    }

    # Read existing assignments to stay idempotent.
    $existingAssignments = @()
    try {
        $current = Invoke-MgGraphRequest -Method GET -Uri "/v1.0/deviceManagement/deviceHealthScripts/$HealthScriptId/assignments" -ErrorAction Stop
        if ($current -and $current.ContainsKey('value')) { $existingAssignments = @($current.value) }
    }
    catch {
        throw "Failed to read assignments for deviceHealthScript $HealthScriptId : $($_.Exception.Message)"
    }

    $alreadyAssigned = $existingAssignments | Where-Object {
        $t = $_.target
        $t -and ([string]$t.'@odata.type' -eq [string]$targetObject.'@odata.type') -and
        # For group targets also match the groupId; for All* targets the type match is sufficient.
        (-not $targetObject.ContainsKey('groupId') -or [string]$t.groupId -eq [string]$targetObject.groupId)
    } | Select-Object -First 1

    if ($alreadyAssigned) {
        Write-IntuneOpsLog -Message "Assignment to $targetType already present on $HealthScriptId; skipping (idempotent)." -Level Info
        return [pscustomobject]@{ AssignmentResult = 'AlreadyAssigned'; TargetType = $targetType }
    }

    $assignBody = @{
        deviceHealthScriptAssignments = @(
            @{
                target               = $targetObject
                runRemediationScript = $true
                runSchedule          = @{
                    '@odata.type' = '#microsoft.graph.deviceHealthScriptDailySchedule'
                    interval      = 1
                    time          = $Action.DailyScheduleTime
                    useUtc        = $false
                }
            }
        )
    }

    try {
        Invoke-MgGraphRequest -Method POST -Uri "/v1.0/deviceManagement/deviceHealthScripts/$HealthScriptId/assign" -Body ($assignBody | ConvertTo-Json -Depth 6) -ContentType 'application/json' -ErrorAction Stop | Out-Null
    }
    catch {
        throw "Failed to assign deviceHealthScript $HealthScriptId to $targetType : $($_.Exception.Message)"
    }

    Write-IntuneOpsLog -Message "Assigned proactive remediation $HealthScriptId to $targetType (daily at $($Action.DailyScheduleTime))." -Level Success
    return [pscustomobject]@{ AssignmentResult = 'Assigned'; TargetType = $targetType }
}
