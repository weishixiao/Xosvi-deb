#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""括号/结构 sanity（参数化，CI 友好）。

默认扫描 Sources/XosviMCP 全部 .swift；默认只报告不阻断（--strict 才退出 1）。
正确处理字符串（含三引号）、行注释、块注释，避免把 `{` 当代码。
"""
from __future__ import annotations
import argparse, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent


def strip_code(src: str) -> str:
    out = []
    i, n = 0, len(src)
    in_str = False
    triple = False
    esc = False
    in_line = False
    in_block = False
    while i < n:
        if in_line:
            if src[i] == "\n":
                in_line = False
                out.append("\n")
            i += 1
            continue
        if in_block:
            if src.startswith("*/", i):
                in_block = False
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if triple:
                if src.startswith('"""', i):
                    in_str = False
                    triple = False
                    i += 3
                    continue
                i += 1
                continue
            if esc:
                esc = False
            elif src[i] == "\\":
                esc = True
            elif src[i] == '"':
                in_str = False
            i += 1
            continue
        if src.startswith("//", i):
            in_line = True
            i += 2
            continue
        if src.startswith("/*", i):
            in_block = True
            i += 2
            continue
        if src.startswith('"""', i):
            in_str, triple = True, True
            i += 3
            continue
        if src[i] == '"':
            in_str = True
            i += 1
            continue
        out.append(src[i])
        i += 1
    return "".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="Swift brace/paren sanity")
    ap.add_argument("--src", default="Sources/XosviMCP")
    ap.add_argument("--strict", action="store_true", help="有 MISMATCH 时退出 1")
    args = ap.parse_args()
    src = pathlib.Path(args.src)
    if not src.is_absolute():
        src = ROOT / src
    if not src.exists():
        print(f"[FATAL] 目录不存在: {src}")
        return 2

    bad = 0
    files = sorted(src.rglob("*.swift"))
    for f in files:
        code = strip_code(f.read_text(encoding="utf-8", errors="replace"))
        for a, b in (("{", "}"), ("(", ")"), ("[", "]")):
            if code.count(a) != code.count(b):
                print(f"MISMATCH {f.name}: {a}{b} {code.count(a)} vs {code.count(b)}")
                bad += 1
    print(f"checked {len(files)} files, mismatches={bad}")
    if bad and args.strict:
        return 1
    print("OK (report-only)" if not bad else "WARN (report-only; use --strict to fail)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
