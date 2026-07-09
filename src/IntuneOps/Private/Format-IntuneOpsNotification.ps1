# Purpose: PRIVATE. Render a compliance-notification message (subject + body) from a canonical result and the templates. Pure/deterministic string work, no Graph, so it is unit-testable.

function Format-IntuneOpsNotification {
    <#
    .SYNOPSIS
        Renders the subject and body for a device's compliance notification from the templates.

    .DESCRIPTION
        Fills the plain-text or HTML template with tokens derived from a canonical compliance result:
        device name, platform, evaluated timestamp, the list of failing checks (with reasons), and a
        remediation instruction per failing check. Pure string rendering: no I/O beyond reading the
        template files, and no Graph. This is what lets the dry-run path show the exact email without
        sending anything.

    .PARAMETER Result
        A canonical compliance result from Test-IntuneOpsCompliance.

    .PARAMETER Config
        The merged config object (Rules + RepositoryRoot + Settings). Used to locate templates and to
        read the subject template.

    .PARAMETER UseHtml
        Render the HTML template instead of plain text.

    .EXAMPLE
        $msg = Format-IntuneOpsNotification -Result $r -Config $config

    .OUTPUTS
        PSCustomObject: To, Subject, Body, ContentType ('Text' | 'HTML'), FailingCheckCount.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Result,

        [Parameter(Mandatory)]
        [object]$Config,

        [Parameter()]
        [switch]$UseHtml
    )

    # Short, user-facing remediation guidance per check.
    $instructionByCheck = @{
        DiskEncryption = 'Turn on device encryption (BitLocker on Windows, FileVault on macOS). On managed devices this may be applied for you: keep the device online and plugged in.'
        OSVersion      = 'Install the latest operating system updates and restart your device.'
        Antivirus      = 'Make sure your antivirus (Microsoft Defender or an approved product) is enabled and its definitions are up to date.'
    }

    $failing = @($Result.Checks | Where-Object { $_.Status -notin @('Compliant') })

    # Build the failing-checks block and the remediation block in the content-appropriate format.
    if ($UseHtml) {
        $failingBlock = '<ul>' + (($failing | ForEach-Object { "<li><strong>$($_.Check)</strong>: $($_.Reason)</li>" }) -join '') + '</ul>'
        $instructions = @($failing | ForEach-Object { if ($instructionByCheck.ContainsKey($_.Check)) { $instructionByCheck[$_.Check] } else { 'Contact IT for remediation steps.' } } | Select-Object -Unique)
        $remediationBlock = '<ul>' + (($instructions | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>'
        $templateName = 'notification.html.template'
        $contentType = 'HTML'
    }
    else {
        $failingBlock = ($failing | ForEach-Object { " - $($_.Check): $($_.Reason)" }) -join "`n"
        $instructions = @($failing | ForEach-Object { if ($instructionByCheck.ContainsKey($_.Check)) { $instructionByCheck[$_.Check] } else { 'Contact IT for remediation steps.' } } | Select-Object -Unique)
        $remediationBlock = ($instructions | ForEach-Object { " - $_" }) -join "`n"
        $templateName = 'notification.text.template'
        $contentType = 'Text'
    }

    $templatePath = Join-Path -Path $Config.RepositoryRoot -ChildPath "templates/$templateName"
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Notification template not found: '$templatePath'."
    }
    $template = Get-Content -LiteralPath $templatePath -Raw

    # Subject template from settings, with a sensible default.
    $subjectTemplate = 'Action required: {{DeviceName}} is not compliant'
    if ($Config.PSObject.Properties['Settings'] -and $Config.Settings -and $Config.Settings.ContainsKey('NotificationSubjectTemplate')) {
        $subjectTemplate = [string]$Config.Settings.NotificationSubjectTemplate
    }

    # Token replacement. Kept explicit so the token set is easy to audit.
    $tokens = @{
        '{{DeviceName}}'            = [string]$Result.DeviceName
        '{{Platform}}'             = [string]$Result.Platform
        '{{EvaluatedAt}}'          = [string]$Result.EvaluatedAt
        '{{FailingChecks}}'        = $failingBlock
        '{{RemediationInstruction}}' = $remediationBlock
        '{{OwnerUpn}}'             = [string]$Result.OwnerUpn
    }

    $body = $template
    $subject = $subjectTemplate
    foreach ($token in $tokens.Keys) {
        $body = $body.Replace($token, $tokens[$token])
        $subject = $subject.Replace($token, $tokens[$token])
    }

    [pscustomobject]@{
        To                = [string]$Result.OwnerUpn
        Subject           = $subject
        Body              = $body
        ContentType       = $contentType
        FailingCheckCount = $failing.Count
    }
}
