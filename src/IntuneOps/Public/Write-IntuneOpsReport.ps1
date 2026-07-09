# Purpose: PUBLIC. Aggregate the run from the ONE canonical result object: write JSON (direct) + CSV (flat projection), build the per-run summary, and return it with a recommended exit code.

function Write-IntuneOpsReport {
    <#
    .SYNOPSIS
        Writes the run report (JSON + CSV) and returns the per-run summary.

    .DESCRIPTION
        The canonical compliance result objects are the single source of truth. This function:
          - serializes them to JSON (the direct, lossless form), and
          - projects the SAME objects to a flat CSV via ConvertTo-IntuneOpsReportRow (no second
            schema: the CSV is a reshape of the canonical object).
        It also builds a per-run summary (counts by status; remediation actions applied vs simulated;
        notifications sent vs rendered) and returns it, including a recommended exit code for
        Automation.

    .PARAMETER Result
        The canonical compliance result objects from Test-IntuneOpsCompliance.

    .PARAMETER JsonPath
        Output path for the JSON report (the canonical serialization).

    .PARAMETER CsvPath
        Optional output path for the flat CSV projection. Omit to skip CSV.

    .PARAMETER RemediationOutcome
        Optional remediation outcome objects from Invoke-IntuneOpsRemediation, for the summary.

    .PARAMETER NotificationOutcome
        Optional notification outcome objects from Send-IntuneOpsNotification, for the summary.

    .EXAMPLE
        $summary = Write-IntuneOpsReport -Result $results -JsonPath $j -CsvPath $c -RemediationOutcome $rem -NotificationOutcome $note

    .OUTPUTS
        PSCustomObject summary (Counts, Remediation, Notifications, RecommendedExitCode, JsonPath, CsvPath).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Result,

        [Parameter(Mandatory)]
        [string]$JsonPath,

        [Parameter()]
        [string]$CsvPath,

        [Parameter()]
        [object[]]$RemediationOutcome = @(),

        [Parameter()]
        [object[]]$NotificationOutcome = @()
    )

    # Ensure output directories exist.
    foreach ($p in @($JsonPath, $CsvPath)) {
        if ($p) {
            $dir = Split-Path -Path $p -Parent
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
        }
    }

    # JSON: direct serialization of the canonical objects.
    $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $JsonPath -Encoding utf8
    Write-IntuneOpsLog -Message "Wrote JSON report: $JsonPath" -Level Success

    # CSV: flat projection of the SAME canonical objects.
    if ($CsvPath) {
        $rows = @($Result | ConvertTo-IntuneOpsReportRow)
        $rows | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding utf8
        Write-IntuneOpsLog -Message "Wrote CSV report: $CsvPath" -Level Success
    }

    # Counts by overall status.
    $statuses = @($Result.OverallStatus)
    $counts = [pscustomobject]@{
        Total        = $statuses.Count
        Compliant    = @($statuses | Where-Object { $_ -eq 'Compliant' }).Count
        NonCompliant = @($statuses | Where-Object { $_ -eq 'NonCompliant' }).Count
        Unknown      = @($statuses | Where-Object { $_ -eq 'Unknown' }).Count
    }

    # Remediation: applied vs simulated (dry-run) vs skipped/failed.
    $rem = @($RemediationOutcome)
    $remediationSummary = [pscustomobject]@{
        Planned   = $rem.Count
        Applied   = @($rem | Where-Object { $_.Mode -eq 'Execute' -and $_.Result -notin @('SkippedByWhatIf', 'Failed') }).Count
        Simulated = @($rem | Where-Object { $_.Mode -eq 'DryRun' }).Count
        Skipped   = @($rem | Where-Object { $_.Result -eq 'SkippedByWhatIf' }).Count
        Failed    = @($rem | Where-Object { $_.Result -eq 'Failed' }).Count
    }

    # Notifications: sent vs rendered (dry-run) vs skipped/failed.
    $note = @($NotificationOutcome)
    $notificationSummary = [pscustomobject]@{
        Total    = $note.Count
        Sent     = @($note | Where-Object { $_.Result -eq 'Sent' }).Count
        Rendered = @($note | Where-Object { $_.Result -eq 'Rendered' }).Count
        Skipped  = @($note | Where-Object { $_.Result -in @('SkippedByWhatIf', 'SkippedNoRecipient') }).Count
        Failed   = @($note | Where-Object { $_.Result -eq 'Failed' }).Count
    }

    # Recommended exit code: NonCompliant -> 1, any Unknown -> 2, else 0. (Fatal 3 is set by the
    # entrypoint's catch block, not here.)
    $exit =
        if ($counts.NonCompliant -gt 0) { 1 }
        elseif ($counts.Unknown -gt 0)  { 2 }
        else                            { 0 }

    $summary = [pscustomobject]@{
        Counts              = $counts
        Remediation         = $remediationSummary
        Notifications       = $notificationSummary
        RecommendedExitCode = $exit
        JsonPath            = $JsonPath
        CsvPath             = $CsvPath
    }

    # Console summary.
    Write-Host ''
    Write-Host 'Run summary' -ForegroundColor Cyan
    Write-Host ("  Devices: {0} total | {1} compliant | {2} non-compliant | {3} unknown" -f $counts.Total, $counts.Compliant, $counts.NonCompliant, $counts.Unknown)
    Write-Host ("  Remediation: {0} planned | {1} applied | {2} simulated | {3} skipped | {4} failed" -f $remediationSummary.Planned, $remediationSummary.Applied, $remediationSummary.Simulated, $remediationSummary.Skipped, $remediationSummary.Failed)
    Write-Host ("  Notifications: {0} total | {1} sent | {2} rendered | {3} skipped | {4} failed" -f $notificationSummary.Total, $notificationSummary.Sent, $notificationSummary.Rendered, $notificationSummary.Skipped, $notificationSummary.Failed)

    return $summary
}
