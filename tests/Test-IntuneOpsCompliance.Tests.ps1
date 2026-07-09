# Purpose: Pester tests for the compliance evaluator using synthetic device models (encryption/OS/AV pass, fail, and unknown cases). No live Graph.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $modulePath = Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1'
    Import-Module $modulePath -Force

    # Rules mirror config/compliance-rules.json but are defined inline so the tests are hermetic.
    $script:Rules = [pscustomobject]@{
        checks = [pscustomobject]@{
            diskEncryption = [pscustomobject]@{ enabled = $true; action = 'Nudge' }
            osVersion      = [pscustomobject]@{
                enabled = $true; action = 'Nudge'
                minimumByPlatform = [pscustomobject]@{ windows = '10.0.19045'; macOS = '14.0'; iOS = '17.0'; android = '13' }
            }
            antivirus      = [pscustomobject]@{ enabled = $true; action = 'Nudge'; treatUnknownAs = 'Unknown' }
        }
    }

    # Factory for a synthetic normalized device model with sensible compliant defaults.
    function New-TestDevice {
        param(
            [string]$Platform = 'Windows',
            [string]$OsVersion = '10.0.19045.4046',
            [object]$IsEncrypted = $true,
            [string]$EncryptionSignalSource = 'Graph',
            [object]$AntivirusHealthy = $true,
            [string]$AntivirusSignalSource = 'Graph'
        )
        [pscustomobject]@{
            DeviceId               = ([guid]::NewGuid()).ToString()
            DeviceName             = 'TEST-PC'
            OwnerUpn               = 'user@contoso.onmicrosoft.com'
            OwnerEmail             = 'user@contoso.onmicrosoft.com'
            Platform               = $Platform
            OsVersion              = $OsVersion
            IsEncrypted            = $IsEncrypted
            EncryptionSignalSource = $EncryptionSignalSource
            AntivirusHealthy       = $AntivirusHealthy
            AntivirusSignalSource  = $AntivirusSignalSource
            AntivirusDetail        = 'synthetic'
        }
    }
}

Describe 'Test-IntuneOpsCompliance overall roll-up' {

    It 'returns Compliant when every check passes' {
        $device = New-TestDevice
        $result = Test-IntuneOpsCompliance -Device $device -Rules $script:Rules
        $result.OverallStatus | Should -Be 'Compliant'
        $result.Reasons.Count | Should -Be 0
    }

    It 'returns NonCompliant when disk encryption is off' {
        $device = New-TestDevice -IsEncrypted $false
        $result = Test-IntuneOpsCompliance -Device $device -Rules $script:Rules
        $result.OverallStatus | Should -Be 'NonCompliant'
        ($result.Checks | Where-Object Check -eq 'DiskEncryption').Status | Should -Be 'NonCompliant'
    }

    It 'returns NonCompliant when OS version is below the platform minimum' {
        $device = New-TestDevice -OsVersion '10.0.18363.0'
        $result = Test-IntuneOpsCompliance -Device $device -Rules $script:Rules
        ($result.Checks | Where-Object Check -eq 'OSVersion').Status | Should -Be 'NonCompliant'
        $result.OverallStatus | Should -Be 'NonCompliant'
    }

    It 'returns Unknown (not Compliant) when the antivirus signal is unavailable' {
        $device = New-TestDevice -AntivirusHealthy $null -AntivirusSignalSource 'Unavailable'
        $result = Test-IntuneOpsCompliance -Device $device -Rules $script:Rules
        ($result.Checks | Where-Object Check -eq 'Antivirus').Status | Should -Be 'Unknown'
        $result.OverallStatus | Should -Be 'Unknown'
    }

    It 'lets NonCompliant win over Unknown in the overall status' {
        $device = New-TestDevice -IsEncrypted $false -AntivirusHealthy $null -AntivirusSignalSource 'Unavailable'
        $result = Test-IntuneOpsCompliance -Device $device -Rules $script:Rules
        $result.OverallStatus | Should -Be 'NonCompliant'
    }

    It 'accepts pipeline input for a batch of devices' {
        $devices = @((New-TestDevice), (New-TestDevice -IsEncrypted $false))
        $results = @($devices | Test-IntuneOpsCompliance -Rules $script:Rules)
        $results.Count | Should -Be 2
        $results[0].OverallStatus | Should -Be 'Compliant'
        $results[1].OverallStatus | Should -Be 'NonCompliant'
    }
}

Describe 'Individual checks (via InModuleScope)' {

    It 'Test-OSVersion parses single-segment Android versions' {
        InModuleScope IntuneOps {
            $rule = [pscustomobject]@{ minimumByPlatform = [pscustomobject]@{ android = '13' } }
            $device = [pscustomobject]@{ Platform = 'Android'; OsVersion = '12' }
            (Test-OSVersion -Device $device -Rule $rule).Status | Should -Be 'NonCompliant'

            $device2 = [pscustomobject]@{ Platform = 'Android'; OsVersion = '14' }
            (Test-OSVersion -Device $device2 -Rule $rule).Status | Should -Be 'Compliant'
        }
    }

    It 'Test-DiskEncryption flags an unavailable signal as Unknown' {
        InModuleScope IntuneOps {
            $rule = [pscustomobject]@{ enabled = $true }
            $device = [pscustomobject]@{ IsEncrypted = $null; EncryptionSignalSource = 'Unavailable' }
            (Test-DiskEncryption -Device $device -Rule $rule).Status | Should -Be 'Unknown'
        }
    }

    It 'Test-Antivirus honors treatUnknownAs = NonCompliant' {
        InModuleScope IntuneOps {
            $rule = [pscustomobject]@{ treatUnknownAs = 'NonCompliant' }
            $device = [pscustomobject]@{ AntivirusHealthy = $null; AntivirusSignalSource = 'Unavailable'; AntivirusDetail = 'synthetic' }
            (Test-Antivirus -Device $device -Rule $rule).Status | Should -Be 'NonCompliant'
        }
    }
}
