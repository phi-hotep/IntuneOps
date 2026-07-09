# Purpose: Pester tests for notification rendering and the render/send safety model, with Graph Mail mocked. Asserts no mail is sent without -Execute.

#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/IntuneOps/IntuneOps.psd1') -Force

    $rules = Get-Content (Join-Path $repoRoot 'config/compliance-rules.json') -Raw | ConvertFrom-Json
    $script:Config = [pscustomobject]@{
        Rules          = $rules
        RepositoryRoot = $repoRoot
        Settings       = @{ MailSender = 'compliance-bot@contoso.onmicrosoft.com'; UseHtmlEmail = $false; NotificationSubjectTemplate = 'Action required: {{DeviceName}} is not compliant' }
    }

    Mock -ModuleName IntuneOps Write-IntuneOpsLog { }

    function New-NcResult {
        param([string]$Upn = 'user@contoso.onmicrosoft.com', [string]$Overall = 'NonCompliant')
        [pscustomobject]@{
            DeviceId = 'dev-1'; DeviceName = 'DEV-WIN-01'; OwnerUpn = $Upn; Platform = 'Windows'; OsVersion = '10.0.1'
            Checks = @(
                [pscustomobject]@{ Check = 'DiskEncryption'; Status = 'NonCompliant'; Reason = 'Disk encryption is not enabled.'; SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'OSVersion';      Status = 'Compliant';    Reason = 'ok';                            SignalSource = 'Graph' }
                [pscustomobject]@{ Check = 'Antivirus';      Status = 'Unknown';      Reason = 'no signal';                     SignalSource = 'Unavailable' }
            )
            OverallStatus = $Overall; Reasons = @('[DiskEncryption] Disk encryption is not enabled.'); EvaluatedAt = '2026-07-08T00:00:00Z'
        }
    }
}

Describe 'Format-IntuneOpsNotification (pure render)' {

    It 'substitutes the device name into subject and body and lists failing checks' {
        InModuleScope IntuneOps -Parameters @{ cfg = $script:Config } {
            param($cfg)
            $r = [pscustomobject]@{
                DeviceName = 'DEV-WIN-01'; Platform = 'Windows'; OwnerUpn = 'user@contoso.onmicrosoft.com'; EvaluatedAt = 'now'
                Checks = @([pscustomobject]@{ Check = 'DiskEncryption'; Status = 'NonCompliant'; Reason = 'Disk encryption is not enabled.' })
            }
            $msg = Format-IntuneOpsNotification -Result $r -Config $cfg
            $msg.Subject | Should -BeLike '*DEV-WIN-01*'
            $msg.Body | Should -BeLike '*DEV-WIN-01*'
            $msg.Body | Should -BeLike '*Disk encryption is not enabled*'
            $msg.ContentType | Should -Be 'Text'
            $msg.To | Should -Be 'user@contoso.onmicrosoft.com'
        }
    }

    It 'renders HTML when -UseHtml is set' {
        InModuleScope IntuneOps -Parameters @{ cfg = $script:Config } {
            param($cfg)
            $r = [pscustomobject]@{
                DeviceName = 'DEV-WIN-01'; Platform = 'Windows'; OwnerUpn = 'user@contoso.onmicrosoft.com'; EvaluatedAt = 'now'
                Checks = @([pscustomobject]@{ Check = 'DiskEncryption'; Status = 'NonCompliant'; Reason = 'x' })
            }
            $msg = Format-IntuneOpsNotification -Result $r -Config $cfg -UseHtml
            $msg.ContentType | Should -Be 'HTML'
            $msg.Body | Should -BeLike '*<li>*'
        }
    }
}

Describe 'Send-IntuneOpsNotification dry-run (default)' {

    BeforeEach { Mock -ModuleName IntuneOps Invoke-MgGraphRequest { } }

    It 'sends NOTHING and reports Rendered' {
        $out = @((New-NcResult) | Send-IntuneOpsNotification -Config $script:Config)
        Should -Invoke -ModuleName IntuneOps Invoke-MgGraphRequest -Times 0 -Exactly
        $out.Result | Should -Be 'Rendered'
        $out.Mode | Should -Be 'DryRun'
    }

    It 'skips a Compliant result (no notification)' {
        $out = @((New-NcResult -Overall 'Compliant') | Send-IntuneOpsNotification -Config $script:Config)
        $out.Count | Should -Be 0
    }

    It 'reports SkippedNoRecipient when the owner UPN is missing' {
        $out = @((New-NcResult -Upn '') | Send-IntuneOpsNotification -Config $script:Config)
        $out.Result | Should -Be 'SkippedNoRecipient'
    }
}

Describe 'Send-IntuneOpsNotification -Execute' {

    It 'sends via Graph Mail and reports Sent' {
        Mock -ModuleName IntuneOps Invoke-MgGraphRequest { }
        $out = @((New-NcResult) | Send-IntuneOpsNotification -Config $script:Config -Execute)
        Should -Invoke -ModuleName IntuneOps Invoke-MgGraphRequest -Times 1 -Exactly
        $out.Result | Should -Be 'Sent'
    }

    It 'short-circuits with -WhatIf (no send)' {
        Mock -ModuleName IntuneOps Invoke-MgGraphRequest { }
        $out = @((New-NcResult) | Send-IntuneOpsNotification -Config $script:Config -Execute -WhatIf)
        Should -Invoke -ModuleName IntuneOps Invoke-MgGraphRequest -Times 0 -Exactly
        $out.Result | Should -Be 'SkippedByWhatIf'
    }
}
