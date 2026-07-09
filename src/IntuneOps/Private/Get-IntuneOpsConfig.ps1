# Purpose: PRIVATE. Load and validate compliance-rules.json and settings.psd1, apply defaults, and fail fast on schema errors.

function Get-IntuneOpsConfig {
    <#
    .SYNOPSIS
        Loads and validates IntuneOps configuration (settings + compliance rules).

    .DESCRIPTION
        Reads the runtime settings (.psd1) and the data-driven compliance rules (.json), validates
        the essentials, applies defaults, and returns a single merged configuration object. Fails
        fast with an actionable message when a file is missing or a required field is malformed,
        rather than letting a bad rule surface later as a wrong compliance verdict.

        Only non-sensitive configuration lives in these files. Identifiers and secrets are resolved
        separately by Resolve-IntuneOpsAuth from environment / Automation variables.

    .PARAMETER SettingsPath
        Path to the settings .psd1 file (e.g. config/settings.psd1 or the shipped
        settings.example.psd1).

    .PARAMETER RulesPath
        Optional explicit path to compliance-rules.json. If omitted, the RulesPath from settings is
        used, resolved relative to the repository root.

    .PARAMETER RepositoryRoot
        Repository root used to resolve relative paths in settings. Defaults to two levels above the
        module folder.

    .EXAMPLE
        $config = Get-IntuneOpsConfig -SettingsPath ./config/settings.example.psd1

    .OUTPUTS
        PSCustomObject with: Settings (hashtable), Rules (object), RulesPath, SettingsPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SettingsPath,

        [Parameter()]
        [string]$RulesPath,

        [Parameter()]
        [string]$RepositoryRoot = (Split-Path -Path $script:IntuneOpsModuleRoot -Parent | Split-Path -Parent)
    )

    if (-not (Test-Path -LiteralPath $SettingsPath)) {
        throw "Settings file not found: '$SettingsPath'. Copy config/settings.example.psd1 and adjust."
    }

    try {
        $settings = Import-PowerShellDataFile -LiteralPath $SettingsPath
    }
    catch {
        throw "Failed to parse settings file '$SettingsPath': $($_.Exception.Message)"
    }

    # Resolve the rules path: explicit parameter wins, else the setting, resolved against the root.
    if (-not $RulesPath) {
        if (-not $settings.ContainsKey('RulesPath')) {
            throw "Settings file '$SettingsPath' does not define 'RulesPath' and no -RulesPath was supplied."
        }
        $RulesPath = if ([System.IO.Path]::IsPathRooted($settings.RulesPath)) {
            $settings.RulesPath
        } else {
            Join-Path -Path $RepositoryRoot -ChildPath $settings.RulesPath
        }
    }

    if (-not (Test-Path -LiteralPath $RulesPath)) {
        throw "Compliance rules file not found: '$RulesPath'."
    }

    try {
        $rules = Get-Content -LiteralPath $RulesPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Failed to parse compliance rules '$RulesPath': $($_.Exception.Message)"
    }

    # Minimal schema validation: the three known checks must exist as objects. Unknown extra keys
    # are tolerated so the schema can grow without breaking older code.
    if (-not $rules.PSObject.Properties['checks']) {
        throw "Compliance rules '$RulesPath' is missing the top-level 'checks' object."
    }
    foreach ($required in 'diskEncryption', 'osVersion', 'antivirus') {
        if (-not $rules.checks.PSObject.Properties[$required]) {
            throw "Compliance rules '$RulesPath' is missing checks.$required."
        }
    }

    Write-IntuneOpsLog -Message "Loaded configuration (settings: $SettingsPath, rules: $RulesPath)." -Level Info

    [pscustomobject]@{
        Settings       = $settings
        Rules          = $rules
        RulesPath      = $RulesPath
        SettingsPath   = $SettingsPath
        RepositoryRoot = $RepositoryRoot
    }
}
