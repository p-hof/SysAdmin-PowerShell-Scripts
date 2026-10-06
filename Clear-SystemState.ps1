<#
.SYNOPSIS
    Windows 11 / Cove Data Protection VSS remediation script for NinjaOne.

.DESCRIPTION
    Performs a safe-by-default repair and diagnostic pass for Windows 11
    backup failures involving Volume Shadow Copy Service (VSS).

    Designed for unattended execution from NinjaOne / NinjaRMM as SYSTEM.

    Default behavior:
      - Verifies elevated/SYSTEM execution and Windows 11 workstation OS.
      - Captures pre-remediation VSS writer/provider/shadow/storage status.
      - Reports disk free space and pending reboot indicators.
      - Resets the VSS and Microsoft Software Shadow Copy Provider services.
      - Runs DISM /RestoreHealth.
      - Runs SFC /scannow.
      - Preserves Event Logs.
      - Preserves existing shadow copies / restore points.
      - Captures post-remediation VSS status and recent VSS-related errors.

    Optional behavior is controlled in the CONFIGURATION section below.
    No prompts or command-line parameters are required.

.NOTES
    Historical filename retained for compatibility: Clear-SystemState.ps1

    IMPORTANT:
    If $DeleteExistingShadowCopies is set to $true, the script permanently
    deletes client-accessible shadow copies on local fixed volumes by using
    vssadmin.exe. This can remove Previous Versions and System Restore points.

    VSSADMIN cannot delete every possible VSS snapshot context. The script
    intentionally does NOT use diskshadow.exe to force-delete other snapshot
    types.

.EXITCODES
    0 = Script completed and all parsed VSS writers are healthy.
    1 = Preflight/fatal script failure.
    2 = Script completed, but one or more VSS writers remain unhealthy or
        VSS writer status could not be verified.
#>

& {

# ============================================================
# CONFIGURATION
# ============================================================

# DESTRUCTIVE. Keep FALSE for the normal/safe remediation pass.
# Change to TRUE only when you intentionally want to remove existing
# client-accessible VSS shadow copies / restore points.
$DeleteExistingShadowCopies = $false

# Optional Windows Update cache cleanup.
# This is not required for most Cove/VSS issues, so it is disabled by default.
$ClearWindowsUpdateDownloadCache = $false

# Core Windows image repair. Recommended for backup/VSS remediation.
$RunDISMRestoreHealth = $true

# Protected system file repair. Recommended after DISM.
$RunSFC = $true

# Optional WinSxS/component maintenance.
# /ResetBase is intentionally NOT used.
$RunComponentCleanup = $false

# Display recent VSS/Volsnap/backup warnings and errors without deleting logs.
$ShowRecentVssEvents = $true

# Safety guard: abort if the target is not a Windows 11 workstation.
$RequireWindows11Workstation = $true

# Number of days of recent VSS-related Event Log history to display.
$EventLookbackDays = 7


# ============================================================
# GLOBAL SETTINGS
# ============================================================

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$ScriptName = "Clear-SystemState.ps1"
$ScriptVersion = "2.0.1"
$StartTime = Get-Date

$LogRoot = Join-Path $env:ProgramData "Cove-VSS-Remediation"
$TranscriptStarted = $false
$TranscriptPath = $null


# ============================================================
# HELPER FUNCTIONS
# ============================================================

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)

    Write-Host ""
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ""
    Write-Host $Text -ForegroundColor Green
}

function Write-Info {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  - $Text" -ForegroundColor Cyan
}

function Write-Warn {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  - WARNING: $Text" -ForegroundColor Yellow
}

function Write-Fail {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "  - ERROR: $Text" -ForegroundColor Red
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$DisplayOutput
    )

    $commandText = "$FilePath $($ArgumentList -join ' ')".Trim()
    Write-Info "Running: $commandText"

    try {
        $output = @(& $FilePath @ArgumentList 2>&1)
        $exitCode = $LASTEXITCODE

        if ($DisplayOutput -and $output.Count -gt 0) {
            foreach ($line in $output) {
                Write-Host "      $line"
            }
        }

        return [pscustomobject]@{
            Command  = $commandText
            ExitCode = $exitCode
            Output   = $output
        }
    }
    catch {
        Write-Fail "Unable to execute '$commandText': $($_.Exception.Message)"
        return [pscustomobject]@{
            Command  = $commandText
            ExitCode = -1
            Output   = @($_.Exception.Message)
        }
    }
}

