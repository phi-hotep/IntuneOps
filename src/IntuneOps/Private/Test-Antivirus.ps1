# Purpose: PRIVATE. Single check: interpret AV/Defender health signal; return Unknown (flagged) when the dev tenant does not surface it.

function Test-Antivirus {
    <#
    .SYNOPSIS
        Evaluates the antivirus-health compliance check for one device model.

    .DESCRIPTION
        Interprets the normalized AntivirusHealthy signal (derived from windowsProtectionState).
        In the free developer tenant this signal is frequently unavailable; when it is, the status
        is governed by the rule's treatUnknownAs setting (default 'Unknown'), never a silent pass.
        This keeps simulated / missing signals honestly labelled in the output.

    .PARAMETER Device
        A normalized device model from ConvertTo-IntuneOpsDeviceModel.

    .PARAMETER Rule
        The antivirus node from the compliance rules (checks.antivirus). Honors an optional
        treatUnknownAs value of 'Unknown', 'Compliant', or 'NonCompliant'.

    .EXAMPLE
        $r = Test-Antivirus -Device $model -Rule $config.Rules.checks.antivirus

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

    if ($Device.AntivirusSignalSource -eq 'Unavailable' -or $null -eq $Device.AntivirusHealthy) {
        $treatAs = 'Unknown'
        if ($Rule.PSObject.Properties['treatUnknownAs'] -and $Rule.treatUnknownAs) {
            $treatAs = [string]$Rule.treatUnknownAs
        }
        return [pscustomobject]@{
            Check        = 'Antivirus'
            Status       = $treatAs
            Reason       = 'Antivirus health not reported by Graph (signal unavailable in this tenant); applied treatUnknownAs policy.'
            SignalSource = 'Unavailable'
            Expected     = $true
            Actual       = $null
        }
    }

    if ($Device.AntivirusHealthy) {
        $status = 'Compliant'
        $reason = "Antivirus healthy ($($Device.AntivirusDetail))."
    }
    else {
        $status = 'NonCompliant'
        $reason = "Antivirus unhealthy ($($Device.AntivirusDetail))."
    }

    [pscustomobject]@{
        Check        = 'Antivirus'
        Status       = $status
        Reason       = $reason
        SignalSource = $Device.AntivirusSignalSource
        Expected     = $true
        Actual       = $Device.AntivirusHealthy
    }
}
