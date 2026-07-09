# Purpose: PRIVATE. Single structured-logging sink to console (with severity) and the run log file. Never receives secret material.

function Write-IntuneOpsLog {
    <#
    .SYNOPSIS
        Writes a structured, timestamped log entry to the console and (if configured) a run log file.

    .DESCRIPTION
        The single logging sink for IntuneOps. Every function routes operator-facing messages
        through here so formatting, severity colouring, and file persistence stay consistent.

        The run log file path is taken from the module-scoped variable $script:IntuneOpsLogPath
        (set by the entrypoint) unless -LogPath is supplied explicitly. If neither is set, the
        entry is written to the console only.

        By design this function never receives secret material. Callers pass identifiers and
        status, not credentials, tokens, or certificate contents.

    .PARAMETER Message
        The human-readable message to log.

    .PARAMETER Level
        Severity of the entry. One of Debug, Info, Success, Warning, Error. Defaults to Info.
        Debug entries are written only when -Verbose/$VerbosePreference or -Debug is in effect.

    .PARAMETER LogPath
        Optional explicit run log file path. Overrides the module-scoped default for this call.

    .EXAMPLE
        Write-IntuneOpsLog -Message 'Connected to Graph.' -Level Success

    .EXAMPLE
        Write-IntuneOpsLog -Message "Device $id missing AV signal." -Level Warning
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('Debug', 'Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter()]
        [string]$LogPath
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffK')
    $line = '{0} [{1,-7}] {2}' -f $timestamp, $Level.ToUpper(), $Message

    # Console sink: severity-appropriate stream and colour. Debug is gated on preference so
    # normal runs stay quiet.
    switch ($Level) {
        'Debug'   { Write-Debug   $line }
        'Info'    { Write-Host    $line -ForegroundColor Gray }
        'Success' { Write-Host    $line -ForegroundColor Green }
        'Warning' { Write-Warning $Message }
        'Error'   { Write-Host    $line -ForegroundColor Red }
    }

    # File sink: append if a path is configured. Failure to write the log must not crash the run,
    # so a file error is downgraded to a single console warning.
    $targetPath = if ($PSBoundParameters.ContainsKey('LogPath') -and $LogPath) { $LogPath } else { $script:IntuneOpsLogPath }
    if ($targetPath) {
        try {
            $directory = Split-Path -Path $targetPath -Parent
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                New-Item -Path $directory -ItemType Directory -Force | Out-Null
            }
            Add-Content -LiteralPath $targetPath -Value $line -Encoding utf8
        }
        catch {
            Write-Warning "Could not write to run log '$targetPath': $($_.Exception.Message)"
        }
    }
}
