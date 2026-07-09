# Purpose: PUBLIC. Establish a Microsoft Graph session using the resolved auth path (device-code local / managed identity Automation) with least-privilege read-only scopes.

function Connect-IntuneOps {
    <#
    .SYNOPSIS
        Connects to Microsoft Graph for IntuneOps using the resolved auth strategy.

    .DESCRIPTION
        Thin, single-path wrapper over Resolve-IntuneOpsAuth + Connect-MgGraph. The same code
        path serves both local development (delegated device-code / interactive) and unattended
        Azure Automation (app-only managed identity): the only thing that changes is the auth
        mode fed to Resolve-IntuneOpsAuth.

        Phase 1 is strictly read-only. The default scope set contains ONLY read scopes
        (DeviceManagementManagedDevices.Read.All, DeviceManagementConfiguration.Read.All). No
        write scope is requested here; write scopes arrive with the remediation and notification
        phases. Scopes apply to delegated modes only; app-only modes rely on pre-assigned app
        roles.

        Requires the Microsoft.Graph.Authentication module. If it is not present, an actionable
        error is thrown rather than a raw command-not-found.

    .PARAMETER AuthMode
        Auth mode to use. Passed through to Resolve-IntuneOpsAuth. Defaults to
        $env:INTUNEOPS_AUTH_MODE, then 'DeviceCode'.

    .PARAMETER TenantId
        Entra tenant id. Defaults to $env:INTUNEOPS_TENANT_ID.

    .PARAMETER ClientId
        App registration (client) id. Defaults to $env:INTUNEOPS_CLIENT_ID.

    .PARAMETER CertificateThumbprint
        Certificate thumbprint for AppCertificate mode. Defaults to $env:INTUNEOPS_CERT_THUMBPRINT.

    .PARAMETER Scopes
        Override the delegated scope set. Defaults to the Phase 1 read-only scopes. Ignored for
        app-only modes.

    .EXAMPLE
        Connect-IntuneOps
        Connects using device-code flow with the default read-only scopes.

    .EXAMPLE
        Connect-IntuneOps -AuthMode ManagedIdentity
        Connects app-only from an Azure Automation runbook.

    .OUTPUTS
        PSCustomObject summarising the established context (Account, AppName, TenantId, Scopes,
        AuthType). Never includes secret material.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('DeviceCode', 'Interactive', 'ManagedIdentity', 'AppCertificate', 'AppSecret')]
        [string]$AuthMode,

        [Parameter()]
        [string]$TenantId,

        [Parameter()]
        [string]$ClientId,

        [Parameter()]
        [string]$CertificateThumbprint,

        [Parameter()]
        [string[]]$Scopes = $script:IntuneOpsDefaultScopes
    )

    # Verify the SDK is available before we try to call it, so the failure is actionable.
    if (-not (Get-Command -Name 'Connect-MgGraph' -ErrorAction SilentlyContinue)) {
        throw "Microsoft.Graph.Authentication is not available. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }

    # Forward only the parameters the caller actually set so Resolve-IntuneOpsAuth can apply its
    # env-var defaults for the rest.
    $resolveParams = @{ Scopes = $Scopes }
    foreach ($name in 'AuthMode', 'TenantId', 'ClientId', 'CertificateThumbprint') {
        if ($PSBoundParameters.ContainsKey($name)) { $resolveParams[$name] = $PSBoundParameters[$name] }
    }

    $auth = Resolve-IntuneOpsAuth @resolveParams
    Write-IntuneOpsLog -Message "Connecting to Microsoft Graph: $($auth.Description)" -Level Info

    try {
        Connect-MgGraph @($auth.ConnectSplat) | Out-Null
    }
    catch {
        Write-IntuneOpsLog -Message "Graph connection failed: $($_.Exception.Message)" -Level Error
        throw
    }

    $context = Get-MgContext
    if (-not $context) {
        throw "Connect-MgGraph returned no context; authentication did not complete."
    }

    Write-IntuneOpsLog -Message "Connected to Graph (tenant $($context.TenantId), auth $($context.AuthType))." -Level Success

    [pscustomobject]@{
        Account   = $context.Account
        AppName   = $context.AppName
        TenantId  = $context.TenantId
        Scopes    = $context.Scopes
        AuthType  = $context.AuthType
        Mode      = $auth.Mode
        IsAppOnly = $auth.IsAppOnly
    }
}
