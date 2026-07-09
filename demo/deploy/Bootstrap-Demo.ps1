# Purpose: DEMO. One-time, idempotent bootstrap for the CI/CD pipeline. Provisions the Azure infra
# (resource group, storage account, Function App), sets CORS for the Cloudflare Pages origin, creates
# the OIDC app registration + federated credential that GitHub Actions signs in with, and prints the
# exact GitHub secrets to set. Safe to re-run: every step checks for the existing resource first.
#
# It does NOT deploy the Function or the page (the pipeline does that on the first run); it only
# creates the app so CORS and the CI key-fetch have a target.
#
# Prerequisites: Azure CLI logged in (az login) with rights to create resources in the subscription
# and to create app registrations + role assignments in the tenant.

<#
.SYNOPSIS
    Provisions the IntuneOps demo Azure infra and GitHub OIDC identity, idempotently.

.EXAMPLE
    az login
    ./demo/deploy/Bootstrap-Demo.ps1 -AppName intuneops-demo -StorageAccount stintuneopsdemo01 -GitHubRepo myuser/intuneops

.NOTES
    The -Branch value MUST match the workflow push trigger in .github/workflows/deploy.yml and the
    repository's real default branch, or the OIDC token exchange will never authorize the workflow.
#>
[CmdletBinding()]
param(
    [string]$AppName = 'intuneops-demo',
    [string]$ResourceGroup = 'rg-intuneops-demo',
    [string]$Location = 'eastus',

    # Storage account name: globally unique, 3-24 chars, lowercase letters and digits only.
    [Parameter(Mandatory)]
    [string]$StorageAccount,

    # GitHub repository in owner/repo form, for the OIDC federated-credential subject.
    [Parameter(Mandatory)]
    [string]$GitHubRepo,

    [string]$Branch = 'master',

    # Cloudflare Pages project name; its origin (https://<project>.pages.dev) is allowed through CORS.
    [string]$PagesProject = 'intuneops-demo',

    # Least-privilege PowerShell runtime the Function targets. The script fails if the plan will not
    # create the app on this version rather than silently accepting a fallback.
    [string]$PowerShellVersion = '7.4'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Az {
    # Thin wrapper so a non-zero az exit code becomes a terminating error with the command shown.
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    $output = & az @AzArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "az $($AzArgs -join ' ') failed: $output"
    }
    return $output
}

