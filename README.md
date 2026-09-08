# windows-dmp-analysis

分析 Windows 崩溃转储 (.dmp) 文件并修复常见崩溃问题的通用工作流（Claude skill + 可复用脚本）。

## 背景

在 Windows Insider/dev build（已知 26200）上，系统 WRP（Windows Resource Protection）把
`msvcp140.dll`、`vcruntime140.dll`、`concrt140.dll` 标记为受保护文件，导致 VC++ Redist
表面上安装成功、System32 里的副本却更新不动。结果就是**多个与微软无关的应用**在这些 DLL 里
以 NULL 指针解引用（0xC0000005）崩溃。

本仓库记录从 dump 分析到修复的完整经验，并附可直接复用的通用脚本。

## 目录结构

```
├── SKILL.md               # 主 skill 定义：崩溃模式 / 排查步骤 / 异常码速查
├── README.md              # 本文件
├── analyze_dump.py        # 通用 dump 快速分析器（异常码 → 崩溃模块 + 偏移）
├── fix_sys32_crt.ps1      # System32 CRT 根治：takeown+覆盖，失败则重启时替换
├── fix_sys32_rename.ps1   # System32 CRT 根治：DLL 被占用时原地替换（无需重启，推荐）
└── find_lock.ps1          # 查哪个进程加载/锁定了某个 DLL 文件
```

## 分析工具

- **Python minidump 库** — 纯 Python 解析 dump，无需 WinDbg
- **analyze_dump.py** — 一键输出异常码、崩溃模块名与偏移、目标地址、线程/模块列表
- **WinDbg Preview（Store 版）** — 可选，用于 `!analyze -v` 等深度分析

## 核心修复方案

崩溃根因是 **System32 里三个 CRT DLL 被 WRP 卡在旧版**，因此修复分两层：

### 1. 根治：直接替换 System32 的 CRT（推荐，一劳永逸）

换掉 System32 里的旧 CRT，所有受影响应用一并解决。提供两个脚本：

- **`fix_sys32_rename.ps1`（首选）** — Windows 允许对已映射进进程的文件做**重命名**
  （镜像区以 `FILE_SHARE_DELETE` 打开），脚本把在用的 DLL 改名为
  `<name>.<旧版本>.old`，再把 14.44 新副本移入原位。**DLL 占用中也能替换，无需重启**，
  已在 build 26200 实测通过。
- **`fix_sys32_crt.ps1`** — takeown + icacls + 直接覆盖；若某 DLL 因占用覆盖失败，则写入
  `PendingFileRenameOperations`，重启后自动替换。

两者都会**自动探测新 DLL 来源**（Edge WebView2 的 WinSxS 组件，任何带 Edge/WebView2 的
机器都有 14.44 版），并把原文件**备份到 `sys32_crt_backup\`**。没有 Edge/WebView2 时用
`vc_redist.x64.exe /x <目录>` 解压一份即可。

> ⚠️ 需管理员运行；System32 受 WRP 保护，正常情况不要手动改。先确认诊断指向版本落差
> （注册表 14.44.x 而磁盘 14.0.24215.1）再动手。

### 2. 兜底：CWD DLL 重定向（不动 System32）

当无法提升权限、或应用目录有反篡改（DLL 放进游戏/应用目录会被拒）时：

1. 关闭 SafeDllSearchMode：`reg add "HKLM\System\CurrentControlSet\Control\Session Manager" /v SafeDllSearchMode /t REG_DWORD /d 0 /f`
2. 把 14.44 版 DLL 放进独立目录（非应用目录）
3. 用批处理 `start /D "<该目录>" "" "<应用.exe>"` 启动 → 搜索顺序优先命中新版

## 实用技巧

- **限制 WER 崩溃转储保留数量**，避免 C:\ 被 LocalDumps 塞满：
  ```
  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /v DumpCount /t REG_DWORD /d 3 /f
  ```
- **文件被占用改不了？** 先跑 `find_lock.ps1` 看是谁加载/锁了它。

## 触发场景

- 遇到 `.dmp` 文件需要分析
- 应用崩溃，异常码 `0xC0000005`（ACCESS_VIOLATION）
- 崩溃模块为 `msvcp140.dll`、`vcruntime140.dll` 等 VC++ DLL
- 需检查 DLL 版本、诊断 WRP 保护导致 DLL 无法更新的情况
