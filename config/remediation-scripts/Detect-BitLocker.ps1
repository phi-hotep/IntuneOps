# Purpose: Intune proactive remediation DETECTION script. Exits 1 (non-compliant, triggers remediation) if the OS volume is not fully BitLocker-encrypted and protected, else 0.

# Runs on the endpoint under the account configured on the deviceHealthScript (system by default).
# Keep output to a single line: Intune surfaces stdout as the detection "pre-remediation" detail.

try {
    $osDrive = $env:SystemDrive
    if (-not $osDrive) { $osDrive = 'C:' }

    $volume = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

    if ($volume.VolumeStatus -eq 'FullyEncrypted' -and $volume.ProtectionStatus -eq 'On') {
        Write-Output "Compliant: $osDrive is FullyEncrypted and protection is On."
        exit 0
    }

    Write-Output "NonCompliant: $osDrive VolumeStatus=$($volume.VolumeStatus), ProtectionStatus=$($volume.ProtectionStatus)."
    exit 1
}
catch {
    # If BitLocker is not available (e.g. no TPM, unsupported SKU), report non-compliant so the
    # signal is visible rather than silently passing.
    Write-Output "NonCompliant: could not read BitLocker state: $($_.Exception.Message)"
    exit 1
}
