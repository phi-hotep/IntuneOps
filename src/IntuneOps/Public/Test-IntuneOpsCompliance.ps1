# Purpose: PUBLIC. Evaluate a device model against loaded rules and emit the normalized compliance result (per-check status + reasons + overall). Pure/deterministic, no Graph calls.

function Test-IntuneOpsCompliance {
    <#
    .SYNOPSIS
        Evaluates a normalized device model against the compliance rules and returns the canonical
        compliance result object.

    .DESCRIPTION
        Runs each enabled check (disk encryption, OS version, antivirus) and assembles a single
        normalized result object per device. This function is pure and deterministic: it performs
        no Graph calls and no I/O, so it is fully unit-testable with synthetic device models. That
        canonical object is the single source of truth used later for JSON and CSV reporting.

        Overall status precedence: NonCompliant beats Unknown beats Compliant. A device with any
        failing check is NonCompliant; with no failures but any unreadable signal it is Unknown;
        only all-Compliant checks yield Compliant. Checks disabled in the rules are skipped and do
        not affect the overall status.

    .PARAMETER Device
        A normalized device model (from Get-IntuneOpsDevice / ConvertTo-IntuneOpsDeviceModel).
        Accepts pipeline input so a device array can be piped straight in.

    .PARAMETER Rules
        The parsed compliance rules object (config.Rules), containing the 'checks' node.

    .EXAMPLE
        $results = $devices | Test-IntuneOpsCompliance -Rules $config.Rules

    .EXAMPLE
        $result = Test-IntuneOpsCompliance -Device $model -Rules $config.Rules

    .OUTPUTS
        PSCustomObject: DeviceId, DeviceName, OwnerUpn, Platform, OsVersion, Checks[], OverallStatus,
        Reasons[], EvaluatedAt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Device,

        [Parameter(Mandatory)]
        [object]$Rules
    )

    process {
        $checks = $Rules.checks
        $results = [System.Collections.Generic.List[object]]::new()

        # Disk encryption
        if ($checks.diskEncryption.enabled) {
            $results.Add((Test-DiskEncryption -Device $Device -Rule $checks.diskEncryption))
        }
        # OS version
        if ($checks.osVersion.enabled) {
            $results.Add((Test-OSVersion -Device $Device -Rule $checks.osVersion))
        }
        # Antivirus
        if ($checks.antivirus.enabled) {
            $results.Add((Test-Antivirus -Device $Device -Rule $checks.antivirus))
        }

        $checkArray = $results.ToArray()

        # Roll up overall status with NonCompliant > Unknown > Compliant precedence.
        $statuses = @($checkArray | ForEach-Object { $_.Status })
        $overall =
            if ($statuses -contains 'NonCompliant') { 'NonCompliant' }
            elseif ($statuses -contains 'Unknown')  { 'Unknown' }
            elseif ($statuses.Count -eq 0)          { 'Unknown' }  # no enabled checks
            else                                    { 'Compliant' }

        # Reasons: the message from every check that is not compliant.
        $reasons = @(
            $checkArray |
                Where-Object { $_.Status -ne 'Compliant' } |
                ForEach-Object { "[$($_.Check)] $($_.Reason)" }
        )

        [pscustomobject]@{
            DeviceId      = $Device.DeviceId
            DeviceName    = $Device.DeviceName
            OwnerUpn      = $Device.OwnerUpn
            Platform      = $Device.Platform
            OsVersion     = $Device.OsVersion
            Checks        = $checkArray
            OverallStatus = $overall
            Reasons       = $reasons
            EvaluatedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        }
    }
}
