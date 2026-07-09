# Purpose: Pester tests for the mock device data source: fixture loading + normalization, the evaluator run directly against the fixtures, and the full mock pipeline in dry-run. No Graph SDK, no session, no mocking of Graph cmdlets required.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1') -Force

    # Silence the module logger so test output stays clean.
    Mock -ModuleName IntuneOps Write-IntuneOpsLog { }

    # The shipped fixtures and the real rules file: the fixtures are deliberately kept consistent
    # with config/compliance-rules.json so the expected results here are deterministic.
    $script:FixturePath = Join-Path $repoRoot 'tests/fixtures/managedDevices/managedDevices.mock.json'
    $rules = Get-Content (Join-Path $repoRoot 'config/compliance-rules.json') -Raw | ConvertFrom-Json
    $script:Config = [pscustomobject]@{
        Rules          = $rules
        RepositoryRoot = $repoRoot
        Settings       = @{ MailSender = 'compliance-bot@contoso.onmicrosoft.com'; UseHtmlEmail = $false; NotificationSubjectTemplate = 'Action required: {{DeviceName}} is not compliant' }
    }

    # One shared pass through the mock source; individual tests assert on slices of it. This runs
    # with no Graph session and no Graph SDK requirement, which is itself part of what is under test.
    $script:Devices = @(Get-IntuneOpsDevice -GraphDataSourceMock)
    $script:Results = @($script:Devices | Test-IntuneOpsCompliance -Rules $rules)

    function Get-ByName {
        param([object[]]$Set, [string]$Name)
        @($Set | Where-Object DeviceName -eq $Name) | Select-Object -First 1
    }
}

Describe 'Get-IntuneOpsDevice -GraphDataSourceMock (offline device source)' {

    It 'loads and normalizes every fixture device without a Graph session' {
        $script:Devices.Count | Should -Be 4
        $script:Devices.DeviceName | Should -Contain 'MOCK-WIN-OK'
        $script:Devices.DeviceName | Should -Contain 'MOCK-WIN-NOENC'
        $script:Devices.DeviceName | Should -Contain 'MOCK-MAC-OLDOS'
        $script:Devices.DeviceName | Should -Contain 'MOCK-WIN-NOAV'
    }

    It 'produces the same normalized model shape as the live path' {
        $ok = Get-ByName $script:Devices 'MOCK-WIN-OK'
        $ok.Platform               | Should -Be 'Windows'
        $ok.OwnerUpn               | Should -Be 'alice.walker@contoso.onmicrosoft.com'
        $ok.IsEncrypted            | Should -BeTrue
        $ok.EncryptionSignalSource | Should -Be 'Graph'
        $ok.AntivirusHealthy       | Should -BeTrue
        $ok.AntivirusSignalSource  | Should -Be 'Graph'
    }

    It 'maps isEncrypted = false through to the model' {
        $noenc = Get-ByName $script:Devices 'MOCK-WIN-NOENC'
        $noenc.IsEncrypted            | Should -BeFalse
        $noenc.EncryptionSignalSource | Should -Be 'Graph'
    }

    It 'flags an absent or null windowsProtectionState as Unavailable, never a guess' {
        $noav = Get-ByName $script:Devices 'MOCK-WIN-NOAV'
        $noav.AntivirusHealthy      | Should -BeNullOrEmpty
        $noav.AntivirusSignalSource | Should -Be 'Unavailable'

        $mac = Get-ByName $script:Devices 'MOCK-MAC-OLDOS'
        $mac.AntivirusSignalSource | Should -Be 'Unavailable'
    }

    It 'applies the -Platform filter after normalization' {
        $macs = @(Get-IntuneOpsDevice -GraphDataSourceMock -Platform macOS)
        $macs.Count | Should -Be 1
        $macs[0].DeviceName | Should -Be 'MOCK-MAC-OLDOS'
    }

    It 'honours -MaxDevices' {
        @(Get-IntuneOpsDevice -GraphDataSourceMock -MaxDevices 2).Count | Should -Be 2
    }

    It 'honours an explicit -FixturePath and accepts a bare JSON array' {
        $single = @(
            [pscustomobject]@{
                id                = '00000000-0000-0000-0000-000000000099'
                deviceName        = 'MOCK-CUSTOM'
                operatingSystem   = 'Windows'
                osVersion         = '10.0.22631.3958'
                isEncrypted       = $true
                userPrincipalName = 'custom@contoso.onmicrosoft.com'
            }
        )
        $customPath = Join-Path $TestDrive 'custom-fixture.json'
        $single | ConvertTo-Json -AsArray | Set-Content -LiteralPath $customPath -Encoding utf8

        $devices = @(Get-IntuneOpsDevice -GraphDataSourceMock -FixturePath $customPath)
        $devices.Count | Should -Be 1
        $devices[0].DeviceName | Should -Be 'MOCK-CUSTOM'
    }

    It 'rejects -FixturePath without -GraphDataSourceMock' {
        { Get-IntuneOpsDevice -FixturePath 'anything.json' } | Should -Throw '*-GraphDataSourceMock*'
    }
}

