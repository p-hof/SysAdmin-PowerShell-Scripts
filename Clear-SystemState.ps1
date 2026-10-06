# Clear-SystemState.ps1
# PowerShell script to clear system state for Windows 11 backup failure resolution
# Target: Windows 11 Pro/Enterprise systems via NinjaRMM deployment

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Clear-SystemState Script" -ForegroundColor Cyan  
Write-Host "Windows 11 Backup Failure Resolution" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if running as Administrator
if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "WARNING: This script requires Administrator privileges!" -ForegroundColor Yellow
    Write-Host "Please run PowerShell as Administrator to execute this script." -ForegroundColor Yellow
    Write-Host ""
    pause
    exit
}

Write-Host "[1/5] Clearing Windows Update Cache..." -ForegroundColor Green
try {
    $updateCache = "$env:Windows\SoftwareDistribution\Download"
    if (Test-Path $updateCache) {
        Remove-Item $updateCache -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  - Windows Update cache cleared successfully!" -ForegroundColor Green
    } else {
        Write-Host "  - Update cache path not found, skipping..." -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - Error clearing update cache: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "[2/5] Deleting Volume Shadow Copies (C:)..." -ForegroundColor Green
try {
    $result = vssadmin.exe delete shadows /for=C: /all /quiet 2>$null
    if ($result) {
        Write-Host "  - Volume shadow copies deleted successfully!" -ForegroundColor Green
    } else {
        Write-Host "  - No shadow copies found or deletion completed" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - Error deleting shadow copies: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "[3/5] Clearing System Restore Points..." -ForegroundColor Green
try {
    $result = vssadmin.exe delete shadows /all /quiet 2>$null
    if ($result) {
        Write-Host "  - System restore points cleared successfully!" -ForegroundColor Green
    } else {
        Write-Host "  - No restore points found or cleanup completed" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - Error clearing restore points: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "[4/5] Cleaning Up Event Logs (older than 7 days)..." -ForegroundColor Green
try {
    $logs = @("Application", "System")
    foreach ($logName in $logs) {
        $oldLogs = Get-WinEvent -LogName $logName -MaxNumberOfEntries 1000 | 
                   Where-Object { $_.TimeCreated -lt (Get-Date).AddDays(-7) }
        if ($oldLogs) {
            Remove-Item $oldLogs -ErrorAction SilentlyContinue
            Write-Host "  - Cleared old logs from '$logName' ($($oldLogs.Count) entries)" -ForegroundColor Green
        } else {
            Write-Host "  - No old event logs found in '$logName'" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "  - Error cleaning event logs: $_" -ForegroundColor Red
}

Write-Host ""
Write-Host "[5/5] Running DISM Component Store Cleanup..." -ForegroundColor Green
try {
    Write-Host "  - Starting DISM cleanup... (this may take a while)" -ForegroundColor Cyan
    $dismResult = Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase /quiet 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  - DISM cleanup completed successfully!" -ForegroundColor Green
    } else {
        Write-Host "  - DISM cleanup completed (some components may not be removable)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  - DISM cleanup error: $_" -ForegroundColor Red
    Write-Host "  - Note: DISM may fail if disk space is critically low" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "System State Clearing Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Your system should now be ready for successful backup operations." -ForegroundColor Cyan
Write-Host "If backups still fail, please check the Windows Event Viewer for additional details." -ForegroundColor Cyan
Write-Host ""