function Get-AzText {
    # Runs az and returns a single trimmed string. az emits NOTHING for a tsv query that matches
    # nothing (e.g. listing an app that does not exist yet), so calling .Trim() on the raw result
    # would throw "cannot call a method on a null-valued expression". This coalesces that to ''.
    # Any stderr lines merged in by Invoke-Az's 2>&1 are dropped so only real output is returned.
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $out = Invoke-Az -AzArgs $AzArgs
    if ($null -eq $out) { return '' }
    $text = @($out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    return $text.Trim()
}

function Get-AzJson {
    # Runs az with -o json and parses the result, or returns $null for empty output. Existence
    # checks below fetch JSON and count/match in PowerShell instead of using JMESPath functions
    # like length(@): on Windows az is a batch file, and an unquoted ')' in an argument without
    # spaces is mangled by cmd.exe, corrupting the query.
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $text = Get-AzText -AzArgs $AzArgs
    if (-not $text) { return $null }
    return $text | ConvertFrom-Json
}

Write-Host '== IntuneOps demo bootstrap ==' -ForegroundColor Cyan

# 0) Must be logged in.
$account = Invoke-Az @('account', 'show', '-o', 'json') | ConvertFrom-Json
$subscriptionId = $account.id
$tenantId = $account.tenantId
Write-Host "Subscription: $($account.name) ($subscriptionId)"
Write-Host "Tenant:       $tenantId"

# Branch-consistency warning (amendment 1): the federated subject below pins this branch, and the
# workflow trigger must name it too. Compare against the repo's current local default branch.
$repoBranch = $null
try { $repoBranch = (git -C $PSScriptRoot rev-parse --abbrev-ref HEAD 2>$null) } catch { $repoBranch = $null }
if ($repoBranch -and $repoBranch -ne 'HEAD' -and $repoBranch -ne $Branch) {
    Write-Warning "Repo's current branch is '$repoBranch' but -Branch is '$Branch'. The OIDC federated credential will authorize refs/heads/$Branch only. Rename the branch or re-run with -Branch $repoBranch, and set the same branch in .github/workflows/deploy.yml."
}

# 1) Resource group.
if ((Invoke-Az @('group', 'exists', '-n', $ResourceGroup)) -eq 'true') {
    Write-Host "Resource group '$ResourceGroup' already exists."
} else {
    Invoke-Az @('group', 'create', '-n', $ResourceGroup, '-l', $Location, '-o', 'none') | Out-Null
    Write-Host "Created resource group '$ResourceGroup'."
}

# 2) Storage account (required by the Function App).
$saNames = @(Get-AzJson @('storage', 'account', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'json'))
if ($saNames -contains $StorageAccount) {
    Write-Host "Storage account '$StorageAccount' already exists."
} else {
    $nameCheck = Invoke-Az @('storage', 'account', 'check-name', '-n', $StorageAccount, '-o', 'json') | ConvertFrom-Json
    if (-not $nameCheck.nameAvailable) {
        throw "Storage account name '$StorageAccount' is not available: $($nameCheck.reason). Pick another globally-unique name."
    }
    Invoke-Az @('storage', 'account', 'create', '-n', $StorageAccount, '-g', $ResourceGroup, '-l', $Location, '--sku', 'Standard_LRS', '-o', 'none') | Out-Null
    Write-Host "Created storage account '$StorageAccount'."
}

# 3) Function App (PowerShell, Consumption, Functions v4).
$faNames = @(Get-AzJson @('functionapp', 'list', '-g', $ResourceGroup, '--query', '[].name', '-o', 'json'))
if ($faNames -contains $AppName) {
    Write-Host "Function App '$AppName' already exists."
} else {
    Invoke-Az @(
        'functionapp', 'create', '-n', $AppName, '-g', $ResourceGroup,
        '--storage-account', $StorageAccount, '--consumption-plan-location', $Location,
        '--runtime', 'powershell', '--runtime-version', $PowerShellVersion, '--functions-version', '4',
        '-o', 'none'
    ) | Out-Null
    Write-Host "Created Function App '$AppName'."
}

# 3b) Runtime pin verification (amendment 3): confirm the created app actually runs the version the
# deployed package targets. A created-vs-deployed mismatch is a common green-deploy-then-500 cause.
$createdVersion = Get-AzText @('functionapp', 'config', 'show', '-n', $AppName, '-g', $ResourceGroup, '--query', 'powerShellVersion', '-o', 'tsv')
if ($createdVersion -ne $PowerShellVersion) {
    throw "Function App '$AppName' reports PowerShell '$createdVersion' but the package targets '$PowerShellVersion'. If $PowerShellVersion is no longer offered on the Consumption plan, update the package target and re-run; do not deploy onto a mismatched runtime."
}
Write-Host "Runtime verified: PowerShell $createdVersion."

# 4) CORS for the Cloudflare Pages origin (idempotent add).
$pagesOrigin = "https://$PagesProject.pages.dev"
$currentCors = Invoke-Az @('functionapp', 'cors', 'show', '-n', $AppName, '-g', $ResourceGroup, '-o', 'json') | ConvertFrom-Json
# A fresh app may return an object with no allowedOrigins property (or none at all); accessing a
# missing property throws under Set-StrictMode, so read it through the property-bag indexer (which
# yields $null rather than throwing) before dereferencing.
$allowed = @()
$originsProp = if ($currentCors) { $currentCors.PSObject.Properties['allowedOrigins'] } else { $null }
if ($originsProp -and $originsProp.Value) {
    $allowed = @($originsProp.Value)
}
if ($allowed -contains $pagesOrigin) {
    Write-Host "CORS already allows $pagesOrigin."
} else {
    Invoke-Az @('functionapp', 'cors', 'add', '-n', $AppName, '-g', $ResourceGroup, '--allowed-origins', $pagesOrigin, '-o', 'none') | Out-Null
    Write-Host "Added CORS origin $pagesOrigin."
}

# 5) OIDC app registration + service principal + federated credential.
$oidcAppName = "$AppName-github-oidc"
$existingAppId = Get-AzText @('ad', 'app', 'list', '--display-name', $oidcAppName, '--query', '[0].appId', '-o', 'tsv')
if ($existingAppId) {
    $clientId = $existingAppId
    Write-Host "OIDC app registration '$oidcAppName' already exists (appId $clientId)."
} else {
    $clientId = Get-AzText @('ad', 'app', 'create', '--display-name', $oidcAppName, '--query', 'appId', '-o', 'tsv')
    Write-Host "Created OIDC app registration '$oidcAppName' (appId $clientId)."
}
if (-not $clientId) {
    throw "Could not resolve the OIDC app registration's appId. Check 'az ad app list --display-name $oidcAppName'."
}

# Service principal for the app (idempotent).
$spId = Get-AzText @('ad', 'sp', 'list', '--filter', "appId eq '$clientId'", '--query', '[0].id', '-o', 'tsv')
if (-not $spId) {
    Invoke-Az @('ad', 'sp', 'create', '--id', $clientId, '-o', 'none') | Out-Null
    Write-Host 'Created service principal.'
}

# Contributor scoped to the resource group only (covers site deploy, functions/listkeys, CORS write).
$rgScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup"
$roleIds = @(Get-AzJson @('role', 'assignment', 'list', '--assignee', $clientId, '--scope', $rgScope, '--role', 'Contributor', '--query', '[].id', '-o', 'json'))
if ($roleIds.Count -gt 0) {
    Write-Host 'Contributor role assignment already present on the resource group.'
} else {
    Invoke-Az @('role', 'assignment', 'create', '--assignee', $clientId, '--role', 'Contributor', '--scope', $rgScope, '-o', 'none') | Out-Null
    Write-Host "Assigned Contributor on $ResourceGroup."
}

# Federated credential pinned to this repo + branch (idempotent by name).
$ficName = "github-$Branch"
$ficSubject = "repo:${GitHubRepo}:ref:refs/heads/$Branch"
$ficNames = @(Get-AzJson @('ad', 'app', 'federated-credential', 'list', '--id', $clientId, '--query', '[].name', '-o', 'json'))
if ($ficNames -contains $ficName) {
    Write-Host "Federated credential '$ficName' already exists."
} else {
    $ficJson = @{
        name        = $ficName
        issuer      = 'https://token.actions.githubusercontent.com'
        subject     = $ficSubject
        description = 'GitHub Actions OIDC for the IntuneOps demo pipeline.'
        audiences   = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -LiteralPath $tmp -Value $ficJson -Encoding utf8
    try {
        Invoke-Az @('ad', 'app', 'federated-credential', 'create', '--id', $clientId, '--parameters', $tmp, '-o', 'none') | Out-Null
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Created federated credential '$ficName' (subject $ficSubject)."
}

# 6) Print the GitHub secrets to set.
Write-Host ''
Write-Host '== Set these GitHub Actions secrets (repo Settings > Secrets and variables > Actions) ==' -ForegroundColor Cyan
Write-Host "  AZURE_CLIENT_ID        $clientId"
Write-Host "  AZURE_TENANT_ID        $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID  $subscriptionId"
Write-Host '  CLOUDFLARE_API_TOKEN   <your Cloudflare API token: Account > Cloudflare Pages: Edit, Account Settings: Read>'
Write-Host '  CLOUDFLARE_ACCOUNT_ID  <your Cloudflare account id>'
Write-Host ''
Write-Host "Branch pinned for OIDC: $Branch. Ensure the workflow push trigger and the repo default branch match it." -ForegroundColor Yellow
Write-Host 'Next: push the repo to GitHub, set the secrets above, then push to the branch (or run the workflow manually).'
