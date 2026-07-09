# Purpose: PRIVATE. Decide the auth strategy from settings/env/Automation vars and build the Connect-MgGraph splat. Never logs or serializes secret material.

function Resolve-IntuneOpsAuth {
    <#
    .SYNOPSIS
        Resolves the authentication strategy and returns a Connect-MgGraph parameter splat.

    .DESCRIPTION
        The single auth-decision point for IntuneOps. Both the local developer path
        (device-code / interactive) and the unattended Azure Automation path (managed identity)
        flow through this one function, which returns a hashtable to splat directly onto
        Connect-MgGraph. Keeping the branching here means Connect-IntuneOps has exactly one code
        path: resolve, then connect.

        Supported modes:
          - DeviceCode      : delegated, browser-free device code flow (default for local dev).
          - Interactive     : delegated, interactive browser sign-in.
          - ManagedIdentity : app-only, system-assigned managed identity (Azure Automation).
          - AppCertificate  : app-only, certificate in the local store (documented fallback).
          - AppSecret       : app-only, client secret (discouraged; supported for throwaway apps).

        Identifiers are read from parameters first, then environment variables
        (INTUNEOPS_TENANT_ID, INTUNEOPS_CLIENT_ID, INTUNEOPS_CERT_THUMBPRINT, INTUNEOPS_AUTH_MODE).
        Secret material is never returned in a loggable form: a client secret, if used, is
        converted to a credential object and is not echoed. This function returns metadata about
        the chosen mode alongside the splat so the caller can log the mode (not the secret).

        Delegated modes receive the read-only -Scopes set. App-only modes (managed identity,
        certificate, secret) do NOT pass -Scopes: their permissions are pre-consented app roles
        on the service principal, so passing scopes is both unnecessary and unsupported.

    .PARAMETER AuthMode
        Override the auth mode. Defaults to $env:INTUNEOPS_AUTH_MODE, then 'DeviceCode'.

    .PARAMETER TenantId
        Entra tenant id. Defaults to $env:INTUNEOPS_TENANT_ID. Not required for ManagedIdentity.

    .PARAMETER ClientId
        App registration (client) id. Defaults to $env:INTUNEOPS_CLIENT_ID. Optional for the
        delegated modes (the Graph SDK first-party app is used if omitted); required for
        AppCertificate and AppSecret.

    .PARAMETER CertificateThumbprint
        Thumbprint of a certificate in the current user / local machine store. Required for
        AppCertificate. Defaults to $env:INTUNEOPS_CERT_THUMBPRINT.

    .PARAMETER Scopes
        Delegated scopes to request. Applied only to DeviceCode / Interactive modes.

    .EXAMPLE
        $auth = Resolve-IntuneOpsAuth -AuthMode DeviceCode -Scopes $scopes
        Connect-MgGraph @($auth.ConnectSplat)

    .EXAMPLE
        $auth = Resolve-IntuneOpsAuth -AuthMode ManagedIdentity

    .OUTPUTS
        PSCustomObject with: Mode, IsAppOnly, ConnectSplat (hashtable), Description.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateSet('DeviceCode', 'Interactive', 'ManagedIdentity', 'AppCertificate', 'AppSecret')]
        [string]$AuthMode = $(if ($env:INTUNEOPS_AUTH_MODE) { $env:INTUNEOPS_AUTH_MODE } else { 'DeviceCode' }),

        [Parameter()]
        [string]$TenantId = $env:INTUNEOPS_TENANT_ID,

        [Parameter()]
        [string]$ClientId = $env:INTUNEOPS_CLIENT_ID,

        [Parameter()]
        [string]$CertificateThumbprint = $env:INTUNEOPS_CERT_THUMBPRINT,

        [Parameter()]
        [string[]]$Scopes
    )

    # Build the Connect-MgGraph splat per mode. NoWelcome keeps unattended logs clean.
    $splat = @{ NoWelcome = $true }
    $isAppOnly = $false

    switch ($AuthMode) {
        'DeviceCode' {
            $splat['UseDeviceCode'] = $true
            if ($Scopes)  { $splat['Scopes']   = $Scopes }
            if ($TenantId){ $splat['TenantId'] = $TenantId }
            if ($ClientId){ $splat['ClientId'] = $ClientId }
            $description = 'Delegated device-code sign-in (local dev).'
        }
        'Interactive' {
            if ($Scopes)  { $splat['Scopes']   = $Scopes }
            if ($TenantId){ $splat['TenantId'] = $TenantId }
            if ($ClientId){ $splat['ClientId'] = $ClientId }
            $description = 'Delegated interactive sign-in (local dev).'
        }
        'ManagedIdentity' {
            # System-assigned managed identity (Azure Automation). No scopes: app roles are
            # pre-assigned to the identity's service principal.
            $splat['Identity'] = $true
            $isAppOnly = $true
            $description = 'App-only via system-assigned managed identity (Azure Automation).'
        }
        'AppCertificate' {
            if (-not $ClientId)              { throw "AuthMode 'AppCertificate' requires -ClientId (or INTUNEOPS_CLIENT_ID)." }
            if (-not $TenantId)              { throw "AuthMode 'AppCertificate' requires -TenantId (or INTUNEOPS_TENANT_ID)." }
            if (-not $CertificateThumbprint) { throw "AuthMode 'AppCertificate' requires -CertificateThumbprint (or INTUNEOPS_CERT_THUMBPRINT)." }
            $splat['ClientId']              = $ClientId
            $splat['TenantId']              = $TenantId
            $splat['CertificateThumbprint'] = $CertificateThumbprint
            $isAppOnly = $true
            $description = 'App-only via certificate (documented fallback).'
        }
        'AppSecret' {
            if (-not $ClientId) { throw "AuthMode 'AppSecret' requires -ClientId (or INTUNEOPS_CLIENT_ID)." }
            if (-not $TenantId) { throw "AuthMode 'AppSecret' requires -TenantId (or INTUNEOPS_TENANT_ID)." }
            $secret = $env:INTUNEOPS_CLIENT_SECRET
            if (-not $secret) { throw "AuthMode 'AppSecret' requires the INTUNEOPS_CLIENT_SECRET environment variable (git-ignored .env only)." }
            # Convert the secret to a PSCredential immediately so it is never returned as a bare
            # string and never lands in a log. The client id is the credential username.
            $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
            $splat['ClientSecretCredential'] = [System.Management.Automation.PSCredential]::new($ClientId, $secure)
            $splat['TenantId'] = $TenantId
            $isAppOnly = $true
            $description = 'App-only via client secret (discouraged; throwaway apps only).'
        }
    }

    [pscustomobject]@{
        Mode        = $AuthMode
        IsAppOnly   = $isAppOnly
        ConnectSplat = $splat
        Description = $description
    }
}
