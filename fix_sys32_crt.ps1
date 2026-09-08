# fix_sys32_crt.ps1 - Replace WRP-protected System32 CRT DLLs with newer ones
#
#   msvcp140.dll / vcruntime140.dll / concrt140.dll
#
# WHY THIS EXISTS
# On Windows Insider / dev builds (known: 26200) the VC++ 2015-2022 Redist
# reports a successful install but its overwrite of the System32 copies is
# silently blocked by WRP (Windows Resource Protection). The three legacy DLLs
# stay at an ancient version (14.0.24215.1) while applications crash at random
# offsets with 0xC0000005 ACCESS_VIOLATION / NULL dereference inside msvcp140.dll.
#
# This is the takeown + direct-copy approach, with a PendingFileRenameOperations
# fallback that replaces any DLL still in use at next reboot.
#
# A variant that replaces the DLLs WHILE they are in use (no reboot) is in
# fix_sys32_rename.ps1 - prefer that one if you can run it.
#
# REQUIREMENTS
#   - Run as Administrator
#   - Source of newer DLLs: Microsoft Edge WebView2 WinSxS component
#     (auto-detected), or a folder extracted from the redist:
#         vc_redist.x64.exe /x C:\crt144
#   - Rollback: restore the backup DLLs from -BackupDir, or System Restore point.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File fix_sys32_crt.ps1
#   powershell -ExecutionPolicy Bypass -File fix_sys32_crt.ps1 -Source C:\crt144
#
param(
    [string]$Source,                          # dir containing the NEW dlls (auto-detect if empty)
    [string]$BackupDir,                       # default: .\sys32_crt_backup next to this script
    [string]$LogFile                          # default: .\fix_sys32_crt.log next to this script
)

$sys32 = "$env:WINDIR\System32"
$dlls  = @("msvcp140.dll", "vcruntime140.dll", "concrt140.dll")

if (-not $BackupDir) { $BackupDir = Join-Path $PSScriptRoot "sys32_crt_backup" }
if (-not $LogFile)   { $LogFile   = Join-Path $PSScriptRoot "fix_sys32_crt.log" }

# 0. Elevation check
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "ERROR: run this script as Administrator." -ForegroundColor Red
    exit 1
}

Set-Content -Path $LogFile -Value ("=== System32 CRT fix start " + (Get-Date -Format s) + " ===") -Encoding ascii
function Log($msg) { Add-Content -Path $LogFile -Value $msg -Encoding ascii; Write-Host $msg }

# 1. Locate a source dir that has the three DLLs
$SrcVer = $null
if (-not $Source) {
    Log "Auto-detecting Edge WebView2 WinSxS component ..."
    $cand = Get-ChildItem "$env:WINDIR\WinSxS" -Directory -Filter "amd64_microsoft-edge-webview_*" -ErrorAction SilentlyContinue |
        ForEach-Object {
            $m = Join-Path $_.FullName "msvcp140.dll"
            if (Test-Path $m) {
                try { $v = [version](Get-Item $m).VersionInfo.FileVersion } catch { $v = $null }
                if ($v) { [pscustomobject]@{ Path = $_.FullName; Version = $v } }
            }
        } | Sort-Object Version -Descending | Select-Object -First 1
    if ($cand) { $Source = $cand.Path; $SrcVer = $cand.Version.ToString() }
}
if (-not $Source -or -not (Test-Path $Source)) {
    Log "ERROR: no usable source dir. Pass -Source <dir> (extract with 'vc_redist.x64.exe /x <dir>') or make sure Edge WebView2 is installed."
    exit 1
}
if (-not $SrcVer) { $SrcVer = (Get-Item (Join-Path $Source "msvcp140.dll")).VersionInfo.FileVersion }
$missing = $dlls | Where-Object { -not (Test-Path (Join-Path $Source $_)) }
if ($missing) { Log ("ERROR: source dir is missing: " + ($missing -join ", ")); exit 1 }
Log ("Source: " + $Source + "  (version " + $SrcVer + ")")

# 2. Restore point (best effort)
try {
    Checkpoint-Computer -Description "Before System32 CRT update" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop | Out-Null
    Log "Restore point created"
} catch {
    Log ("Restore point skipped: " + $_.Exception.Message)
}

# 3. Backup originals
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
foreach ($d in $dlls) {
    $f = Join-Path $sys32 $d
    if (Test-Path $f) { Copy-Item $f (Join-Path $BackupDir $d) -Force; Log ("Backed up " + $d) }
}

# 4. takeown + grant admins full control so the WRP-protected files can be overwritten
foreach ($d in $dlls) {
    $f = Join-Path $sys32 $d
    if (Test-Path $f) {
        takeown /f $f | Out-Null
        icacls $f /grant administrators:F | Out-Null
        Log ("takeown+icacls: " + $d)
    }
}

# 5. Try a direct in-place overwrite; collect any that fail or stay old
$needReboot = New-Object System.Collections.ArrayList
foreach ($d in $dlls) {
    $t = Join-Path $sys32 $d
    try {
        Copy-Item (Join-Path $Source $d) $t -Force -ErrorAction Stop
        $cur = (Get-Item $t).VersionInfo.FileVersion
        if ($cur -eq $SrcVer) {
            Log ("DIRECT OK: " + $d + " -> " + $cur)
        } else {
            Log ("DIRECT ran but version stayed " + $cur + "; queueing reboot replace for " + $d)
            [void]$needReboot.Add($d)
        }
    } catch {
        Log ("DIRECT FAILED: " + $d + " : " + $_.Exception.Message)
        [void]$needReboot.Add($d)
    }
}

# 6. PendingFileRenameOperations fallback: staged copy replaces the live file at next boot
if ($needReboot.Count -gt 0) {
    $temp = Join-Path $env:WINDIR "Temp\crt140"
    New-Item -ItemType Directory -Path $temp -Force | Out-Null
    $pending = New-Object System.Collections.ArrayList
    foreach ($d in $needReboot) {
        $staged = Join-Path $temp $d
        Copy-Item (Join-Path $Source $d) $staged -Force
        [void]$pending.Add(("\??\" + $staged))
        [void]$pending.Add(("!\??\" + (Join-Path $sys32 $d)))
        Log ("QUEUED reboot replacement: " + $d)
    }
    $reg = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Control\Session Manager", $true)
    if ($reg) {
        $reg.SetValue("PendingFileRenameOperations", $pending.ToArray(), [Microsoft.Win32.RegistryValueKind]::MultiString)
        $reg.Close()
        Log "PendingFileRenameOperations written - REBOOT REQUIRED"
    } else {
        Log "ERROR: could not open Session Manager key"
    }
} else {
    Log "All DLLs replaced in place - no reboot needed"
}

# 7. Final verify (files queued for reboot still show the old version until then)
foreach ($d in $dlls) {
    $t = Join-Path $sys32 $d
    if (Test-Path $t) { Log ("VERIFY " + $d + " = " + (Get-Item $t).VersionInfo.FileVersion) }
}
Log "=== done ==="