function Test-Administrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)

        return $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    }
    catch {
        return $false
    }
}

function Test-PendingReboot {
    $reasons = New-Object System.Collections.Generic.List[string]

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        $reasons.Add("Component Based Servicing: RebootPending")
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        $reasons.Add("Windows Update: RebootRequired")
    }

    try {
        $pendingFileRename = (Get-ItemProperty `
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue).PendingFileRenameOperations

        if ($pendingFileRename) {
            $reasons.Add("Session Manager: PendingFileRenameOperations")
        }
    }
    catch {
        # Best-effort check only.
    }

    return @($reasons)
}

function Get-VssWriterReport {
    $rawOutput = @(& "$env:SystemRoot\System32\vssadmin.exe" list writers 2>&1)
    $exitCode = $LASTEXITCODE

    $writers = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($line in $rawOutput) {
        $text = [string]$line

        if ($text -match "Writer name:\s+'(.+)'") {
            if ($null -ne $current) {
                $writers.Add([pscustomobject]$current)
            }

            $current = [ordered]@{
                Name      = $Matches[1]
                StateCode = $null
                State     = $null
                LastError = $null
                Healthy   = $false
            }
            continue
        }

        if ($null -ne $current -and $text -match "State:\s+\[(\d+)\]\s+(.+)$") {
            $current.StateCode = [int]$Matches[1]
            $current.State = $Matches[2].Trim()
            continue
        }

        if ($null -ne $current -and $text -match "Last error:\s+(.+)$") {
            $current.LastError = $Matches[1].Trim()
            continue
        }
    }

    if ($null -ne $current) {
        $writers.Add([pscustomobject]$current)
    }

    foreach ($writer in $writers) {
        $writer.Healthy = (
            $writer.State -eq "Stable" -and
            $writer.LastError -eq "No error"
        )
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Raw       = $rawOutput
        Writers   = @($writers)
    }
}

function Show-VssWriterReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Label
    )

    Write-Host ""
    Write-Host "$Label VSS WRITER STATUS" -ForegroundColor Cyan
    Write-Host ("-" * 70)

    if ($Report.ExitCode -ne 0) {
        Write-Fail "vssadmin list writers returned exit code $($Report.ExitCode)."
        foreach ($line in $Report.Raw) {
            Write-Host "      $line"
        }
        return
    }

    if ($Report.Writers.Count -eq 0) {
        Write-Warn "No VSS writers were parsed. Raw vssadmin output follows:"
        foreach ($line in $Report.Raw) {
            Write-Host "      $line"
        }
        return
    }

    foreach ($writer in $Report.Writers) {
        $stateText = "$($writer.State)"
        if ($writer.LastError) {
            $stateText += " / $($writer.LastError)"
        }

        if ($writer.Healthy) {
            Write-Host ("  [OK]     {0} - {1}" -f $writer.Name, $stateText) -ForegroundColor Green
        }
        else {
            Write-Host ("  [ISSUE]  {0} - {1}" -f $writer.Name, $stateText) -ForegroundColor Yellow
        }
    }

    $healthyCount = @($Report.Writers | Where-Object Healthy).Count
    $problemCount = @($Report.Writers | Where-Object { -not $_.Healthy }).Count

    Write-Host ""
    Write-Info "Healthy writers: $healthyCount"
    if ($problemCount -gt 0) {
        Write-Warn "Unhealthy writers: $problemCount"
    }
    else {
        Write-Info "Unhealthy writers: 0"
    }
}

function Show-DiskStatus {
    Write-Host ""
    Write-Host "LOCAL FIXED DISK STATUS" -ForegroundColor Cyan
    Write-Host ("-" * 70)

    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
            Sort-Object DeviceID

        foreach ($disk in $disks) {
            $sizeGB = if ($disk.Size) {
                [math]::Round($disk.Size / 1GB, 2)
            } else {
                0
            }

            $freeGB = if ($disk.FreeSpace) {
                [math]::Round($disk.FreeSpace / 1GB, 2)
            } else {
                0
            }

            $freePct = if ($disk.Size -gt 0) {
                [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
            } else {
                0
            }

            $line = "{0}  Free: {1} GB / {2} GB ({3}%)" -f `
                $disk.DeviceID, $freeGB, $sizeGB, $freePct

            if ($freePct -lt 10) {
                Write-Warn $line
            }
            else {
                Write-Info $line
            }
        }
    }
    catch {
        Write-Warn "Unable to query fixed disk free space: $($_.Exception.Message)"
    }
}

