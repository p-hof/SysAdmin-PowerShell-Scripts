# PowerShell script to clear system state for Windows 11 Cove backup failure resolution
# Execute this from NinjaRMM (System) PowerShell prompt

Write-Host "Starting System State Clear..." -ForegroundColor Green

# Clear Windows Update Cache
Write-Host "Clearing Windows Update Cache..." -ForegroundColor Green
\$cachePath = "$env:Windows\SoftwareDistribution\Download"
if (Test-Path \$cachePath) {
    Remove-Item -Path \$cachePath -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Windows Update cache cleared." -ForegroundColor Yellow
}

# Clear Volume Shadow Copies (VSS)
Write-Host "Clearing Volume Shadow Copies..." -ForegroundColor Green
vssadmin.exe delete shadows /for=C: /quiet 2>$null
Write-Host "Volume Shadow Copies cleared." -ForegroundColor Yellow

# Clear System Restore Points
Write-Host "Clearing System Restore Points..." -ForegroundColor Green
vssadmin.exe delete shadows /all /quiet 2>$null
Write-Host "System Restore Points cleared." -ForegroundColor Yellow
