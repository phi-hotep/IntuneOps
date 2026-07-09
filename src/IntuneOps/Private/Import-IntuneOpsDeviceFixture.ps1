# Purpose: PRIVATE. Load raw managedDevice objects from a JSON fixture file for the offline mock data source. Pure file I/O: no Graph, no SDK requirement.

function Import-IntuneOpsDeviceFixture {
    <#
    .SYNOPSIS
        Loads raw managedDevice objects from a JSON fixture file for the mock data source.

    .DESCRIPTION
        Backs Get-IntuneOpsDevice -GraphDataSourceMock. Reads a fixture file shaped like a Graph
        managedDevices list response ({ "value": [ ... ] }) or a bare JSON array of devices, and
        returns the raw device objects exactly as a live query would hand them to
        ConvertTo-IntuneOpsDeviceModel. A fixture device may carry an inline windowsProtectionState
        object (mirroring the navigation property the live path reads with a separate per-device
        call); Get-IntuneOpsDevice lifts it out so the model sees the same two inputs either way.

        Pure file I/O: no Graph calls and no Graph SDK requirement, so the mock path imports and
        runs on a machine with neither installed.

    .PARAMETER FixturePath
        Path to the fixture JSON file. Defaults to
        tests/fixtures/managedDevices/managedDevices.mock.json under the repository root.

    .EXAMPLE
        $raw = Import-IntuneOpsDeviceFixture
        Loads the shipped default fixture set.

    .EXAMPLE
        $raw = Import-IntuneOpsDeviceFixture -FixturePath ./tests/fixtures/managedDevices/custom.json

    .OUTPUTS
        PSCustomObject[] raw managedDevice objects (Graph schema property names and casing).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$FixturePath
    )

    if (-not $FixturePath) {
        $repoRoot = Split-Path -Path $script:IntuneOpsModuleRoot -Parent | Split-Path -Parent
        $FixturePath = Join-Path -Path $repoRoot -ChildPath 'tests/fixtures/managedDevices/managedDevices.mock.json'
    }

    if (-not (Test-Path -LiteralPath $FixturePath)) {
        throw "Device fixture file not found: '$FixturePath'. Ship one under tests/fixtures/managedDevices/ or pass -FixturePath."
    }

    try {
        # -NoEnumerate keeps a top-level JSON array an array even with a single element (the
        # pipeline would otherwise unwrap it to a bare object).
        $parsed = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json -NoEnumerate
    }
    catch {
        throw "Failed to parse device fixture '$FixturePath': $($_.Exception.Message)"
    }

    # Accept either a Graph-style list response or a bare array of devices.
    $devices = if ($parsed -is [System.Array]) {
        @($parsed)
    }
    elseif ($parsed.PSObject.Properties['value']) {
        @($parsed.value)
    }
    else {
        throw "Device fixture '$FixturePath' is neither a JSON array nor a list response with a 'value' property."
    }

    Write-IntuneOpsLog -Message "Loaded $($devices.Count) mock device(s) from fixture: $FixturePath" -Level Info
    return $devices
}
