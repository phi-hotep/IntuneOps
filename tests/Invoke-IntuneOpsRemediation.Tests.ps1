# Purpose: Pester tests for remediation action selection and the dry-run/execute/WhatIf branching, with Graph calls mocked. Asserts no mutation without -Execute.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1') -Force

    # Use the real rules (diskEncryption=Automated, osVersion/antivirus=Nudge) and real script files
    # so ScriptsExist resolves true, but drive it with synthetic compliance results.
    $rules = Get-Content (Join-Path $repoRoot 'config/compliance-rules.json') -Raw | ConvertFrom-Json
    $script:Config = [pscustomobject]@{ Rules = $rules; RepositoryRoot = $repoRoot }

    # Silence the module logger so test output stays clean (private function, mock via -ModuleName).
    Mock -ModuleName IntuneOps Write-IntuneOpsLog { }

    function New-Result {
        param(
            [string]$EncStatus = 'NonCompliant',
            [string]$OsStatus  = 'Compliant',
            [string]$Name      = 'PC1',
            [string]$Id        = 'dev-1'
        )
        [pscustomobject]@{
            DeviceId      = $Id
            DeviceName    = $Name
            OwnerUpn      = 'user@contoso.onmicrosoft.com'
            Platform      = 'Windows'
            OsVersion     = '10.0.19045.4046'
            Checks        = @(
                [pscustomobject]@{ Check = 'DiskEncryption'; Status = $EncStatus; Reason = 'enc reason'; SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'OSVersion';      Status = $OsStatus;  Reason = 'os reason';  SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'Antivirus';      Status = 'Unknown';  Reason = 'av reason';  SignalSource = 'Unavailable' }
            )
            OverallStatus = 'NonCompliant'
            Reasons       = @()
            EvaluatedAt   = 'now'
        }
    }
}

Describe 'Resolve-IntuneOpsRemediationPlan (pure)' {

    It 'emits one aggregate Automated action for a failing Automated check' {
        InModuleScope IntuneOps -Parameters @{ cfg = $script:Config } {
            param($cfg)
            $r1 = [pscustomobject]@{ DeviceId='d1'; DeviceName='P1'; OwnerUpn='a@x'; Checks=@([pscustomobject]@{Check='DiskEncryption';Status='NonCompliant';Reason='x'}) }
            $r2 = [pscustomobject]@{ DeviceId='d2'; DeviceName='P2'; OwnerUpn='b@x'; Checks=@([pscustomobject]@{Check='DiskEncryption';Status='NonCompliant';Reason='x'}) }
            $plan = Resolve-IntuneOpsRemediationPlan -Results @($r1, $r2) -Config $cfg
            $auto = @($plan | Where-Object Kind -eq 'Automated')
            $auto.Count | Should -Be 1
            $auto[0].Check | Should -Be 'DiskEncryption'
            $auto[0].AffectedDeviceCount | Should -Be 2
            $auto[0].ScriptsExist | Should -BeTrue
        }
    }

    It 'emits per-device Nudge actions for a failing Nudge check' {
        InModuleScope IntuneOps -Parameters @{ cfg = $script:Config } {
            param($cfg)
            $r = [pscustomobject]@{ DeviceId='d1'; DeviceName='P1'; OwnerUpn='a@x'; Checks=@([pscustomobject]@{Check='OSVersion';Status='NonCompliant';Reason='old os'}) }
            $plan = Resolve-IntuneOpsRemediationPlan -Results @($r) -Config $cfg
            $nudge = @($plan | Where-Object Kind -eq 'Nudge')
            $nudge.Count | Should -Be 1
            $nudge[0].Check | Should -Be 'OSVersion'
            $nudge[0].Reason | Should -Be 'old os'
        }
    }

    It 'emits nothing when no check is non-compliant' {
        InModuleScope IntuneOps -Parameters @{ cfg = $script:Config } {
            param($cfg)
            $r = [pscustomobject]@{ DeviceId='d1'; DeviceName='P1'; OwnerUpn='a@x'; Checks=@([pscustomobject]@{Check='DiskEncryption';Status='Compliant';Reason=''}) }
            $plan = Resolve-IntuneOpsRemediationPlan -Results @($r) -Config $cfg
            @($plan).Count | Should -Be 0
        }
    }
}

