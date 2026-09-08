---
name: windows-dmp-analysis
description: Windows minidump (.dmp) analysis and crash diagnosis workflow. Use whenever the user has a .dmp file, reports a crash with an exception code, investigates application crashes (especially ACCESS_VIOLATION), or encounters DLL loading issues on Windows. Covers dump analysis with Python minidump and WinDbg (Store/SDK), plus web search for crash signatures and hands-on fix procedures for common crash patterns including WRP-protected VC++ DLL issues on Insider builds. Also triggers when user needs to check DLL versions, diagnose "application was unable to start correctly", or fix MSVCP140.dll/VCRUNTIME140.dll related crashes. Always tries fixes proactively instead of just giving advice — copies files, runs commands, modifies configs unless admin elevation is required. Searches the web for ALL unfamiliar crash patterns AND when initial fixes fail.
---

# Windows Dump Analysis & Crash Fix Workflow

A practical guide to analyzing Windows crash dumps and applying fixes based on real-world experience. Covers the tools, the analysis steps, known crash patterns, and the fixes that actually work on systems where traditional approaches fail.

## Tools

### Primary: Python minidump library

Pure Python dump parser — no WinDbg needed for basic analysis.

```
pip3 install minidump
```

Reads exception info, thread list, and loaded modules from any .dmp file.

### Optional: WinDbg (Store version or SDK)

Full-power debugger with `!analyze -v` and heap inspection. Two ways to get it:

**Microsoft Store version (WinDbg Preview / WinDbgX)** — recommended:
- Install: `winget install "WinDbg"` or search Store for "WinDbg"
- Path: `C:\Users\<user>\AppData\Local\Microsoft\WindowsApps\Microsoft.WinDbg_8wekyb3d8bbwe\`
- GUI: `WinDbgX.exe` in that folder (symlink on desktop: `WinDbg.lnk`)
- Console: `cdbX64.exe` in that folder → symlink to actual `cdb.exe` in WindowsApps
- Console invocation from cmd.exe: `cdbX64 -z <dump.dmp> -c "!analyze -v; q"`

**SDK version (classic WinDbg)**:
- Install via: Windows SDK installer → select "Debugging Tools for Windows"
- Path: `C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe`
- **Known caveat**: SDK may install only supporting DLLs without cdb.exe. If so, use Store version instead.

### Analysis script

`analyze_dump.py` — parses a dump and prints the exception code/address, the loaded module executing at the crash address (name + offset), thread info, and the full module list. Run it first thing on any dump.

### Companion scripts (this repo)

- `fix_sys32_rename.ps1` / `fix_sys32_crt.ps1` — the root-cause fix for Pattern 1: replace the WRP-stuck System32 CRT DLLs. The rename variant swaps them while in use (no reboot).
- `find_lock.ps1` — when a DLL cannot be replaced, show which running process has it loaded/locked.

### Detection: Environment check

Before starting, check what's available:

```bash
# Python minidump
python3 -c "from minidump.minidumpfile import MinidumpFile; print('minidump OK')" 2>&1

# WinDbg (Store version)
ls /c/Users/*/AppData/Local/Microsoft/WindowsApps/Microsoft.WinDbg_*/cdbX64.exe 2>/dev/null || echo "WinDbg Store not found"
# WinDbg (SDK version)
ls /c/Program\ Files\ \(x86\)/Windows\ Kits/10/Debuggers/x64/cdb.exe 2>/dev/null || echo "WinDbg SDK not found"