function Show-VssInventory {
    Write-Host ""
    Write-Host "VSS PROVIDERS" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    $null = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\vssadmin.exe" `
        -ArgumentList @("list", "providers") `
        -DisplayOutput

    Write-Host ""
    Write-Host "EXISTING SHADOW COPIES" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    $null = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\vssadmin.exe" `
        -ArgumentList @("list", "shadows") `
        -DisplayOutput

    Write-Host ""
    Write-Host "SHADOW STORAGE" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    $null = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\vssadmin.exe" `
        -ArgumentList @("list", "shadowstorage") `
        -DisplayOutput
}

function Reset-VssServices {
    Write-Step "[REPAIR] Resetting VSS infrastructure services..."

    $serviceNames = @("VSS", "swprv")
    $originalState = @{}

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        if (-not $service) {
            Write-Warn "Service '$serviceName' was not found."
            continue
        }

        $originalState[$serviceName] = $service.Status

        try {
            $service.Refresh()

            if ($service.Status -ne "Stopped") {
                Write-Info "Stopping $serviceName..."
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                (Get-Service -Name $serviceName).WaitForStatus(
                    [System.ServiceProcess.ServiceControllerStatus]::Stopped,
                    [TimeSpan]::FromSeconds(30)
                )
            }

            Write-Info "Starting $serviceName..."
            Start-Service -Name $serviceName -ErrorAction Stop
            (Get-Service -Name $serviceName).WaitForStatus(
                [System.ServiceProcess.ServiceControllerStatus]::Running,
                [TimeSpan]::FromSeconds(30)
            )

            Write-Info "$serviceName reset successfully."
        }
        catch {
            Write-Warn "Unable to fully reset '$serviceName': $($_.Exception.Message)"
        }
    }

    return $originalState
}

function Restore-VssServiceStates {
    param([hashtable]$OriginalState)

    if (-not $OriginalState) {
        return
    }

    Write-Step "[CLEANUP] Restoring original VSS service running/stopped state..."

    foreach ($serviceName in $OriginalState.Keys) {
        try {
            $current = Get-Service -Name $serviceName -ErrorAction Stop
            $wasRunning = ($OriginalState[$serviceName] -eq "Running")

            if (-not $wasRunning -and $current.Status -ne "Stopped") {
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
                Write-Info "$serviceName returned to its original stopped state."
            }
            elseif ($wasRunning -and $current.Status -ne "Running") {
                Start-Service -Name $serviceName -ErrorAction Stop
                Write-Info "$serviceName returned to its original running state."
            }
            else {
                Write-Info "$serviceName already matches its original state."
            }
        }
        catch {
            Write-Warn "Unable to restore original state for '$serviceName': $($_.Exception.Message)"
        }
    }
}

function Clear-WindowsUpdateDownloadCache {
    Write-Step "[OPTIONAL] Clearing Windows Update download cache..."

    $cachePath = Join-Path $env:SystemRoot "SoftwareDistribution\Download"
    $serviceNames = @("BITS", "wuauserv")
    $originalStates = @{}

    foreach ($serviceName in $serviceNames) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            $originalStates[$serviceName] = $service.Status
        }
    }

    try {
        foreach ($serviceName in $serviceNames) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.Status -ne "Stopped") {
                Write-Info "Stopping $serviceName..."
                Stop-Service -Name $serviceName -Force -ErrorAction Stop
            }
        }

        if (Test-Path $cachePath) {
            $items = @(Get-ChildItem -Path $cachePath -Force -ErrorAction SilentlyContinue)

            if ($items.Count -eq 0) {
                Write-Info "Windows Update download cache is already empty."
            }
            else {
                $items | Remove-Item -Recurse -Force -ErrorAction Stop
                Write-Info "Windows Update download cache cleared."
            }
        }
        else {
            Write-Warn "Cache path not found: $cachePath"
        }
    }
    catch {
        Write-Warn "Windows Update cache cleanup was incomplete: $($_.Exception.Message)"
    }
    finally {
        foreach ($serviceName in $originalStates.Keys) {
            try {
                if ($originalStates[$serviceName] -eq "Running") {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Write-Info "$serviceName returned to running state."
                }
            }
            catch {
                Write-Warn "Unable to restore '$serviceName': $($_.Exception.Message)"
            }
        }
    }
}

function Remove-ClientAccessibleShadowCopies {
    Write-Step "[DESTRUCTIVE] Deleting existing client-accessible shadow copies..."

    Write-Warn "This action is permanent and can remove Previous Versions and System Restore points."

    try {
        $volumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
            Where-Object { $_.DeviceID -match "^[A-Z]:$" } |
            Sort-Object DeviceID

        if (-not $volumes) {
            Write-Warn "No local fixed volumes with drive letters were found."
            return
        }

        foreach ($volume in $volumes) {
            $drive = $volume.DeviceID

            Write-Info "Deleting client-accessible shadows for $drive ..."

            $result = Invoke-NativeCommand `
                -FilePath "$env:SystemRoot\System32\vssadmin.exe" `
                -ArgumentList @(
                    "delete",
                    "shadows",
                    "/for=$drive",
                    "/all",
                    "/quiet"
                ) `
                -DisplayOutput

            if ($result.ExitCode -eq 0) {
                Write-Info "Shadow-copy deletion command completed for $drive."
            }
            else {
                Write-Warn "vssadmin returned exit code $($result.ExitCode) for $drive."
            }
        }
    }
    catch {
        Write-Warn "Shadow-copy cleanup encountered an error: $($_.Exception.Message)"
    }
}

