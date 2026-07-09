# Purpose: PRIVATE. Map a raw Graph managedDevice (+ windowsProtectionState) to the normalized device model with signal-source flags.

function ConvertTo-IntuneOpsDeviceModel {
    <#
    .SYNOPSIS
        Normalizes a raw Graph managedDevice (plus optional protection state) into the IntuneOps
        device model.

    .DESCRIPTION
        Flattens the properties IntuneOps cares about into a stable, platform-agnostic object and,
        crucially, records the SOURCE of each compliance signal so downstream checks can tell a
        real reading from a missing one. In the free developer tenant some signals (notably
        antivirus health) are frequently absent; this function marks those 'Unavailable' rather
        than guessing pass or fail.

        The function is pure: it performs no Graph calls. Get-IntuneOpsDevice does the querying and
        hands the raw objects here.

    .PARAMETER Device
        A raw managedDevice object (from Get-MgDeviceManagementManagedDevice or an equivalent raw
        Graph response). Property access is defensive so partial objects do not crash the mapping.

    .PARAMETER ProtectionState
        Optional windowsProtectionState object for the device (Windows only). When supplied, the
        antivirus signal source is 'Graph'; when $null, it is 'Unavailable'.

    .EXAMPLE
        $model = ConvertTo-IntuneOpsDeviceModel -Device $raw -ProtectionState $protection

    .OUTPUTS
        PSCustomObject: the normalized device model.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Device,

        [Parameter()]
        [object]$ProtectionState
    )

    # Defensive accessor: raw Graph objects may be hashtables (from Invoke-MgGraphRequest) or typed
    # SDK objects. This reads a named property from either shape and returns $null if absent.
    function Get-Prop {
        param([object]$Object, [string]$Name)
        if ($null -eq $Object) { return $null }
        if ($Object -is [System.Collections.IDictionary]) {
            if ($Object.Contains($Name)) { return $Object[$Name] }
            return $null
        }
        $prop = $Object.PSObject.Properties[$Name]
        if ($prop) { return $prop.Value }
        return $null
    }

    $rawOs = [string](Get-Prop $Device 'operatingSystem')
    # Normalize the platform label to a small fixed set the rules key off of.
    $platform = switch -Regex ($rawOs) {
        'windows' { 'Windows'; break }
        'macos'   { 'macOS';   break }
        'ios|ipad'{ 'iOS';     break }
        'android' { 'Android'; break }
        default   { if ([string]::IsNullOrWhiteSpace($rawOs)) { 'Unknown' } else { $rawOs } }
    }

    # Disk encryption: managedDevice.isEncrypted is a boolean when present. If the property is
    # entirely absent from the response, the signal is unavailable rather than false.
    $isEncryptedRaw = Get-Prop $Device 'isEncrypted'
    if ($null -eq $isEncryptedRaw) {
        $isEncrypted = $null
        $encryptionSource = 'Unavailable'
    }
    else {
        $isEncrypted = [bool]$isEncryptedRaw
        $encryptionSource = 'Graph'
    }

    # Antivirus health: derived from windowsProtectionState when provided. Healthy means real-time
    # protection on, AV engine enabled, and signatures not overdue. Absent state -> Unavailable.
    if ($null -eq $ProtectionState) {
        $avHealthy = $null
        $avSource  = 'Unavailable'
        $avDetail  = 'No protection state returned by Graph (common in the free dev tenant).'
    }
    else {
        $rtp        = Get-Prop $ProtectionState 'realTimeProtectionEnabled'
        $avEnabled  = Get-Prop $ProtectionState 'antivirusEnabled'
        $sigOverdue = Get-Prop $ProtectionState 'signatureUpdateOverdue'
        $avHealthy  = ([bool]$rtp) -and ([bool]$avEnabled) -and (-not [bool]$sigOverdue)
        $avSource   = 'Graph'
        $avDetail   = "realTimeProtection=$rtp; antivirusEnabled=$avEnabled; signatureUpdateOverdue=$sigOverdue"
    }

    [pscustomobject]@{
        DeviceId               = [string](Get-Prop $Device 'id')
        DeviceName             = [string](Get-Prop $Device 'deviceName')
        OwnerUpn               = [string](Get-Prop $Device 'userPrincipalName')
        OwnerEmail             = [string](Get-Prop $Device 'emailAddress')
        Platform               = $platform
        OsVersion              = [string](Get-Prop $Device 'osVersion')
        IsEncrypted            = $isEncrypted
        EncryptionSignalSource = $encryptionSource
        AntivirusHealthy       = $avHealthy
        AntivirusSignalSource  = $avSource
        AntivirusDetail        = $avDetail
        ComplianceState        = [string](Get-Prop $Device 'complianceState')
        ManagementState        = [string](Get-Prop $Device 'managementState')
        LastSyncDateTime       = Get-Prop $Device 'lastSyncDateTime'
        Manufacturer           = [string](Get-Prop $Device 'manufacturer')
        Model                  = [string](Get-Prop $Device 'model')
    }
}
