#!/usr/bin/env python3
"""Validate that every `register(XxxTool())` in registerBuiltinTools has a class
definition with a ToolDefinition(name:).

v7.17.0: 旧版硬编码作者本机路径 C:\\Users\\q3711\\...，除作者外必然失效（CI 永远跑不了）。
现在默认从脚本相对路径取源码，也支持 --src / XOSVI_SRC 覆盖。

Usage:
  python3 scripts/check_tool_registration.py [--src Sources/Xosvi]
Exit 1 on missing class / missing tool name / duplicate tool name.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path


def strip_comments(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            if src.startswith('"""', i):
                j = i + 3
                while j < n and not src.startswith('"""', j):
                    j += 2 if src[j] == "\\" else 1
                out.append(src[i:min(j + 3, n)])
                i = min(j + 3, n)
                continue
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == '"':
                    j += 1
                    break
                j += 1
            out.append(src[i:j])
            i = j
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def find_block(src: str, start: int) -> str:
    i = src.find("{", start)
    if i < 0:
        return ""
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j]
        j += 1
    return src[i:]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=os.environ.get("XOSVI_SRC", str(root / "Sources" / "Xosvi")))
    args = ap.parse_args()

    src_dir = Path(args.src)
    if not src_dir.exists():
        print(f"src not found: {src_dir}", file=sys.stderr)
        return 2

    classes: dict[str, str | None] = {}
    for f in sorted(src_dir.glob("*.swift")):
        text = strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
        for m in re.finditer(r"(?:final\s+)?class\s+(\w+)\s*:\s*MCPTool\b", text):
            tail = text[m.end(): m.end() + 20000]
            nm = re.search(r'name\s*:\s*"([^"]+)"', tail)
            classes[m.group(1)] = nm.group(1) if nm else None

    core_path = src_dir / "MCPCore.swift"
    if not core_path.exists():
        print(f"missing {core_path}", file=sys.stderr)
        return 2
    core = strip_comments(core_path.read_text(encoding="utf-8", errors="ignore"))
    m = re.search(r"func\s+registerBuiltinTools\(\)", core)
    body = find_block(core, m.start()) if m else ""
    registered = re.findall(r"register\(\s*(\w+)\s*\(\s*\)\s*\)", body)

    errors: list[str] = []
    seen: dict[str, str] = {}
    for cname in registered:
        if cname not in classes:
            errors.append(f"register({cname}()) but class not found in sources")
            continue
        nm = classes[cname]
        if not nm:
            errors.append(f"register({cname}()) but no ToolDefinition(name:) found")
            continue
        if nm in seen:
            errors.append(f"duplicate tool name '{nm}' ({cname} and {seen[nm]})")
        seen[nm] = cname

    print(f"registered: {len(registered)}, unique names: {len(seen)}, classes: {len(classes)}")
    if errors:
        print("ERRORS:")
        for e in errors:
            print("  -", e)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
