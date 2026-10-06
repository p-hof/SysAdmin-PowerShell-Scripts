# Clear-SystemState.ps1

## Overview
This PowerShell script clears various system states on Windows 11 Pro/Enterprise systems to resolve backup failures, particularly those related to Cove backup software.

## Purpose
The script addresses common Windows update and shadow copy issues that prevent successful backups by:
- Clearing Windows Update cache
- Deleting volume shadow copies
- Removing old event logs
- Cleaning up DISM component store

## Prerequisites
- **Operating System**: Windows 11 Pro or Enterprise (required for full functionality)
- **Permissions**: Administrator privileges required
- **Tools Required**: vssadmin.exe, DISM (included in Windows)

## Usage

### Deploy via NinjaRMM
```powershell
.\Clear-SystemState.ps1
```

### Manual Execution (Admin Required)
```powershell
Set-Location C:\Windows\System32\config\systemprofile\AppData\Roaming\NinjaRMM
.\Clear-SystemState.ps1 -Verbose
```

## Script Functions

### 1. Windows Update Cache Clear
Removes cached Windows update files that can cause backup failures.
```powershell
Remove-Item "$env:Windows\SoftwareDistribution\Download" -Recurse -Force -ErrorAction SilentlyContinue
```

### 2. Volume Shadow Copy Deletion
Deletes volume shadow copies using vssadmin, which can interfere with backups.
```powershell
vssadmin.exe delete shadows /for=C: /all /quiet
```

### 3. System Restore Points Clear
Clears all restore points to free up space and prevent conflicts.
```powershell
vssadmin.exe delete shadows /all /quiet
```

### 4. Event Log Cleanup
Removes Windows event logs older than 7 days to reduce disk usage.
```powershell
Get-WinEvent -LogName "Application","System" | Where-Object { $_.TimeCreated -lt (Get-Date).AddDays(-7) } | Remove-Item -ErrorAction SilentlyContinue
```

### 5. DISM Component Store Cleanup
Cleans up the Windows component store to free space and improve system performance.
```powershell
Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase
```

## Error Handling
The script includes error handling with `-ErrorAction SilentlyContinue` and `2>$null` to prevent execution from stopping on non-critical errors. However, some operations (like DISM cleanup) may fail on systems with insufficient disk space.

## Important Notes
- ⚠️ **This script deletes volume shadow copies** - This will affect system recovery capabilities
- ⚠️ **Requires Administrator rights** - Will not work without elevated privileges
- ⚠️ **Windows Update cache deletion** - May cause Windows Update to slow down temporarily
- ℹ️ **DISM cleanup** - May fail if disk space is critically low

## Troubleshooting

### Script Won't Execute
- Ensure you're running as Administrator
- Check that NinjaRMM deployment directory has execute permissions

### DISM Cleanup Fails
- Insufficient disk space may prevent cleanup
- Consider defragmenting or freeing up disk space first

### vssadmin Commands Fail
- Some Windows configurations disable shadow copy creation
- This is expected behavior and not an error

## Version History
- **1.0** - Initial release for Windows 11 backup failure resolution

## License
Internal use only - Company Property

## Support
For issues or questions, contact your system administrator or NinjaRMM support team.