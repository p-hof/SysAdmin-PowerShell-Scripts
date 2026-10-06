# Cove / VSS Windows 11 Backup Remediation

`Clear-SystemState.ps1` is a Windows 11 remediation and diagnostic script intended for deployment through **NinjaOne / NinjaRMM as SYSTEM** when Cove Data Protection backups are failing because of suspected Volume Shadow Copy Service (VSS), VSS writer, or Windows component corruption issues.

The historical filename is retained so the script can replace the previous `Clear-SystemState.ps1` without changing an existing Ninja script name or Git workflow.

> **Important:** The default configuration is intentionally safe. It does **not** delete existing VSS shadow copies, System Restore points, Previous Versions, or Event Logs.

---

## Why this version replaces the old script

The previous script performed several actions that were either overly destructive or did not work as intended:

- It deleted VSS shadow copies automatically.
- It then attempted a second, broader shadow-copy deletion.
- It labeled `vssadmin delete shadows /all` as "clearing System Restore points," even though VSS shadow copies can represent more than System Restore data.
- It attempted to delete individual Windows Event Log entries with `Remove-Item`, which is not how Windows Event Logs work.
- It used `DISM /StartComponentCleanup /ResetBase`, which removes the ability to uninstall superseded Windows updates.
- It reported completion even when VSS writers had not actually been checked before and after remediation.

This replacement takes a **diagnose -> repair -> verify** approach.

---

## What the script does by default

The default run performs the following actions:

1. Confirms the script is running elevated / as SYSTEM.
2. Confirms the target is a Windows 11 workstation.
3. Creates a local transcript under:

   ```text
   C:\ProgramData\Cove-VSS-Remediation\
   ```

4. Reports free space on local fixed disks.
5. Checks for common pending-reboot indicators.
6. Captures **pre-remediation**:
   - VSS writer status
   - VSS providers
   - Existing shadow copies
   - Shadow-storage configuration
7. Resets:
   - Volume Shadow Copy (`VSS`)
   - Microsoft Software Shadow Copy Provider (`swprv`)
8. Runs:

   ```text
   DISM.exe /Online /Cleanup-Image /RestoreHealth
   ```

9. Runs:

   ```text
   sfc.exe /scannow
   ```

10. Captures **post-remediation** VSS status.
11. Displays recent VSS / Volsnap / backup warnings and errors from the Application and System logs.
12. Restores the VSS service running/stopped state to what it was before the script ran.
13. Returns a meaningful NinjaOne exit code.

Cove uses Windows VSS writers and Volume Shadow Copy to create a consistent virtual copy of files before backup, so writer/provider health is directly relevant to Cove backup troubleshooting.

---

## Default configuration

Configuration is controlled at the top of the script. No prompts and no command-line switches are required.

```powershell
$DeleteExistingShadowCopies = $false
$ClearWindowsUpdateDownloadCache = $false
$RunDISMRestoreHealth = $true
$RunSFC = $true
$RunComponentCleanup = $false
$ShowRecentVssEvents = $true
$RequireWindows11Workstation = $true
$EventLookbackDays = 7
```

This makes the script suitable for unattended NinjaOne execution as **SYSTEM**.

---

## Recommended NinjaOne deployment

### Preferred: Automation Library / Run Automation

For production deployment, save `Clear-SystemState.ps1` in the NinjaOne Automation Library and run it using **Run Automation -> Script** as SYSTEM. This is preferable to manually pasting a long script into the remote PowerShell terminal.

### Remote System PowerShell console

NinjaOne's System PowerShell option is an interactive PowerShell console. Version 2.0.1 wraps the script body in an outer `& { ... }` script block so that, when the **entire script is pasted at once**, PowerShell keeps parsing the complete block before executing it. This avoids the common interactive-paste problem where an `if` block can execute before a following `else` line is received.

If using the remote console, paste the entire script in one operation rather than pasting individual sections.


Deploy the script using the normal NinjaOne PowerShell / System context.

Recommended settings:

- Run as: **SYSTEM**
- Architecture: **64-bit PowerShell**
- User interaction: **None**
- Reboot: **Do not reboot automatically**
- Parameters: **None required**

Do not run the remediation while a Cove backup job is actively creating a snapshot. Run it after a failed job or before intentionally retrying the backup.

---

## Recommended troubleshooting workflow

### Pass 1 - Safe remediation

Leave:

```powershell
$DeleteExistingShadowCopies = $false
```

Run the script from NinjaOne.

Then review the output for:

```text
POST-REMEDIATION VSS WRITER STATUS
```

Ideally every writer should report:

```text
Stable / No error
```

Then retry the Cove backup.

This safe pass can resolve issues caused by:

- Transient VSS service/provider state
- Windows component corruption
- Damaged protected system files
- Pending/stale VSS writer state that clears after the VSS infrastructure is reset
- OS servicing issues affecting VSS components

---

## Pass 2 - Aggressive shadow-copy cleanup

If the Cove backup continues to fail and the failure points toward stale/corrupt shadow-copy state, change:

```powershell
$DeleteExistingShadowCopies = $false
```

to:

```powershell
$DeleteExistingShadowCopies = $true
```

and rerun the script.

### Warning

This is destructive.

The script will issue `vssadmin delete shadows` against local fixed volumes.

Deleting a shadow copy is permanent and can remove data used by:

- System Restore
- Previous Versions
- Other client-accessible Windows shadow copies

Return the setting to:

```powershell
$DeleteExistingShadowCopies = $false
```

after the aggressive remediation pass.

The script intentionally does **not** use `diskshadow.exe` to force-delete snapshot types that `vssadmin` cannot remove.

---

## Windows Update cache cleanup

Windows Update cache removal is available but disabled by default:

```powershell
$ClearWindowsUpdateDownloadCache = $false
```

Enable it only when Windows Update / servicing problems are also suspected:

```powershell
$ClearWindowsUpdateDownloadCache = $true
```

The script temporarily stops BITS and Windows Update, clears the contents of:

```text
C:\Windows\SoftwareDistribution\Download
```

and then restores services that were running before the cleanup.

This is not normally necessary for a VSS-only Cove failure.

---

## Component-store cleanup

Optional component-store maintenance is also disabled by default:

```powershell
$RunComponentCleanup = $false
```

To enable it:

```powershell
$RunComponentCleanup = $true
```

The command used is:

```text
DISM.exe /Online /Cleanup-Image /StartComponentCleanup
```

The script intentionally does **not** use:

```text
/ResetBase
```

because `/ResetBase` removes superseded component versions and prevents those superseded Windows updates from being uninstalled.

---

## Event Logs

The script **does not clear Event Logs**.

Instead, it displays recent warning/error events associated with:

- VSS
- Volsnap
- Backup-related providers/messages
- Volume Shadow Copy errors

The default lookback is:

```powershell
$EventLookbackDays = 7
```

This preserves troubleshooting evidence rather than deleting it.

---

## Pending reboot detection

The script checks several common pending-reboot indicators.

If a reboot is pending, Ninja output will contain a warning.

A reboot is not performed automatically.

If the safe remediation completes but Cove still fails, a reboot should generally be considered before enabling destructive shadow-copy cleanup.

---

## NinjaOne exit codes

| Exit code | Meaning |
|---|---|
| `0` | Script completed and all parsed VSS writers are `Stable / No error`. |
| `1` | Preflight or fatal script failure, such as not running elevated or targeting an unsupported OS. |
| `2` | Remediation completed, but one or more VSS writers remain unhealthy or writer status could not be verified. |

An exit code of `2` is intentional. It allows NinjaOne to flag a machine that still requires attention rather than reporting a false success.

---

## Example healthy result

```text
POST-REMEDIATION VSS WRITER STATUS
----------------------------------------------------------------------

  [OK]     Task Scheduler Writer - Stable / No error
  [OK]     VSS Metadata Store Writer - Stable / No error
  [OK]     Performance Counters Writer - Stable / No error
  [OK]     System Writer - Stable / No error

  - Healthy writers: 4
  - Unhealthy writers: 0

RESULT: All parsed VSS writers are Stable / No error.
Retry the Cove backup job and review the Cove result.
```

The actual number and names of writers vary by endpoint.

---

## If a writer is still failed

A generic VSS reset cannot safely restart every application-specific VSS writer service.

For example, some VSS writers belong to SQL Server, IIS, Exchange, application services, or other workload-specific components. Automatically restarting all possible writer services could interrupt production applications.

If the script returns exit code `2`:

1. Identify the failed writer in the Ninja output.
2. Review the related Event Log entries shown by the script.
3. Restart or repair the service/application that owns that writer.
4. Rerun the safe remediation.
5. Retry Cove.
6. Use destructive shadow-copy cleanup only when the failure actually points toward existing snapshot/shadow-storage state.

---

## Safety changes from the old version

This version intentionally:

- Does **not** clear Windows Event Logs.
- Does **not** use `DISM /ResetBase`.
- Does **not** automatically delete shadow copies.
- Does **not** force-delete non-client-accessible VSS snapshots with DiskShadow.
- Does **not** restart arbitrary application-specific VSS writer services.
- Does **not** pause for user input.
- Does **not** require command-line parameters.
- Does **not** automatically reboot the endpoint.
- Does **not** claim success without checking VSS writers afterward.

---

## Scope

The script is intentionally restricted to Windows 11 workstation operating systems by default:

```powershell
$RequireWindows11Workstation = $true
```

This prevents an accidental Ninja deployment to a Windows Server from performing workstation-oriented remediation.

Do not disable this safety check merely to use the script on servers. Server workloads can have application-specific VSS writers and should be handled with a server-specific remediation procedure.

---

## Local logging

In addition to NinjaOne's activity/script output, a transcript is written to:

```text
C:\ProgramData\Cove-VSS-Remediation\
```

The filename includes the computer name and timestamp.

Example:

```text
C:\ProgramData\Cove-VSS-Remediation\PC-001-20261006-121500.log
```

---

## Notes about VSSADMIN

`vssadmin list writers` is used to enumerate subscribed VSS writers.

The script also uses:

```text
vssadmin list providers
vssadmin list shadows
vssadmin list shadowstorage
```

When aggressive mode is enabled, `vssadmin delete shadows` is used.

Microsoft documents that `vssadmin delete shadows` only deletes supported/client-accessible shadow copies. If Windows reports that snapshots exist outside the allowed context, this script deliberately stops there rather than escalating to an indiscriminate DiskShadow deletion.

---

## References

- Microsoft VSSADMIN documentation  
  https://learn.microsoft.com/windows-server/administration/windows-commands/vssadmin

- Microsoft `vssadmin delete shadows` documentation  
  https://learn.microsoft.com/windows-server/administration/windows-commands/vssadmin-delete-shadows

- Microsoft Volume Shadow Copy Service overview  
  https://learn.microsoft.com/windows-server/storage/file-server/volume-shadow-copy-service

- Microsoft WinSxS / component-store cleanup documentation  
  https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11

- Microsoft System File Checker guidance  
  https://support.microsoft.com/windows/experience/backup-recovery/use-the-system-file-checker-tool-to-repair-missing-or-corrupted-system-files

- N-able Cove Data Protection - Backup FAQ / VSS usage  
  https://documentation.n-able.com/covedataprotection/USERGUIDE/QSG/Content/backup-manager/backup-manager-guide/faqs-backup.htm
