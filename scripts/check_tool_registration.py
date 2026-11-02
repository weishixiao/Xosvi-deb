#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Xosvi 工具注册一致性校验（CI 友好，无硬编码路径）。

校验项：
  1) register(XxxTool()) 中出现的类，必须在源码里有 class XxxTool 定义        -> ERROR
  2) ToolDefinition(name: "...") 的工具名不允许重复（跨文件扫描）            -> ERROR
  3) 有 class 定义但未在任何 register(...) 出现的类                          -> WARN
     （--strict-extras 时升级为 ERROR）

用法：
  python3 scripts/check_tool_registration.py
  python3 scripts/check_tool_registration.py --src Sources/XosviMCP
  python3 scripts/check_tool_registration.py --strict-extras

退出码：0 = 通过；1 = 存在 ERROR；2 = 参数/目录错误。
说明：解析为启发式正则扫描，不做完整 Swift 语法分析。
"""
from __future__ import annotations

import argparse
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

CLASS_RE = re.compile(r"\bclass\s+([A-Za-z_]\w*Tool)\b")
REGISTER_RE = re.compile(r"\bregister\s*\(\s*([A-Za-z_]\w*Tool)\s*\(", re.S)
NAME_RE = re.compile(r"ToolDefinition\s*\(\s*name\s*:\s*\"([^\"]+)\"", re.S)


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi tool registration consistency check")
    p.add_argument("--src", default="Sources/XosviMCP",
                   help="源码目录（默认相对仓库根 Sources/XosviMCP）")
    p.add_argument("--strict-extras", action="store_true",
                   help="把「定义了但未注册」的类也视为错误")
    return p.parse_args(argv)


def resolve_src(raw: str) -> Path:
    p = Path(raw)
    if not p.is_absolute():
        p = (REPO_ROOT / p).resolve()
    if not p.exists() or not p.is_dir():
        print(f"[FATAL] 源码目录不存在: {p}")
        sys.exit(2)
    return p


def main(argv=None) -> int:
    args = parse_args(argv)
    src = resolve_src(args.src)

    files = sorted(src.rglob("*.swift"))
    if not files:
        print(f"[FATAL] 目录下没有 .swift 文件: {src}")
        return 2

    defined: set[str] = set()
    registered: set[str] = set()
    names: dict[str, list[str]] = defaultdict(list)

    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        defined.update(CLASS_RE.findall(text))
        registered.update(REGISTER_RE.findall(text))
        for m in NAME_RE.finditer(text):
            line = text.count("\n", 0, m.start()) + 1
            names[m.group(1)].append(f"{f.name}:{line}")

    missing = sorted(registered - defined)
    extras = sorted(defined - registered)
    dup = {k: v for k, v in names.items() if len(v) > 1}

    print(f"files={len(files)} registered={len(registered)} "
          f"defined={len(defined)} tools={len(names)}")

    errors = 0
    if missing:
        errors += len(missing)
        print("\n[ERROR] register() 引用了未定义的类：")
        for c in missing:
            print(f"  - {c}")

    if dup:
        errors += len(dup)
        print("\n[ERROR] 工具名重复（ToolDefinition name 冲突）：")
        for name, locs in sorted(dup.items()):
            print(f"  - {name}: {', '.join(locs)}")

    if extras:
        tag = "[ERROR]" if args.strict_extras else "[WARN]"
        if args.strict_extras:
            errors += len(extras)
        print(f"\n{tag} 已定义但未在 register(...) 出现（可能被其它文件复用）：")
        for c in extras[:40]:
            print(f"  - {c}")
        if len(extras) > 40:
            print(f"  ... 共 {len(extras)} 个")

    if errors:
        print(f"\nFAILED: {errors} error(s)")
        return 1

    print("\nOK: 注册一致性与工具名唯一性检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())