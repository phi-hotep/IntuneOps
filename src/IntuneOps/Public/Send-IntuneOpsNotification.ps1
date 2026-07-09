# Purpose: PUBLIC. Render the compliance-nudge email for a device's failing checks and send via Graph Mail (Mail.Send). Dry-run renders and logs only; -Execute sends.

function Send-IntuneOpsNotification {
    <#
    .SYNOPSIS
        Sends (or, in dry-run, renders) a compliance notification email to the affected user.

    .DESCRIPTION
        For each non-compliant compliance result, renders the templated message (plain text or HTML)
        with Format-IntuneOpsNotification and either sends it via Graph Mail or, in dry-run, logs the
        rendered email and sends nothing.

        SAFETY MODEL (same shape as the remediation engine):
          1. Dry-run is the default. Without -Execute, NO mail is sent: the email is rendered and
             logged (a preview) and the outcome is 'Rendered'. This is the primary gate.
          2. SupportsShouldProcess: even with -Execute, -WhatIf short-circuits the send, and each
             send is guarded by ShouldProcess.

        Mail is sent with a RAW Invoke-MgGraphRequest POST to /users/{sender}/sendMail. The sender is
        the configured MailSender mailbox (app-only) or the signed-in user (delegated). saveToSentItems
        is false to avoid cluttering the sender mailbox. No third-party mail provider is used.

        Only NonCompliant results are notified. Compliant and Unknown results are skipped (Unknown
        means a signal could not be read, not a confirmed failure, so we do not alarm the user).

    .PARAMETER ComplianceResult
        Canonical compliance result(s) from Test-IntuneOpsCompliance. Accepts pipeline input.

    .PARAMETER Config
        The merged config object from Get-IntuneOpsConfig (Rules + RepositoryRoot + Settings).

    .PARAMETER MailSender
        Sender mailbox (UPN). Defaults to Config.Settings.MailSender. Required to actually send.

    .PARAMETER UseHtml
        Send the HTML template instead of plain text. Defaults to Config.Settings.UseHtmlEmail.

    .PARAMETER Execute
        Actually send. WITHOUT this switch the function renders and logs only, sending nothing.

    .EXAMPLE
        $results | Send-IntuneOpsNotification -Config $config
        Dry-run: renders and logs each email, sends nothing.

    .EXAMPLE
        $results | Send-IntuneOpsNotification -Config $config -Execute
        Sends the emails via Graph Mail.

    .OUTPUTS
        PSCustomObject[] outcome records (To, Subject, ContentType, Mode, Result).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$ComplianceResult,

        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter()]
        [string]$MailSender,

        [Parameter()]
        [switch]$UseHtml,

        [Parameter()]
        [switch]$Execute
    )

    begin {
        # Resolve sender / html defaults from settings once.
        if (-not $PSBoundParameters.ContainsKey('MailSender')) {
            if ($Config.PSObject.Properties['Settings'] -and $Config.Settings -and $Config.Settings.ContainsKey('MailSender')) {
                $MailSender = [string]$Config.Settings.MailSender
            }
        }
        if (-not $PSBoundParameters.ContainsKey('UseHtml')) {
            if ($Config.PSObject.Properties['Settings'] -and $Config.Settings -and $Config.Settings.ContainsKey('UseHtmlEmail')) {
                $UseHtml = [bool]$Config.Settings.UseHtmlEmail
            }
        }
        $mode = if ($Execute) { 'Execute' } else { 'DryRun' }
    }

    process {
        # Only notify confirmed non-compliance.
        if ($ComplianceResult.OverallStatus -ne 'NonCompliant') {
            return
        }

        $message = Format-IntuneOpsNotification -Result $ComplianceResult -Config $Config -UseHtml:$UseHtml

        # No recipient means we cannot notify; surface it rather than silently dropping.
        if ([string]::IsNullOrWhiteSpace($message.To)) {
            Write-IntuneOpsLog -Message "No owner UPN for device '$($ComplianceResult.DeviceName)'; cannot notify." -Level Warning
            [pscustomobject]@{ To = $null; Subject = $message.Subject; ContentType = $message.ContentType; Mode = $mode; Result = 'SkippedNoRecipient'; Device = $ComplianceResult.DeviceName }
            return
        }

        if (-not $Execute) {
            # Dry-run: render + log a preview, send nothing.
            $preview = ($message.Body -split "`n" | Select-Object -First 4) -join ' | '
            Write-IntuneOpsLog -Message "WOULD send $($message.ContentType) mail to $($message.To) | subject: '$($message.Subject)' | preview: $preview" -Level Info
            [pscustomobject]@{ To = $message.To; Subject = $message.Subject; ContentType = $message.ContentType; Mode = 'DryRun'; Result = 'Rendered'; Device = $ComplianceResult.DeviceName }
            return
        }

        # Execute path.
        if ([string]::IsNullOrWhiteSpace($MailSender)) {
            throw "Cannot send mail: no MailSender configured (set Config.Settings.MailSender or pass -MailSender)."
        }

        if (-not $PSCmdlet.ShouldProcess("$($message.To)", "Send compliance notification '$($message.Subject)'")) {
            [pscustomobject]@{ To = $message.To; Subject = $message.Subject; ContentType = $message.ContentType; Mode = 'Execute'; Result = 'SkippedByWhatIf'; Device = $ComplianceResult.DeviceName }
            return
        }

        $payload = @{
            message = @{
                subject      = $message.Subject
                body         = @{ contentType = $message.ContentType; content = $message.Body }
                toRecipients = @(@{ emailAddress = @{ address = $message.To } })
            }
            saveToSentItems = $false
        }

        try {
            Invoke-MgGraphRequest -Method POST -Uri "/v1.0/users/$MailSender/sendMail" -Body ($payload | ConvertTo-Json -Depth 8) -ContentType 'application/json' -ErrorAction Stop | Out-Null
            Write-IntuneOpsLog -Message "Sent compliance notification to $($message.To) (from $MailSender)." -Level Success
            [pscustomobject]@{ To = $message.To; Subject = $message.Subject; ContentType = $message.ContentType; Mode = 'Execute'; Result = 'Sent'; Device = $ComplianceResult.DeviceName }
        }
        catch {
            Write-IntuneOpsLog -Message "Failed to send notification to $($message.To): $($_.Exception.Message)" -Level Error
            [pscustomobject]@{ To = $message.To; Subject = $message.Subject; ContentType = $message.ContentType; Mode = 'Execute'; Result = 'Failed'; Device = $ComplianceResult.DeviceName }
        }
    }
}
