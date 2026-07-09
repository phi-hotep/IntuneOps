# Purpose: PRIVATE. Single check: compare device OS version to the configured per-platform minimum and return status + reason.

function Test-OSVersion {
    <#
    .SYNOPSIS
        Evaluates the OS-version compliance check for one device model.

    .DESCRIPTION
        Compares the device's OS version against the configured minimum for its platform
        (checks.osVersion.minimumByPlatform). Version strings are parsed leniently: values like
        '13' or '17.0' are padded to a comparable [version]. If the platform has no configured
        minimum, or either version cannot be parsed, the status is 'Unknown' rather than a guess.

    .PARAMETER Device
        A normalized device model from ConvertTo-IntuneOpsDeviceModel.

    .PARAMETER Rule
        The osVersion node from the compliance rules (checks.osVersion).

    .EXAMPLE
        $r = Test-OSVersion -Device $model -Rule $config.Rules.checks.osVersion

    .OUTPUTS
        PSCustomObject: Check, Status, Reason, SignalSource, Expected, Actual.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Device,

        [Parameter(Mandatory)]
        [object]$Rule
    )

    # Lenient version parser: pad to at least major.minor so single-segment values parse.
    function ConvertTo-ComparableVersion {
        param([string]$Value)
        if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
        $clean = ($Value -replace '[^0-9\.]', '').Trim('.')
        if ([string]::IsNullOrWhiteSpace($clean)) { return $null }
        $parts = $clean.Split('.')
        while ($parts.Count -lt 2) { $parts += '0' }
        try { return [version]($parts -join '.') } catch { return $null }
    }

    $platform = $Device.Platform
    $minimumRaw = $null
    if ($Rule.PSObject.Properties['minimumByPlatform']) {
        $mp = $Rule.minimumByPlatform
        # JSON keys are case-sensitive on the object; match case-insensitively to the platform label.
        $match = $mp.PSObject.Properties | Where-Object { $_.Name -ieq $platform } | Select-Object -First 1
        if ($match) { $minimumRaw = [string]$match.Value }
    }

    if (-not $minimumRaw) {
        return [pscustomobject]@{
            Check        = 'OSVersion'
            Status       = 'Unknown'
            Reason       = "No minimum OS version configured for platform '$platform'."
            SignalSource = 'Config'
            Expected     = $null
            Actual       = $Device.OsVersion
        }
    }

    $minVersion = ConvertTo-ComparableVersion $minimumRaw
    $devVersion = ConvertTo-ComparableVersion $Device.OsVersion

    if ($null -eq $minVersion -or $null -eq $devVersion) {
        return [pscustomobject]@{
            Check        = 'OSVersion'
            Status       = 'Unknown'
            Reason       = "Could not compare OS version (device='$($Device.OsVersion)', minimum='$minimumRaw')."
            SignalSource = 'Graph'
            Expected     = $minimumRaw
            Actual       = $Device.OsVersion
        }
    }

    if ($devVersion -ge $minVersion) {
        $status = 'Compliant'
        $reason = "OS version $($Device.OsVersion) meets minimum $minimumRaw."
    }
    else {
        $status = 'NonCompliant'
        $reason = "OS version $($Device.OsVersion) is below minimum $minimumRaw."
    }

    [pscustomobject]@{
        Check        = 'OSVersion'
        Status       = $status
        Reason       = $reason
        SignalSource = 'Graph'
        Expected     = $minimumRaw
        Actual       = $Device.OsVersion
    }
}