function Invoke-DISMRestoreHealth {
    Write-Step "[REPAIR] Running DISM RestoreHealth..."

    $result = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\Dism.exe" `
        -ArgumentList @(
            "/Online",
            "/Cleanup-Image",
            "/RestoreHealth"
        ) `
        -DisplayOutput

    if ($result.ExitCode -eq 0) {
        Write-Info "DISM RestoreHealth completed successfully."
    }
    else {
        Write-Warn "DISM RestoreHealth returned exit code $($result.ExitCode)."
    }

    return $result.ExitCode
}

function Invoke-SystemFileChecker {
    Write-Step "[REPAIR] Running System File Checker..."

    $result = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\sfc.exe" `
        -ArgumentList @("/scannow") `
        -DisplayOutput

    if ($result.ExitCode -eq 0) {
        Write-Info "SFC completed."
    }
    else {
        Write-Warn "SFC returned exit code $($result.ExitCode). Review its output above."
    }

    return $result.ExitCode
}

function Invoke-ComponentCleanup {
    Write-Step "[OPTIONAL] Running DISM component-store cleanup..."

    $result = Invoke-NativeCommand `
        -FilePath "$env:SystemRoot\System32\Dism.exe" `
        -ArgumentList @(
            "/Online",
            "/Cleanup-Image",
            "/StartComponentCleanup"
        ) `
        -DisplayOutput

    if ($result.ExitCode -eq 0) {
        Write-Info "Component cleanup completed successfully."
    }
    else {
        Write-Warn "Component cleanup returned exit code $($result.ExitCode)."
    }

    return $result.ExitCode
}

