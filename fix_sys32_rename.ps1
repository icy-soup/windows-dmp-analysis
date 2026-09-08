# fix_sys32_rename.ps1 - Replace WRP-protected System32 CRT DLLs while they are in use
#
#   msvcp140.dll / vcruntime140.dll / concrt140.dll
#
# WHY THIS EXISTS
# Same problem as fix_sys32_crt.ps1: on Insider / dev builds (known: 26200) WRP
# blocks the VC++ Redist from updating System32's copies, so the three CRT DLLs
# stay at 14.0.24215.1 and apps crash with 0xC0000005 inside msvcp140.dll.
#
# Directly overwriting those DLLs often fails because a running process has them
# memory-mapped. Windows still lets you RENAME a mapped image file (image sections
# are opened with FILE_SHARE_DELETE), so the trick is:
#   1. stage a copy of the new DLL as <name>.new
#   2. rename the live <name>.dll to <name>.<oldver>.old
#   3. move <name>.new into <name>.dll
# This was verified to work on build 26200 with NO reboot - every process that
# started afterward picks up the new DLL.
#
# REQUIREMENTS
#   - Run as Administrator
#   - Source of newer DLLs: Microsoft Edge WebView2 WinSxS component
#     (auto-detected), or a folder extracted from the redist:
#         vc_redist.x64.exe /x C:\crt144
#   - Rollback: rename the .old files back, or restore from System Restore.
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File fix_sys32_rename.ps1
#   powershell -ExecutionPolicy Bypass -File fix_sys32_rename.ps1 -Source C:\crt144
#
param(
    [string]$Source,                          # dir containing the NEW dlls (auto-detect if empty)
    [string]$LogFile                          # default: .\fix_sys32_rename.log next to this script
)

$sys32 = "$env:WINDIR\System32"
$dlls  = @("msvcp140.dll", "vcruntime140.dll", "concrt140.dll")

if (-not $LogFile) { $LogFile = Join-Path $PSScriptRoot "fix_sys32_rename.log" }

# 0. Elevation check
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "ERROR: run this script as Administrator." -ForegroundColor Red
    exit 1
}

Set-Content -Path $LogFile -Value ("=== System32 CRT rename+replace start " + (Get-Date -Format s) + " ===") -Encoding ascii
function Log($msg) { Add-Content -Path $LogFile -Value $msg -Encoding ascii; Write-Host $msg }

# 1. Locate a source dir that has the three DLLs
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
    if ($cand) { $Source = $cand.Path }
}
if (-not $Source -or -not (Test-Path $Source)) {
    Log "ERROR: no usable source dir. Pass -Source <dir> (extract with 'vc_redist.x64.exe /x <dir>') or make sure Edge WebView2 is installed."
    exit 1
}
$SrcVer = (Get-Item (Join-Path $Source "msvcp140.dll")).VersionInfo.FileVersion
$missing = $dlls | Where-Object { -not (Test-Path (Join-Path $Source $_)) }
if ($missing) { Log ("ERROR: source dir is missing: " + ($missing -join ", ")); exit 1 }
Log ("Source: " + $Source + "  (version " + $SrcVer + ")")

# 2. Per DLL: stage -> rename live to .old -> move staged into place
foreach ($d in $dlls) {
    $live    = Join-Path $sys32 $d
    $staged  = "$live.new"
    $oldVer  = (Get-Item $live).VersionInfo.FileVersion
    $old     = "$live.$oldVer.old"
    if (-not (Test-Path (Join-Path $Source $d))) {
        Log ("SKIP: source file missing: " + (Join-Path $Source $d)); continue
    }
    if (-not (Test-Path $live)) {
        Log ("SKIP: System32 file missing: " + $live); continue
    }

    # 2a) stage the new copy
    try {
        Copy-Item (Join-Path $Source $d) $staged -Force -ErrorAction Stop
        Log ("staged " + $d + " -> " + (Get-Item $staged).VersionInfo.FileVersion)
    } catch {
        Log ("stage FAILED: " + $d + " : " + $_.Exception.Message); continue
    }

    # 2b) rename the live (possibly in-use) file
    try {
        Rename-Item $live $old -Force -ErrorAction Stop
        Log ("renamed old: " + $d)
    } catch {
        Log ("rename FAILED: " + $d + " : " + $_.Exception.Message)
        Remove-Item $staged -Force -ErrorAction SilentlyContinue
        continue
    }

    # 2c) move the staged copy into the live name
    try {
        Move-Item $staged $live -Force -ErrorAction Stop
        Log ("moved new into place: " + $d)
    } catch {
        Log ("move FAILED: " + $d + " : " + $_.Exception.Message + " - restoring old")
        Rename-Item $old $live -Force -ErrorAction SilentlyContinue
    }
}

# 3. Final verify
foreach ($d in $dlls) {
    $live = Join-Path $sys32 $d
    if (Test-Path $live) {
        Log ("VERIFY " + $d + " = " + (Get-Item $live).VersionInfo.FileVersion)
    } else {
        Log ("VERIFY " + $d + " = MISSING")
    }
}
Log "=== done ==="
