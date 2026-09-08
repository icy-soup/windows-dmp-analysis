#!/usr/bin/env python3
"""Windows minidump (.dmp) quick analyzer.

Parses the exception record, loaded modules, and threads out of a dump file and
prints the key facts needed for a first diagnosis:

  - exception code / flags / address
  - which loaded module was executing (module name + offset from base)
  - NULL-pointer vs invalid-address hint
  - full loaded module list and thread list

Usage:
    python3 analyze_dump.py <path\\to\\crash.dmp>

Requires:
    pip3 install minidump
"""
import sys

from minidump.minidumpfile import MinidumpFile

if len(sys.argv) < 2:
    print(__doc__)
    sys.exit(1)

dump_path = sys.argv[1]
md = MinidumpFile.parse(dump_path)

try:
    modules = md.modules.modules
except Exception:
    modules = []


def mod_name(m):
    try:
        return str(m.name).split("\\")[-1].split("/")[-1]
    except Exception:
        return "<unknown>"


def module_at(addr):
    """Return (name, base, size) of the module whose image range contains addr.

    Falls back to the nearest module loaded below addr so the crash offset can
    still be shown even when the size field is unavailable.
    """
    best = None
    for m in modules:
        try:
            base = int(m.baseaddress)
            size = int(m.SizeOfImage)
        except Exception:
            base = int(m.baseaddress)
            size = 0
        if base <= addr:
            if best is None or base > best[0]:
                best = (base, size, mod_name(m))
    if best is None:
        return None
    base, size, name = best
    if size and addr >= base + size:
        return None
    return name, base, size


ex = md.exception
if ex and getattr(ex, "exception_records", None):
    rec = ex.exception_records[0]
    er = rec.ExceptionRecord
    tid = rec.ThreadId
    code = int(er.ExceptionCode_raw)
    addr = int(er.ExceptionAddress)
    info = list(er.ExceptionInformation)
    flags = er.ExceptionFlags

    print(f"线程ID: {tid}")
    print(f"异常代码: {er.ExceptionCode} (0x{code:08X})")
    print(f"异常标志: {flags}")
    print(f"异常地址: 0x{addr:016X}")

    codes = {
        0xC0000005: "EXCEPTION_ACCESS_VIOLATION - 内存访问违规",
        0x80000003: "EXCEPTION_BREAKPOINT - 断点命中",
        0xC0000094: "EXCEPTION_INT_DIVIDE_BY_ZERO - 整数除零",
        0xC00000FD: "EXCEPTION_STACK_OVERFLOW - 堆栈溢出",
        0xC0000135: "EXCEPTION_DLL_NOT_FOUND - DLL找不到",
        0xC0000142: "EXCEPTION_DLL_INIT_FAILED - DLL初始化失败",
        0xE06D7363: "C++ 异常 (Microsoft C++ Exception)",
        0xC0000374: "堆损坏",
        0xC0000409: "安全检查失败 (/GS编译选项)",
    }
    print(f"异常说明: {codes.get(code, '未知异常')}")

    hit = module_at(addr)
    if hit:
        name, base, size = hit
        print(f"\n崩溃模块: {name}")
        print(f"模块基址: 0x{base:X}  模块大小: 0x{size:X}")
        print(f"崩溃偏移: 0x{addr - base:X}  (相对 {name} 基址)")
    else:
        print("\n崩溃模块: 地址不在任何已加载模块范围内")

    if code == 0xC0000005:
        op = "读" if (info and info[0] == 0) else "写"
        target = info[1] if len(info) > 1 else -1
        print(f"访问类型: {op}操作")
        print(f"目标地址: 0x{target:016X}")
        if target == 0:
            print("\n*** 根本原因: 空指针解引用 (NULL pointer dereference) ***")
            print("    程序试图访问内存地址 0x0 (NULL)，导致崩溃")
        elif 0 < target < 0x10000:
            print(f"\n*** 根本原因: 疑似空指针+小偏移访问 (NULL+0x{target:X}) ***")
        else:
            print(f"\n*** 原因: 访问了非法地址 0x{target:016X} ***")
        print(f"\n异常参数: {info}")
else:
    print("未找到异常记录")

print(f"\n系统: Windows {md.sysinfo.MajorVersion}.{md.sysinfo.MinorVersion} build {md.sysinfo.BuildNumber}")
print(f"架构: {md.sysinfo.ProcessorArchitecture}")

print(f"\n=== 加载的模块 ({len(modules)} 个) ===")
for m in modules:
    try:
        base = int(m.baseaddress)
        size = int(m.SizeOfImage)
        print(f"  0x{base:016X}  0x{size:08X}  {mod_name(m)}")
    except Exception:
        pass

try:
    threads = md.threads.threads
    print(f"\n=== 线程信息 ({len(threads)} 个) ===")
    for t in threads:
        try:
            print(f"  线程ID: {t.ThreadId} (0x{t.ThreadId:08X})  Teb: 0x{t.Teb:016X}")
        except Exception:
            pass
except Exception:
    pass
