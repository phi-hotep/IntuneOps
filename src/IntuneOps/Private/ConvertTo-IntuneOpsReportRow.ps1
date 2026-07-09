# Purpose: PRIVATE. Flatten ONE canonical compliance result into a single CSV row. This is a projection of the canonical object, not a second schema: every value comes from the result.

function ConvertTo-IntuneOpsReportRow {
    <#
    .SYNOPSIS
        Projects a canonical compliance result into a flat row for CSV output.

    .DESCRIPTION
        The canonical compliance result (with its nested Checks array) is the single source of truth.
        The JSON report serializes it directly; the CSV needs a flat shape, so this function projects
        the same object into one row: top-level fields plus per-check Status/Reason columns. No new
        data is introduced; it only reshapes what the result already contains.

    .PARAMETER Result
        A canonical compliance result from Test-IntuneOpsCompliance.

    .EXAMPLE
        $rows = $results | ForEach-Object { ConvertTo-IntuneOpsReportRow -Result $_ }
        $rows | Export-Csv report.csv -NoTypeInformation

    .OUTPUTS
        PSCustomObject: one flat row.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Result
    )

    process {
        # Index the checks by name so per-check columns are stable regardless of array order.
        $byName = @{}
        foreach ($check in @($Result.Checks)) { $byName[$check.Check] = $check }

        function Get-CheckField {
            param([string]$Name, [string]$Field)
            if ($byName.ContainsKey($Name)) { return [string]$byName[$Name].$Field }
            return ''
        }

        [pscustomobject][ordered]@{
            DeviceId              = $Result.DeviceId
            DeviceName            = $Result.DeviceName
            OwnerUpn              = $Result.OwnerUpn
            Platform              = $Result.Platform
            OsVersion             = $Result.OsVersion
            OverallStatus         = $Result.OverallStatus
            DiskEncryption_Status = Get-CheckField -Name 'DiskEncryption' -Field 'Status'
            DiskEncryption_Reason = Get-CheckField -Name 'DiskEncryption' -Field 'Reason'
            OSVersion_Status      = Get-CheckField -Name 'OSVersion' -Field 'Status'
            OSVersion_Reason      = Get-CheckField -Name 'OSVersion' -Field 'Reason'
            Antivirus_Status      = Get-CheckField -Name 'Antivirus' -Field 'Status'
            Antivirus_Reason      = Get-CheckField -Name 'Antivirus' -Field 'Reason'
            Reasons               = (@($Result.Reasons) -join ' ; ')
            EvaluatedAt           = $Result.EvaluatedAt
        }
    }
}