# Dumps in workspace
find . -name "*.dmp" -type f 2>/dev/null
```

## Quick Analysis Flow

When encountering a .dmp file, follow these steps:

### Step 1: Run analysis script

```bash
python3 analyze_dump.py <dump.dmp>
```

Key output:
- **Exception code** — `0xC0000005` = ACCESS_VIOLATION, `0xC0000374` = heap corruption, etc.
- **Exception address** — which module + offset crashed
- **Access type** — read (0) or write (1) at what address
- **NULL pointer** — if target address is 0x0

### Step 2: Identify crashing module

The exception address tells you which DLL/EXE was executing at crash time. Cross-reference with the loaded modules list to determine the module name and base address.

Calculate the crash offset: `crash_offset = exception_address - module_base_address`

### Step 3: Search the web for crash details

**Always search the web** at two points:

1. **When you encounter a crash pattern you haven't seen before** — other people have almost certainly hit the same bug.
2. **When your first fix attempt doesn't work** — don't just tweak the same approach, go search for what you might have missed.

Essential search strategies:

```text
Search for:
- The exact exception code + crashing module (e.g., "0xC0000005 msvcp140.dll")
- The crash offset (e.g., "msvcp140.dll 0x18C34 crash")
- The app name + crash symptom (e.g., "100 Orange Juice MSVCP140.dll crash")
- Search in both English and Chinese for better coverage
- Targets: GitHub issues, Steam community threads, Microsoft answers, Stack Overflow
- If a fix fails: search the error message or symptom you're seeing instead
```

Don't rely purely on your own knowledge or even the known patterns below. A 30-second web search often finds the exact solution.

## Proactive Mindset

This is a hands-on skill. The user came to you to solve problems, not to get advice. Follow these principles:

- **Try before you suggest**. If a fix involves copying files, running a command, or modifying a registry key — do it yourself rather than telling the user to do it (unless it requires admin privileges they need to provide).
- **Verify your work**. After applying a fix, confirm it worked: check file versions, verify DLLs are in place, test the launch.
- **Only punt to the user** when the action requires something you can't do (admin elevation, launching a GUI app, checking if the game opens). When you do ask, give them a specific command or action — not "try this maybe."
- **If something fails, diagnose why**. Don't just try a different random fix — search for the failure, read the error, understand what went wrong.

### Step 4: Check for known patterns

Compare against the crash patterns below. If it matches, follow the corresponding fix.

### Step 5: (Optional) WinDbg deep analysis

If you need stack trace, heap state, or thread context:

```bash
# Store version (from WindowsApps symlink dir):
cdbX64 -z <dump.dmp> -c "!analyze -v; q"

# Or from the WindowsApps directly:
"C:\Program Files\WindowsApps\Microsoft.WinDbg_*\amd64\cdb.exe" -z <dump.dmp> -c "!analyze -v; q"
```

## Known Crash Patterns

Before diving into individual patterns, always search the web for the crash signature (exception code + module + offset). Other people's solutions are your most valuable resource — this skill documents patterns we've personally confirmed, but many more exist online.

### Pattern 1: MSVCP140.dll ACCESS_VIOLATION — WRP block

The most common pattern on Windows Insider/dev builds.

**Symptoms:**
- Exception: `0xC0000005 ACCESS_VIOLATION`
- Crashing module: `msvcp140.dll`
- Access type: **read** (ExceptionInformation[0] = 0)
- Target address: `0x0` (NULL pointer dereference)
- Multiple different apps crash at different offsets in the same DLL

**Confirmed cases:**

| App | Offset in msvcp140.dll | 
|-----|----------------------|
| AMD Adrenalin (amdow.exe) | 0x1b93c |
| 100% Orange Juice (100orange.exe) | 0x18C34 |

Three separate dumps of 100% Orange Juice all crashed at the exact same offset (0x18C34) — 100% reproducible.

**Diagnosis — check DLL version gap:**

```bash
# Check on-disk version (what processes actually load)
powershell -Command "(Get-Item 'C:\Windows\System32\msvcp140.dll').VersionInfo.FileVersion"
# Expected: 14.44.35211.0 or similar
# Typical bad: 14.00.24215.1 (VS2015 RTM — incredibly old)

# Check registry version (what VC++ redist thinks is installed)
powershell -Command "Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -Name Version"
# Shows the version the redist installed to registry

