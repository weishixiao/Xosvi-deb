#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tweak（Objective-C++/Logos）括号 sanity：扫描 tweaks/ 下的 .x/.xm/.m/.mm。

默认只报告；--strict 才退出 1。
"""
from __future__ import annotations
import argparse, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from check_swift_braces import strip_code

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main() -> int:
    ap = argparse.ArgumentParser(description="Tweak brace sanity")
    ap.add_argument("--src", default="tweaks")
    ap.add_argument("--strict", action="store_true")
    args = ap.parse_args()
    src = pathlib.Path(args.src)
    if not src.is_absolute():
        src = ROOT / src
    if not src.exists():
        print(f"[FATAL] 目录不存在: {src}")
        return 2
    bad = 0
    files = [p for p in src.rglob("*") if p.suffix in (".x", ".xm", ".m", ".mm")]
    for f in sorted(files):
        code = strip_code(f.read_text(encoding="utf-8", errors="replace"))
        for a, b in (("{", "}"), ("(", ")"), ("[", "]")):
            if code.count(a) != code.count(b):
                print(f"MISMATCH {f.name}: {a}{b} {code.count(a)} vs {code.count(b)}")
                bad += 1
    print(f"checked {len(files)} tweak files, mismatches={bad}")
    if bad and args.strict:
        return 1
    print("OK (report-only)" if not bad else "WARN (report-only; use --strict to fail)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
