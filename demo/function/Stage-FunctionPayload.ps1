# Purpose: DEMO. Stage the pipeline payload (module, config, templates, fixtures) into the
# Function app folder so `func azure functionapp publish` ships a self-contained app. The staged
# copy (demo/function/IntuneOps/) is git-ignored; re-run this after any pipeline change and before
# every publish. Local `func start` does not need it: run.ps1 falls back to the repo root.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appRoot  = $PSScriptRoot
$repoRoot = Split-Path -Path (Split-Path -Path $appRoot -Parent) -Parent
$target   = Join-Path $appRoot 'IntuneOps'

if (Test-Path -LiteralPath $target) {
    Remove-Item -LiteralPath $target -Recurse -Force
}

# Mirror the repo layout so every relative-path default inside the module keeps working
# (RulesPath, remediation script paths, templates, fixtures all resolve against this root).
$folders = @(
    'src/IntuneOps'
    'config'
    'templates'
    'tests/fixtures/managedDevices'
)

foreach ($folder in $folders) {
    $source      = Join-Path $repoRoot $folder
    $destination = Join-Path $target $folder
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Expected pipeline folder not found: '$source'. Run this script from a full checkout."
    }
    New-Item -Path (Split-Path -Path $destination -Parent) -ItemType Directory -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Recurse
}

Write-Host "Staged pipeline payload into '$target'. Publish with: func azure functionapp publish <app-name>"