Describe 'Test-IntuneOpsCompliance against the fixtures (pure, no mocking)' {

    It 'MOCK-WIN-OK is Compliant on every check' {
        $r = Get-ByName $script:Results 'MOCK-WIN-OK'
        $r.OverallStatus | Should -Be 'Compliant'
        @($r.Checks | Where-Object Status -ne 'Compliant').Count | Should -Be 0
    }

    It 'MOCK-WIN-NOENC fails DiskEncryption only (the Automated path)' {
        $r = Get-ByName $script:Results 'MOCK-WIN-NOENC'
        $r.OverallStatus | Should -Be 'NonCompliant'
        ($r.Checks | Where-Object Check -eq 'DiskEncryption').Status | Should -Be 'NonCompliant'
        ($r.Checks | Where-Object Check -eq 'OSVersion').Status      | Should -Be 'Compliant'
        ($r.Checks | Where-Object Check -eq 'Antivirus').Status      | Should -Be 'Compliant'
    }

    It 'MOCK-MAC-OLDOS fails OSVersion (the Nudge path) with antivirus honestly Unknown' {
        $r = Get-ByName $script:Results 'MOCK-MAC-OLDOS'
        $r.OverallStatus | Should -Be 'NonCompliant'
        ($r.Checks | Where-Object Check -eq 'OSVersion').Status | Should -Be 'NonCompliant'
        ($r.Checks | Where-Object Check -eq 'Antivirus').Status | Should -Be 'Unknown'
    }

    It 'MOCK-WIN-NOAV resolves antivirus to Unknown via treatUnknownAs and rolls up to Unknown' {
        $r = Get-ByName $script:Results 'MOCK-WIN-NOAV'
        ($r.Checks | Where-Object Check -eq 'Antivirus').Status | Should -Be 'Unknown'
        $r.OverallStatus | Should -Be 'Unknown'
    }
}

Describe 'End-to-end mock pipeline in dry-run (fixtures -> plan -> render -> report, zero Graph calls)' {

    BeforeAll {
        $script:NonCompliant = @($script:Results | Where-Object OverallStatus -eq 'NonCompliant')
    }

    It 'plans one aggregate Automated action and one Nudge, mutating nothing' {
        $outcomes = @($script:NonCompliant | Invoke-IntuneOpsRemediation -Config $script:Config)

        $auto = @($outcomes | Where-Object Kind -eq 'Automated')
        $auto.Count | Should -Be 1
        $auto[0].Check | Should -Be 'DiskEncryption'
        $auto[0].Result | Should -Be 'WouldCreateAndAssign'
        $auto[0].AffectedDeviceCount | Should -Be 1

        $nudge = @($outcomes | Where-Object Kind -eq 'Nudge')
        $nudge.Count | Should -Be 1
        $nudge[0].Check | Should -Be 'OSVersion'
        $nudge[0].Result | Should -Be 'WouldNudge'

        $outcomes | ForEach-Object { $_.Mode | Should -Be 'DryRun' }
    }

    It 'renders the notifications without sending' {
        $outcomes = @($script:NonCompliant | Send-IntuneOpsNotification -Config $script:Config)
        $outcomes.Count | Should -Be 2
        $outcomes | ForEach-Object { $_.Result | Should -Be 'Rendered' }
        $outcomes.To | Should -Contain 'bruno.tremblay@contoso.onmicrosoft.com'
        $outcomes.To | Should -Contain 'chloe.martin@contoso.onmicrosoft.com'
    }

    It 'reports from the one canonical object, preserving the antivirus Unknown state in the CSV' {
        $json = Join-Path $TestDrive 'mock-report.json'
        $csv  = Join-Path $TestDrive 'mock-report.csv'

        $summary = Write-IntuneOpsReport -Result $script:Results -JsonPath $json -CsvPath $csv

        $summary.Counts.Total        | Should -Be 4
        $summary.Counts.Compliant    | Should -Be 1
        $summary.Counts.NonCompliant | Should -Be 2
        $summary.Counts.Unknown      | Should -Be 1
        $summary.RecommendedExitCode | Should -Be 1

        $rows = @(Import-Csv $csv)
        ($rows | Where-Object DeviceName -eq 'MOCK-WIN-NOAV').Antivirus_Status  | Should -Be 'Unknown'
        ($rows | Where-Object DeviceName -eq 'MOCK-WIN-NOAV').OverallStatus     | Should -Be 'Unknown'
        ($rows | Where-Object DeviceName -eq 'MOCK-MAC-OLDOS').Antivirus_Status | Should -Be 'Unknown'
    }
}