# Golden diagnostic — compare vcruntime140_1.dll vs msvcp140.dll:
powershell -Command "(Get-Item 'C:\Windows\System32\vcruntime140_1.dll').VersionInfo.FileVersion"
powershell -Command "(Get-Item 'C:\Windows\System32\msvcp140.dll').VersionInfo.FileVersion"
```

**Root cause pattern — registry says one thing, disk says another:**

All three VC++ DLLs (msvcp140.dll, vcruntime140.dll, concrt140.dll) are **stuck at v14.0.24215.1** on disk even though the VC++ 2015-2022 Redist (14.44.x) was installed successfully. Only `vcruntime140_1.dll` (a VS2019-era addition) got properly updated.

The reason: Windows build 26200 (an Insider dev build) treats these legacy DLLs as system-protected files via WRP (Windows Resource Protection). The VC++ redist's `CopyFile` call to overwrite System32's copies is silently blocked.

| DLL | System32 build 26200 | Why |
|-----|---------------------|-----|
| msvcp140.dll | 14.0.24215.1 (OLD) | WRP protected |
| vcruntime140.dll | 14.0.24215.1 (OLD) | WRP protected |
| concrt140.dll | 14.0.24215.1 (OLD) | WRP protected |
| vcruntime140_1.dll | 14.44.35211.0 (OK) | New file, not in WRP list |

**Root-cause fix (recommended) — replace the WRP-stuck System32 copies:**

Every affected app loads its CRT from System32, so updating those three DLLs there fixes all of them at once. Two scripts ship with this repo:

- `fix_sys32_rename.ps1` — **preferred**. Windows lets you rename a memory-mapped image (image sections are opened with `FILE_SHARE_DELETE`), so the script renames the live DLL to `<name>.<oldversion>.old` and moves a staged newer copy into place. Works while the DLLs are in use — **no reboot**. Verified on build 26200.
- `fix_sys32_crt.ps1` — takeown + icacls + direct overwrite; any DLL that stays old (still in use) is queued via `PendingFileRenameOperations` and replaced at next boot.

Both auto-detect a source of newer DLLs from the Edge WebView2 WinSxS component and back up the originals to `sys32_crt_backup\`. Without Edge/WebView2, extract from the redist with `vc_redist.x64.exe /x <dir>`. Requires an elevated shell. Only apply when diagnosis confirms the version gap (registry 14.44.x, disk 14.0.24215.1).

**Fix — CWD-based DLL redirection (avoids PoD5/anti-tamper):**

When the target application has anti-tamper that blocks extra DLLs in its directory (like PoD5 in 100% Orange Juice), use this approach:

1. **Disable SafeDllSearchMode** (one-time, requires admin):
   ```
   reg add "HKLM\System\CurrentControlSet\Control\Session Manager" /v SafeDllSearchMode /t REG_DWORD /d 0 /f
   ```
   This changes the DLL search order to: EXE dir → **Current Directory** → System32 → PATH.
   Revert with: `reg add ... /d 1 /f`

2. **Get the 14.44 DLLs** — best source is Edge WebView's WinSxS component (present on any system with Edge/WebView2):
   ```
   C:\Windows\WinSxS\amd64_microsoft-edge-webview_31bf3856ad364e35_10.0.26100.8036_none_2eddbf5f3aa19f00\
   ```
   Contains: msvcp140.dll, vcruntime140.dll, concrt140.dll — all v14.44.35211.0
   
   Alternative: extract from VC++ redist installer: `vc_redist.x64.exe /x <extract_dir>`

3. **Create a fix directory** outside the game/app directory:
   ```
   G:\games\steam\oj_fix\
   ├── msvcp140.dll       (14.44.35211.0)
   ├── vcruntime140.dll   (14.44.35211.0)
   ├── concrt140.dll      (14.44.35211.0)
   └── run_app.bat
   ```

4. **Batch launcher** — sets CWD to fix directory, then launches the app:
   ```bat
   @echo off
   start /D "G:\games\steam\oj_fix" "" "E:\path\to\app.exe"
   pause
   ```

5. **Launch flow**: Double-click .bat → CWD = fix directory → Windows searches CWD before System32 → finds 14.44 DLLs → app loads successfully. Game/app directory has zero extra files, so anti-tamper is satisfied. Steam must be running in background for DRM.

### Pattern 2: VC++ DLL WRP detection

Use this diagnostic when you suspect WRP is blocking VC++ DLL updates (even without a crash dump):

```bash
# The "smoking gun" check — compare registry version vs disk version
echo === Registry (what redist installed) ===
reg query "HKLM\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" /v Version