function Show-RecentVssEvents {
    param(
        [int]$LookbackDays = 7
    )

    Write-Step "[DIAGNOSTIC] Recent VSS / Volsnap / backup warnings and errors..."

    $start = (Get-Date).AddDays(-1 * [math]::Abs($LookbackDays))
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($logName in @("Application", "System")) {
        try {
            $events = Get-WinEvent `
                -FilterHashtable @{
                    LogName   = $logName
                    StartTime = $start
                    Level     = @(2, 3)
                } `
                -MaxEvents 300 `
                -ErrorAction Stop

            foreach ($logEvent in $events) {
                $provider = [string]$logEvent.ProviderName
                $message = [string]$logEvent.Message

                if (
                    $provider -match "(?i)VSS|Volsnap|Backup" -or
                    $message -match "(?i)volume shadow|shadow copy|\bVSS\b"
                ) {
                    $results.Add([pscustomobject]@{
                        TimeCreated  = $logEvent.TimeCreated
                        LogName      = $logName
                        ProviderName = $provider
                        Id           = $logEvent.Id
                        Level        = $logEvent.LevelDisplayName
                        Message      = $message
                    })
                }
            }
        }
        catch {
            Write-Warn "Unable to query '$logName' log: $($_.Exception.Message)"
        }
    }

    $results = @(
        $results |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 20
    )

    if ($results.Count -eq 0) {
        Write-Info "No matching warning/error events found in the last $LookbackDays day(s)."
        return
    }

    foreach ($logEvent in $results) {
        $message = ($logEvent.Message -replace "\r?\n", " " -replace "\s{2,}", " ").Trim()

        if ($message.Length -gt 500) {
            $message = $message.Substring(0, 500) + "..."
        }

        Write-Host ""
        Write-Host (
            "  [{0}] {1} | {2} | Event {3} | {4}" -f `
            $logEvent.Level,
            $logEvent.TimeCreated,
            $logEvent.ProviderName,
            $logEvent.Id,
            $logEvent.LogName
        ) -ForegroundColor Yellow

        Write-Host "      $message"
    }
}


# ============================================================
# PREFLIGHT
# ============================================================

Write-Section "Cove / VSS Backup Remediation - $ScriptName v$ScriptVersion"

Write-Host "Computer              : $env:COMPUTERNAME"
Write-Host "Execution identity    : $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "Started               : $StartTime"
Write-Host ""

Write-Host "CONFIGURATION" -ForegroundColor Cyan
Write-Host ("-" * 70)
Write-Host ("Delete shadow copies       : {0}" -f $DeleteExistingShadowCopies)
Write-Host ("Clear Windows Update cache : {0}" -f $ClearWindowsUpdateDownloadCache)
Write-Host ("Run DISM RestoreHealth     : {0}" -f $RunDISMRestoreHealth)
Write-Host ("Run SFC                    : {0}" -f $RunSFC)
Write-Host ("Run component cleanup      : {0}" -f $RunComponentCleanup)
Write-Host ("Show recent VSS events     : {0}" -f $ShowRecentVssEvents)

if (-not (Test-Administrator)) {
    Write-Fail "Administrative/SYSTEM privileges are required."
    exit 1
}

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $version = [version]$os.Version

    Write-Host ""
    Write-Host "OPERATING SYSTEM" -ForegroundColor Cyan
    Write-Host ("-" * 70)
    Write-Host "Caption     : $($os.Caption)"
    Write-Host "Version     : $($os.Version)"
    Write-Host "Build       : $($os.BuildNumber)"
    Write-Host "ProductType : $($os.ProductType)"

    if ($RequireWindows11Workstation) {
        $isWorkstation = ($os.ProductType -eq 1)
        $isWindows11Build = ($version.Build -ge 22000)

        if (-not ($isWorkstation -and $isWindows11Build)) {
            Write-Fail "Safety check failed: target is not a Windows 11 workstation."
            Write-Fail "No remediation changes were made."
            exit 1
        }
    }
}
catch {
    Write-Fail "Unable to identify operating system: $($_.Exception.Message)"
    exit 1
}

