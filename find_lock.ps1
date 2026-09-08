# find_lock.ps1 - Find which processes have a DLL/file loaded, and test if it is locked
#
# Typical use: you cannot overwrite C:\Program Files\App\msvcp140.dll because a
# process has it memory-mapped. Point this at that path (or its folder) to see:
#   1. every running process that loaded a module from that location
#   2. whether the file can be opened exclusively (locked check)
#
# USAGE
#   powershell -ExecutionPolicy Bypass -File find_lock.ps1 "C:\Program Files\App\msvcp140.dll"
#   powershell -ExecutionPolicy Bypass -File find_lock.ps1 "C:\Program Files\App"
#
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path
)

$ErrorActionPreference = "SilentlyContinue"

$full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$isFile = Test-Path -LiteralPath $full -PathType Leaf
$dir = if ($isFile) { Split-Path $full -Parent } else { $full }

Write-Host ("Scanning processes that loaded modules under: " + $dir)
Write-Host ""

$found = $false
foreach ($p in Get-Process) {
    $loaded = @()
    try {
        foreach ($m in $p.Modules) {
            $fn = $m.FileName
            if ($fn -and $fn.StartsWith($dir, [System.StringComparison]::OrdinalIgnoreCase)) {
                $loaded += $fn
            }
        }
    } catch {
        # process is protected / access denied / wrong bitness - skip it
    }
    if ($loaded.Count -gt 0) {
        $found = $true
        Write-Host ("PID {0,-6} {1}" -f $p.Id, $p.ProcessName)
        foreach ($fn in $loaded) { Write-Host ("      " + $fn) }
    }
}
if (-not $found) { Write-Host "No running process loaded a module from this location." }

Write-Host ""
if ($isFile) {
    Write-Host ("Lock test: " + $full)
    try {
        $s = [System.IO.File]::Open($full, "Open", "Read", "None")
        $s.Close()
        Write-Host "  File is NOT locked - it can be replaced right now."
    } catch {
        Write-Host ("  LOCKED: " + $_.Exception.Message)
    }
} else {
    Write-Host ("Path is a directory; pass a specific file (e.g. a DLL) to run the lock test.")
}