echo === On disk (what processes actually load) ===
powershell -Command "(Get-Item 'C:\Windows\System32\msvcp140.dll').VersionInfo.FileVersion"
powershell -Command "(Get-Item 'C:\Windows\System32\vcruntime140.dll').VersionInfo.FileVersion"
powershell -Command "(Get-Item 'C:\Windows\System32\concrt140.dll').VersionInfo.FileVersion"

echo === Check vcruntime140_1.dll (VS2019+ only, not WRP protected) ===
powershell -Command "(Get-Item 'C:\Windows\System32\vcruntime140_1.dll').VersionInfo.FileVersion"
```

If registry shows 14.44.x but disk shows 14.0.24215.1, WRP is blocking. This only happens on Insider/dev builds (known: build 26200).

### Pattern 3: General ACCESS_VIOLATION at NULL

When the exception shows `ExceptionInformation=[0, 0]` (read at address 0x0):
- Usually a bug in the crashing code itself (trying to use a pointer that wasn't initialized)
- Check if it's in a third-party DLL or the app's own code
- If consistently in a Microsoft system DLL at a specific offset, it may be a known Windows bug or a version mismatch (see Pattern 1)

### Exception Code Reference

| Code | Name | Common Cause |
|------|------|-------------|
| 0xC0000005 | ACCESS_VIOLATION | NULL pointer / invalid memory access |
| 0x80000003 | BREAKPOINT | Debugger breakpoint hit |
| 0xC0000094 | INT_DIVIDE_BY_ZERO | Integer division by zero |
| 0xC00000FD | STACK_OVERFLOW | Stack overflow (infinite recursion, deep call chain) |
| 0xC0000135 | DLL_NOT_FOUND | Missing dependency DLL |
| 0xC0000142 | DLL_INIT_FAILED | DLL entry point failed |
| 0xE06D7363 | MSVC_CXX_EXCEPTION | C++ exception (catchable if handler exists) |
| 0xC0000374 | HEAP_CORRUPTION | Heap memory corruption detected |
| 0xC0000409 | GS_FAILURE | Buffer overrun detected (/GS compile flag) |

## Script Automation

### analyze_dump.py

The analysis script ([source](./analyze_dump.py)) automates steps 1-3. Run it as the first thing when you get a dump:

```bash
python3 analyze_dump.py path/to/crash.dmp
```

It outputs: exception code and details, crash type (NULL pointer, etc.), system info, loaded modules, thread list, and key module checks.

The script now lives at the repo root ([source](./analyze_dump.py)). Besides the raw fields it resolves the exception address to the containing module name + offset, so step 2's manual cross-reference is automated.

Companion automation scripts (see Tools): `fix_sys32_rename.ps1`, `fix_sys32_crt.ps1` (Pattern 1 root-cause fix), `find_lock.ps1` (find which process holds a DLL).

## Practical Tips

- **Cap WER dump retention** so `LocalDumps` doesn't fill the disk with crash dumps:
  ```
  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v DumpCount /t REG_DWORD /d 3 /f
  ```

## Environment Support

This skill is designed for Windows + MSYS2/Git bash hybrid environments:
- `python3` for running analysis scripts
- `find`/`ls` in bash for locating dumps and tools
- `powershell -Command` for DLL version inspection and registry queries
- `reg` command (in cmd.exe) for registry changes
- `.bat` files for launch scripts (must be ASCII-only, tested in cmd.exe)

## Also see

For writing .bat/.cmd launcher scripts:
- `windows-encoding-testing` skill — encoding discipline, cmd.exe vs bash differences