try {
    if (-not (Test-Path $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $TranscriptPath = Join-Path $LogRoot "$env:COMPUTERNAME-$timestamp.log"

    Start-Transcript -Path $TranscriptPath -Force -ErrorAction Stop | Out-Null
    $TranscriptStarted = $true
    Write-Info "Local transcript: $TranscriptPath"
}
catch {
    Write-Warn "Unable to start local transcript: $($_.Exception.Message)"
}


# ============================================================
# PRE-REMEDIATION DIAGNOSTICS
# ============================================================

Write-Section "PRE-REMEDIATION DIAGNOSTICS"

Show-DiskStatus

$pendingReboot = @(Test-PendingReboot)
Write-Host ""
Write-Host "PENDING REBOOT CHECK" -ForegroundColor Cyan
Write-Host ("-" * 70)

if ($pendingReboot.Count -gt 0) {
    foreach ($reason in $pendingReboot) {
        Write-Warn $reason
    }
}
else {
    Write-Info "No common pending-reboot indicators detected."
}

$preVss = Get-VssWriterReport
Show-VssWriterReport -Report $preVss -Label "PRE-REMEDIATION"

Show-VssInventory


# ============================================================
# REMEDIATION
# ============================================================

Write-Section "REMEDIATION"

$vssOriginalStates = Reset-VssServices

if ($ClearWindowsUpdateDownloadCache) {
    Clear-WindowsUpdateDownloadCache
}
else {
    Write-Step "[SKIP] Windows Update download-cache cleanup is disabled."
}

if ($DeleteExistingShadowCopies) {
    Remove-ClientAccessibleShadowCopies
}
else {
    Write-Step "[SAFE MODE] Existing shadow copies are being preserved."
    Write-Info "Set `$DeleteExistingShadowCopies = `$true only for an intentional aggressive pass."
}

if ($RunDISMRestoreHealth) {
    $null = Invoke-DISMRestoreHealth
}
else {
    Write-Step "[SKIP] DISM RestoreHealth is disabled."
}

if ($RunSFC) {
    $null = Invoke-SystemFileChecker
}
else {
    Write-Step "[SKIP] System File Checker is disabled."
}

if ($RunComponentCleanup) {
    $null = Invoke-ComponentCleanup
}
else {
    Write-Step "[SKIP] Component-store cleanup is disabled."
}


# ============================================================
# POST-REMEDIATION DIAGNOSTICS
# ============================================================

Write-Section "POST-REMEDIATION DIAGNOSTICS"

$postVss = Get-VssWriterReport
Show-VssWriterReport -Report $postVss -Label "POST-REMEDIATION"

Show-VssInventory

if ($ShowRecentVssEvents) {
    Show-RecentVssEvents -LookbackDays $EventLookbackDays
}
else {
    Write-Step "[SKIP] Recent VSS event display is disabled."
}

Restore-VssServiceStates -OriginalState $vssOriginalStates


# ============================================================
# FINAL SUMMARY
# ============================================================

Write-Section "FINAL SUMMARY"

$endTime = Get-Date
$duration = New-TimeSpan -Start $StartTime -End $endTime

$unhealthyWriters = @(
    $postVss.Writers |
    Where-Object { -not $_.Healthy }
)

Write-Host "Computer               : $env:COMPUTERNAME"
Write-Host "Completed              : $endTime"
Write-Host ("Duration               : {0:hh\:mm\:ss}" -f $duration)
Write-Host "Shadow copies deleted  : $DeleteExistingShadowCopies"

if ($DeleteExistingShadowCopies) {
    Write-Warn "Aggressive mode was enabled. Client-accessible shadow copies were targeted for deletion."
}
else {
    Write-Info "Safe mode was used. Existing shadow copies were preserved."
}

if ($postVss.ExitCode -ne 0 -or $postVss.Writers.Count -eq 0) {
    Write-Warn "VSS writer health could not be verified after remediation."
    $finalExitCode = 2
}
elseif ($unhealthyWriters.Count -gt 0) {
    Write-Warn "$($unhealthyWriters.Count) VSS writer(s) remain unhealthy."
    Write-Warn "Review the writer names above and perform writer-specific remediation before retrying Cove."
    $finalExitCode = 2
}
else {
    Write-Host ""
    Write-Host "RESULT: All parsed VSS writers are Stable / No error." -ForegroundColor Green
    Write-Host "Retry the Cove backup job and review the Cove result." -ForegroundColor Green
    $finalExitCode = 0
}

if ($pendingReboot.Count -gt 0) {
    Write-Host ""
    Write-Warn "A pending reboot was detected before remediation."
    Write-Warn "If backup problems continue, reboot the endpoint before escalating to destructive VSS cleanup."
}

if ($TranscriptStarted) {
    try {
        Write-Host ""
        Write-Info "Transcript saved to: $TranscriptPath"
        Stop-Transcript | Out-Null
    }
    catch {
        # Do not alter final exit status for transcript cleanup.
    }
}

exit $finalExitCode
}
