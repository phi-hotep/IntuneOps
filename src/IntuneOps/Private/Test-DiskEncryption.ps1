# Purpose: PRIVATE. Single check: interpret the per-platform disk-encryption signal (BitLocker/FileVault) and return status + reason + signal source.

function Test-DiskEncryption {
    <#
    .SYNOPSIS
        Evaluates the disk-encryption compliance check for one device model.

    .DESCRIPTION
        Interprets the normalized IsEncrypted signal (surfaced by Graph as BitLocker on Windows and
        FileVault on macOS). Returns a check-result object rather than a bare boolean so the reason
        and the signal source travel with the verdict. When the signal is unavailable the status is
        'Unknown' (never silently Compliant or NonCompliant).

    .PARAMETER Device
        A normalized device model from ConvertTo-IntuneOpsDeviceModel.

    .PARAMETER Rule
        The diskEncryption node from the compliance rules (checks.diskEncryption).

    .EXAMPLE
        $r = Test-DiskEncryption -Device $model -Rule $config.Rules.checks.diskEncryption

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

    if ($Device.EncryptionSignalSource -eq 'Unavailable' -or $null -eq $Device.IsEncrypted) {
        return [pscustomobject]@{
            Check        = 'DiskEncryption'
            Status       = 'Unknown'
            Reason       = 'Encryption state not reported by Graph for this device.'
            SignalSource = 'Unavailable'
            Expected     = $true
            Actual       = $null
        }
    }

    if ($Device.IsEncrypted) {
        $status = 'Compliant'
        $reason = 'Disk encryption is enabled.'
    }
    else {
        $status = 'NonCompliant'
        $reason = 'Disk encryption is not enabled.'
    }

    [pscustomobject]@{
        Check        = 'DiskEncryption'
        Status       = $status
        Reason       = $reason
        SignalSource = $Device.EncryptionSignalSource
        Expected     = $true
        Actual       = $Device.IsEncrypted
    }
}
