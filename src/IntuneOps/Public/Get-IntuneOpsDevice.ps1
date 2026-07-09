# Purpose: PUBLIC. Query Intune managed devices via Graph and return the normalized device model, flagging real vs unknown/simulated signals.

function Get-IntuneOpsDevice {
    <#
    .SYNOPSIS
        Queries Intune managed devices and returns normalized IntuneOps device models.

    .DESCRIPTION
        Reads managed devices from Microsoft Graph and hands each raw object to
        ConvertTo-IntuneOpsDeviceModel for normalization. For Windows devices it additionally
        attempts to read windowsProtectionState so the antivirus check has a real signal to
        evaluate; when that data is unavailable (common in the free developer tenant) the model
        records the antivirus signal source as 'Unavailable' and the run continues.

        Device inventory is read with the Microsoft.Graph SDK cmdlet
        Get-MgDeviceManagementManagedDevice. The per-device windowsProtectionState is read with a
        RAW Invoke-MgGraphRequest call by design: SDK cmdlet coverage for the protection-state
        navigation property varies across Microsoft.Graph module versions, so a documented raw call
        is more reliable than depending on a cmdlet that may not be present. This is the single
        place in Phase 1 where a raw Graph call is used, and only for a read.

        Degrades gracefully with tiny data volumes: an empty tenant yields an empty result and a
        warning, not an error.

        OFFLINE MOCK SOURCE: with -GraphDataSourceMock the raw devices come from a JSON fixture
        file (Import-IntuneOpsDeviceFixture) instead of live Graph, and no Graph SDK or session is
        required. Everything after the raw read is the identical code path: the same
        ConvertTo-IntuneOpsDeviceModel normalization, the same filters, the same output shape, so
        the evaluator, remediation planner, notifier, and reporter are unaware of the data source.
        A fixture device may embed windowsProtectionState inline; it is lifted out here exactly
        where the live path reads it per device, and an absent or null value keeps the antivirus
        signal honestly 'Unavailable'.

    .PARAMETER Platform
        Optional platform filter (Windows, macOS, iOS, Android). Applied after normalization so the
        label matches the rules file.

    .PARAMETER MaxDevices
        Optional cap on the number of devices returned, for quick dev runs. 0 (default) means no cap.

    .PARAMETER IncludeProtectionState
        Attempt to read windowsProtectionState for Windows devices (default $true). Set to $false to
        skip the extra per-device calls when the antivirus check is disabled.

    .PARAMETER GraphDataSourceMock
        Source raw devices from the JSON fixtures instead of live Graph. No Graph SDK or session is
        required on this path, and no Graph call is made. Downstream behaviour is identical.

    .PARAMETER FixturePath
        Optional explicit fixture file for -GraphDataSourceMock. Defaults to the shipped
        tests/fixtures/managedDevices/managedDevices.mock.json.

    .EXAMPLE
        $devices = Get-IntuneOpsDevice

    .EXAMPLE
        $devices = Get-IntuneOpsDevice -Platform Windows -MaxDevices 25

    .EXAMPLE
        $devices = Get-IntuneOpsDevice -GraphDataSourceMock
        Loads the shipped fixtures; runs fully offline.

    .OUTPUTS
        PSCustomObject[] of normalized device models (see ConvertTo-IntuneOpsDeviceModel).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('Windows', 'macOS', 'iOS', 'Android')]
        [string]$Platform,

        [Parameter()]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$MaxDevices = 0,

        [Parameter()]
        [bool]$IncludeProtectionState = $true,

        [Parameter()]
        [switch]$GraphDataSourceMock,

        [Parameter()]
        [string]$FixturePath
    )

    if ($FixturePath -and -not $GraphDataSourceMock) {
        throw "-FixturePath only applies to the mock data source; pass -GraphDataSourceMock with it."
    }

    if ($GraphDataSourceMock) {
        # Offline mock source: raw devices come from the fixture file. No SDK check, no session
        # check, no Graph call. Everything below this branch is the shared, source-unaware path.
        $fixtureParams = @{}
        if ($FixturePath) { $fixtureParams['FixturePath'] = $FixturePath }
        $rawList = @(Import-IntuneOpsDeviceFixture @fixtureParams)
        Write-IntuneOpsLog -Message 'MOCK data source in use: managed devices are fixtures, not live Graph data.' -Level Warning
    }
    else {
        if (-not (Get-Command -Name 'Get-MgDeviceManagementManagedDevice' -ErrorAction SilentlyContinue)) {
            throw "Microsoft.Graph.DeviceManagement is not available. Install it with: Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser"
        }
        if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
            throw "Not connected to Graph. Call Connect-IntuneOps before Get-IntuneOpsDevice."
        }

        # Request only the properties the pipeline uses (least-data principle and faster queries).
        $selectProps = @(
            'id', 'deviceName', 'userPrincipalName', 'emailAddress', 'operatingSystem', 'osVersion',
            'isEncrypted', 'complianceState', 'managementState', 'lastSyncDateTime', 'manufacturer', 'model'
        )

        Write-IntuneOpsLog -Message 'Querying Intune managed devices...' -Level Info
        try {
            $raw = Get-MgDeviceManagementManagedDevice -All -Property $selectProps -ErrorAction Stop
        }
        catch {
            Write-IntuneOpsLog -Message "Device query failed: $($_.Exception.Message)" -Level Error
            throw
        }

        $rawList = @($raw)
    }

    if ($rawList.Count -eq 0) {
        Write-IntuneOpsLog -Message 'No managed devices returned. Tenant may be empty or newly provisioned.' -Level Warning
        return @()
    }

    $models = [System.Collections.Generic.List[object]]::new()
    foreach ($device in $rawList) {
        $protection = $null

        $osString = [string]$device.OperatingSystem
        $isWindowsDevice = $osString -match 'windows'

        if ($IncludeProtectionState -and $isWindowsDevice) {
            if ($GraphDataSourceMock) {
                # Fixture devices may embed windowsProtectionState inline (the live path reads it
                # per device); an absent or null value keeps the antivirus signal Unavailable.
                $stateProp = $device.PSObject.Properties['windowsProtectionState']
                if ($stateProp -and $null -ne $stateProp.Value) { $protection = $stateProp.Value }
            }
            else {
                # Raw read of the protection-state navigation property (see .DESCRIPTION for why raw).
                try {
                    $uri = "/v1.0/deviceManagement/managedDevices/$($device.Id)/windowsProtectionState"
                    $protection = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                }
                catch {
                    # Missing/forbidden protection state is expected in the dev tenant; keep going and
                    # let the model flag the antivirus signal as Unavailable.
                    Write-IntuneOpsLog -Message "No windowsProtectionState for device $($device.Id): $($_.Exception.Message)" -Level Debug
                    $protection = $null
                }
            }
        }

        $models.Add((ConvertTo-IntuneOpsDeviceModel -Device $device -ProtectionState $protection))
    }

    $result = $models.ToArray()

    if ($Platform) {
        $result = @($result | Where-Object { $_.Platform -eq $Platform })
    }
    if ($MaxDevices -gt 0 -and $result.Count -gt $MaxDevices) {
        $result = @($result | Select-Object -First $MaxDevices)
    }

    Write-IntuneOpsLog -Message "Normalized $($result.Count) device(s)." -Level Success
    return $result
}
