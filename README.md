# windows-dmp-analysis

分析 Windows 崩溃转储 (.dmp) 文件并修复常见崩溃问题的工作流。

## 背景

在 Windows Insider build 26200 上，系统 WRP（Windows Resource Protection）把 `msvcp140.dll`、`vcruntime140.dll`、`concrt140.dll` 标记为受保护文件，导致 VC++ Redist 无法更新它们。结果就是**多个应用**（AMD Adrenalin、100% Orange Juice）在 `msvcp140.dll` 中以 NULL 指针解引用的方式崩溃。

这个 skill 记录了从 dump 分析到最终修复的完整经验。

## 目录结构

```
├── SKILL.md  # 主 skill 定义
```

## 分析工具

- **Python minidump 库** — 纯 Python 解析 dump，无需 WinDbg
- **WinDbg Preview（Store 版）** — 可选，用于 `!analyze -v` 等深度分析
- **analyze_dump.py** — 自动化分析脚本

## 核心修复方案

用 SafeDllSearchMode=0 + CWD 劫持绕过 DLL 加载限制：

1. 禁用 SafeDllSearchMode（注册表）
2. 将新版 DLL 放在**游戏/应用目录之外**的独立文件夹
3. 用批处理脚本将工作目录设为该文件夹后再启动应用
4. Windows 搜索 DLL 时优先命中新版，同时也避开了反篡改检测

## 触发条件

- 遇到 `.dmp` 文件需要分析
- 应用崩溃，异常码为 `0xC0000005`（ACCESS_VIOLATION）
- 崩溃模块为 `msvcp140.dll`、`vcruntime140.dll` 等 VC++ DLL
- 需要检查 DLL 版本、诊断 WRP 保护导致 DLL 无法更新的情况
