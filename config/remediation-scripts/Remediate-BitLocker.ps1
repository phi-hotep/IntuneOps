# Purpose: Intune proactive remediation REMEDIATION script. Enables BitLocker on the OS volume (TPM + recovery password) when the detection script reported non-compliance.

# Runs only when the detection script exits non-zero. Idempotent: if protection is already On it
# exits success without re-enabling. Keep output to a single summary line.

try {
    $osDrive = $env:SystemDrive
    if (-not $osDrive) { $osDrive = 'C:' }

    $volume = Get-BitLockerVolume -MountPoint $osDrive -ErrorAction Stop

    if ($volume.ProtectionStatus -eq 'On') {
        Write-Output "No action: $osDrive protection is already On."
        exit 0
    }

    # Add a recovery password protector first so a recovery key exists, then enable encryption.
    # Encrypt used space only for speed; XtsAes256 is the modern default. SkipHardwareTest avoids a
    # reboot-gated hardware test in unattended context.
    if (-not ($volume.KeyProtector | Where-Object KeyProtectorType -eq 'RecoveryPassword')) {
        Add-BitLockerKeyProtector -MountPoint $osDrive -RecoveryPasswordProtector -ErrorAction Stop | Out-Null
    }

    Enable-BitLocker -MountPoint $osDrive -EncryptionMethod XtsAes256 -UsedSpaceOnly -SkipHardwareTest -ErrorAction Stop | Out-Null

    Write-Output "Remediated: BitLocker enable initiated on $osDrive (XtsAes256, used-space-only)."
    exit 0
}
catch {
    Write-Output "Remediation failed on $($env:SystemDrive): $($_.Exception.Message)"
    exit 1
}
