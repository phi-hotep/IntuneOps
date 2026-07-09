# Purpose: Pester tests for run reporting: JSON + flat CSV projection from the ONE canonical object, and the per-run summary counts.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1') -Force
    Mock -ModuleName IntuneOps Write-IntuneOpsLog { }

    function New-CanonResult {
        param([string]$Id, [string]$Name, [string]$Overall, [string]$EncStatus)
        [pscustomobject]@{
            DeviceId = $Id; DeviceName = $Name; OwnerUpn = "$Name@x"; Platform = 'Windows'; OsVersion = '10.0.1'
            Checks = @(
                [pscustomobject]@{ Check = 'DiskEncryption'; Status = $EncStatus;   Reason = 'enc reason'; SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'OSVersion';      Status = 'Compliant';   Reason = 'os ok';      SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'Antivirus';      Status = 'Unknown';     Reason = 'no av';      SignalSource = 'Unavailable' }
            )
            OverallStatus = $Overall; Reasons = @('r1', 'r2'); EvaluatedAt = '2026-07-08T00:00:00Z'
        }
    }
}

Describe 'Write-IntuneOpsReport' {

    It 'writes JSON and a flat CSV projection of the same canonical objects' {
        $results = @(
            (New-CanonResult -Id 'd1' -Name 'PC1' -Overall 'Compliant'    -EncStatus 'Compliant')
            (New-CanonResult -Id 'd2' -Name 'PC2' -Overall 'NonCompliant' -EncStatus 'NonCompliant')
        )
        $json = Join-Path $TestDrive 'r.json'
        $csv  = Join-Path $TestDrive 'r.csv'

        $summary = Write-IntuneOpsReport -Result $results -JsonPath $json -CsvPath $csv

        Test-Path $json | Should -BeTrue
        Test-Path $csv  | Should -BeTrue

        # CSV is one row per canonical result, with per-check columns projected from the same object.
        $rows = @(Import-Csv $csv)
        $rows.Count | Should -Be 2
        ($rows | Where-Object DeviceName -eq 'PC2').DiskEncryption_Status | Should -Be 'NonCompliant'
        ($rows | Where-Object DeviceName -eq 'PC1').OverallStatus | Should -Be 'Compliant'

        # JSON round-trips to the canonical shape (nested Checks preserved).
        $fromJson = Get-Content $json -Raw | ConvertFrom-Json
        @($fromJson).Count | Should -Be 2
        (@($fromJson) | Where-Object DeviceName -eq 'PC2').Checks.Count | Should -Be 3
    }

    It 'summarizes counts and recommends the right exit code' {
        $results = @(
            (New-CanonResult -Id 'd1' -Name 'PC1' -Overall 'Compliant'    -EncStatus 'Compliant')
            (New-CanonResult -Id 'd2' -Name 'PC2' -Overall 'NonCompliant' -EncStatus 'NonCompliant')
            (New-CanonResult -Id 'd3' -Name 'PC3' -Overall 'Unknown'      -EncStatus 'Unknown')
        )
        $summary = Write-IntuneOpsReport -Result $results -JsonPath (Join-Path $TestDrive 'r2.json')

        $summary.Counts.Total        | Should -Be 3
        $summary.Counts.NonCompliant | Should -Be 1
        $summary.Counts.Unknown      | Should -Be 1
        # NonCompliant present -> exit 1 (takes precedence over Unknown's 2).
        $summary.RecommendedExitCode | Should -Be 1
    }

    It 'counts remediation applied-vs-simulated and notifications sent-vs-rendered' {
        $results = @((New-CanonResult -Id 'd2' -Name 'PC2' -Overall 'NonCompliant' -EncStatus 'NonCompliant'))
        $rem = @(
            [pscustomobject]@{ Kind = 'Automated'; Mode = 'DryRun';  Result = 'WouldCreateAndAssign' }
            [pscustomobject]@{ Kind = 'Nudge';     Mode = 'DryRun';  Result = 'WouldNudge' }
        )
        $note = @(
            [pscustomobject]@{ Result = 'Rendered' }
            [pscustomobject]@{ Result = 'SkippedNoRecipient' }
        )
        $summary = Write-IntuneOpsReport -Result $results -JsonPath (Join-Path $TestDrive 'r3.json') -RemediationOutcome $rem -NotificationOutcome $note

        $summary.Remediation.Simulated | Should -Be 2
        $summary.Remediation.Applied   | Should -Be 0
        $summary.Notifications.Rendered | Should -Be 1
        $summary.Notifications.Skipped  | Should -Be 1
    }
}
