# Purpose: PRIVATE. Create an Intune proactive remediation (deviceHealthScript) from detection + remediation script files. STATE-CHANGING: callers must gate this behind -Execute and ShouldProcess.

function New-IntuneOpsHealthScript {
    <#
    .SYNOPSIS
        Creates a deviceHealthScript (Intune proactive remediation) from an Automated plan action.

    .DESCRIPTION
        Reads the detection and remediation script files, base64-encodes them, and POSTs a new
        deviceHealthScript to Graph. This is a state-changing operation: it must only be invoked on
        the -Execute path after ShouldProcess has approved it. The function itself does not gate;
        gating lives in Invoke-IntuneOpsRemediation so the dry-run path never reaches here.

        Uses a RAW Invoke-MgGraphRequest POST against the documented v1.0 endpoint (see
        Get-IntuneOpsHealthScript for why raw).

    .PARAMETER Action
        An 'Automated' plan action from Resolve-IntuneOpsRemediationPlan (carries DisplayName,
        script paths, runAsAccount, etc.).

    .EXAMPLE
        $created = New-IntuneOpsHealthScript -Action $action

    .OUTPUTS
        The created deviceHealthScript object (hashtable), including its new id.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Action
    )

    foreach ($p in @($Action.DetectionScriptPath, $Action.RemediationScriptPath)) {
        if (-not $p -or -not (Test-Path -LiteralPath $p)) {
            throw "Remediation script file not found: '$p'. Cannot create '$($Action.DisplayName)'."
        }
    }

    # Base64-encode the raw script bytes (UTF-8) as Graph expects for *ScriptContent.
    $detectionB64   = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $Action.DetectionScriptPath -Raw)))
    $remediationB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath $Action.RemediationScriptPath -Raw)))

    $body = @{
        '@odata.type'            = '#microsoft.graph.deviceHealthScript'
        displayName              = $Action.DisplayName
        description              = $Action.Description
        publisher                = $Action.Publisher
        detectionScriptContent   = $detectionB64
        remediationScriptContent = $remediationB64
        runAsAccount             = $Action.RunAsAccount
        runAs32Bit               = $Action.RunAs32Bit
        enforceSignatureCheck    = $Action.EnforceSignatureCheck
    }

    try {
        $created = Invoke-MgGraphRequest -Method POST -Uri '/v1.0/deviceManagement/deviceHealthScripts' -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json' -ErrorAction Stop
    }
    catch {
        throw "Failed to create deviceHealthScript '$($Action.DisplayName)': $($_.Exception.Message)"
    }

    Write-IntuneOpsLog -Message "Created proactive remediation '$($Action.DisplayName)' (id=$($created.id))." -Level Success
    return $created
}
