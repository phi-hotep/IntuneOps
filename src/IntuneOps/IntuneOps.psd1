# Purpose: PowerShell module manifest for IntuneOps. Declares metadata, exported functions, and Microsoft.Graph module dependencies. Populated in Phase 1.
@{
    RootModule        = 'IntuneOps.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b7d3f6a1-2c48-4e9a-9f15-3a7c8e0d1b62'
    Author            = 'IntuneOps'
    Description       = 'Automated Intune device compliance evaluation and remediation workflow over Microsoft Graph.'
    PowerShellVersion = '7.0'

    # Deliberate soft dependency: the Microsoft.Graph submodules are NOT listed here so the pure
    # compliance-evaluation logic (Test-IntuneOpsCompliance and the Test-* checks) can be imported
    # and unit-tested on a machine without the Graph SDK installed. Functions that actually call
    # Graph (Connect-IntuneOps, Get-IntuneOpsDevice) verify SDK availability at call time and emit
    # an actionable error if a required submodule is missing. Required submodules:
    #   Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
    RequiredModules   = @()

    # Populated from Public/ during Phase 1-3, plus the two operational helpers the thin
    # entrypoints (scripts/, runbooks/) drive directly: the logging sink and the config loader.
    FunctionsToExport = @(
        'Connect-IntuneOps',
        'Get-IntuneOpsDevice',
        'Test-IntuneOpsCompliance',
        'Invoke-IntuneOpsRemediation',
        'Send-IntuneOpsNotification',
        'Write-IntuneOpsReport',
        'Write-IntuneOpsLog',
        'Get-IntuneOpsConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