Describe 'Invoke-IntuneOpsRemediation dry-run (default)' {

    BeforeEach {
        Mock -ModuleName IntuneOps Get-IntuneOpsHealthScript { $null }
        Mock -ModuleName IntuneOps New-IntuneOpsHealthScript { @{ id = 'new-1' } }
        Mock -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment { [pscustomobject]@{ AssignmentResult = 'Assigned'; TargetType = 'AllDevices' } }
    }

    It 'makes ZERO state-changing Graph calls' {
        $result = New-Result -EncStatus 'NonCompliant' -OsStatus 'NonCompliant'
        $null = @($result | Invoke-IntuneOpsRemediation -Config $script:Config)
        Should -Invoke -ModuleName IntuneOps New-IntuneOpsHealthScript -Times 0 -Exactly
        Should -Invoke -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment -Times 0 -Exactly
        Should -Invoke -ModuleName IntuneOps Get-IntuneOpsHealthScript -Times 0 -Exactly
    }

    It 'reports WouldCreateAndAssign and WouldNudge outcomes' {
        $result = New-Result -EncStatus 'NonCompliant' -OsStatus 'NonCompliant'
        $outcomes = @($result | Invoke-IntuneOpsRemediation -Config $script:Config)
        ($outcomes | Where-Object Kind -eq 'Automated').Result | Should -Be 'WouldCreateAndAssign'
        ($outcomes | Where-Object Kind -eq 'Nudge').Result      | Should -Be 'WouldNudge'
        $outcomes | ForEach-Object { $_.Mode | Should -Be 'DryRun' }
    }
}

Describe 'Invoke-IntuneOpsRemediation -Execute' {

    It 'creates then assigns when the script does not yet exist' {
        Mock -ModuleName IntuneOps Get-IntuneOpsHealthScript { $null }
        Mock -ModuleName IntuneOps New-IntuneOpsHealthScript { @{ id = 'new-1' } }
        Mock -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment { [pscustomobject]@{ AssignmentResult = 'Assigned'; TargetType = 'AllDevices' } }

        $result = New-Result -EncStatus 'NonCompliant' -OsStatus 'Compliant'
        $outcomes = @($result | Invoke-IntuneOpsRemediation -Config $script:Config -Execute)

        Should -Invoke -ModuleName IntuneOps New-IntuneOpsHealthScript -Times 1 -Exactly
        Should -Invoke -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment -Times 1 -Exactly
        ($outcomes | Where-Object Kind -eq 'Automated').Result | Should -Be 'Created+Assigned'
    }

    It 'is idempotent: reuses an existing script instead of creating a duplicate' {
        Mock -ModuleName IntuneOps Get-IntuneOpsHealthScript { @{ id = 'existing-1' } }
        Mock -ModuleName IntuneOps New-IntuneOpsHealthScript { @{ id = 'should-not-be-called' } }
        Mock -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment { [pscustomobject]@{ AssignmentResult = 'AlreadyAssigned'; TargetType = 'AllDevices' } }

        $result = New-Result -EncStatus 'NonCompliant' -OsStatus 'Compliant'
        $outcomes = @($result | Invoke-IntuneOpsRemediation -Config $script:Config -Execute)

        Should -Invoke -ModuleName IntuneOps New-IntuneOpsHealthScript -Times 0 -Exactly
        ($outcomes | Where-Object Kind -eq 'Automated').Result | Should -Be 'AlreadyExists+AlreadyAssigned'
    }
}

Describe 'Invoke-IntuneOpsRemediation -Execute -WhatIf' {

    It 'short-circuits every write even with -Execute' {
        Mock -ModuleName IntuneOps Get-IntuneOpsHealthScript { $null }
        Mock -ModuleName IntuneOps New-IntuneOpsHealthScript { @{ id = 'new-1' } }
        Mock -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment { [pscustomobject]@{ AssignmentResult = 'Assigned'; TargetType = 'AllDevices' } }

        $result = New-Result -EncStatus 'NonCompliant' -OsStatus 'Compliant'
        $outcomes = @($result | Invoke-IntuneOpsRemediation -Config $script:Config -Execute -WhatIf)

        Should -Invoke -ModuleName IntuneOps Get-IntuneOpsHealthScript -Times 0 -Exactly
        Should -Invoke -ModuleName IntuneOps New-IntuneOpsHealthScript -Times 0 -Exactly
        Should -Invoke -ModuleName IntuneOps Set-IntuneOpsHealthScriptAssignment -Times 0 -Exactly
        ($outcomes | Where-Object Kind -eq 'Automated').Result | Should -Be 'SkippedByWhatIf'
    }
}
