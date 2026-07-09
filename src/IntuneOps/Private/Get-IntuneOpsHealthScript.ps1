# Purpose: PRIVATE. Find an existing Intune proactive remediation (deviceHealthScript) by displayName. Read-only. Used for idempotency before create/assign.

function Get-IntuneOpsHealthScript {
    <#
    .SYNOPSIS
        Returns the existing deviceHealthScript with the given displayName, or $null.

    .DESCRIPTION
        Read-only lookup used to make creation idempotent: if a script we manage already exists we
        reuse it rather than creating a duplicate. Uses a RAW Invoke-MgGraphRequest GET by design;
        deviceHealthScript SDK cmdlet coverage varies across Microsoft.Graph versions, so a raw read
        against the documented v1.0 endpoint is the reliable path. Server-side $filter on displayName
        is not consistently supported for this resource, so it filters client-side (the dev tenant
        has a small number of scripts).

    .PARAMETER DisplayName
        The exact displayName to match.

    .EXAMPLE
        $existing = Get-IntuneOpsHealthScript -DisplayName 'IntuneOps - Enable BitLocker (OS volume)'

    .OUTPUTS
        The matching deviceHealthScript object (hashtable) or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    $uri = '/v1.0/deviceManagement/deviceHealthScripts?$select=id,displayName,publisher'
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    }
    catch {
        throw "Failed to list deviceHealthScripts: $($_.Exception.Message)"
    }

    $items = @()
    if ($response -and $response.ContainsKey('value')) { $items = @($response.value) }

    $match = $items | Where-Object { [string]$_.displayName -eq $DisplayName } | Select-Object -First 1
    return $match
}
