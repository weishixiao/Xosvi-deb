#!/usr/bin/env python3
"""Fast structural sanity check for Swift sources.

This is not a compiler. It catches the class of error that has actually bitten this
repo: unbalanced braces/parens/brackets after a large edit, usually caused by a
string literal or comment being counted as code.

Usage:
  python3 scripts/check_swift_braces.py [--src Sources/Xosvi] [file ...]
Exit code 1 on any imbalance.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path


def strip_strings_and_comments(src: str) -> str:
    out: list[str] = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # Swift raw string: #"..."# / ##"..."## (also #"""..."""#)
        if c == "#":
            h = 0
            while i + h < n and src[i + h] == "#":
                h += 1
            if i + h < n and src[i + h] == '"':
                quote_start = i + h
                triple = src.startswith('"""', quote_start)
                close = ('"""' if triple else '"') + ("#" * h)
                j = quote_start + (3 if triple else 1)
                k = src.find(close, j)
                i = n if k < 0 else k + len(close)
                out.append('""')
                continue
        if c == '"':
            if src.startswith('"""', i):
                j = i + 3
                while j < n and not src.startswith('"""', j):
                    j += 2 if src[j] == "\\" else 1
                j = min(j + 3, n)
                out.append('""')
                i = j
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
            out.append('""')
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


def check(path: Path) -> list[str]:
    src = path.read_text(encoding="utf-8", errors="ignore")
    s = strip_strings_and_comments(src)
    problems: list[str] = []
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    for a, b in pairs:
        if s.count(a) != s.count(b):
            problems.append(f"{a}{b} mismatch: {s.count(a)} vs {s.count(b)}")
    # 行尾孤立的 } 往往是整块被误删的信号（只在缩进为 0 时提示）
    lines = s.splitlines()
    for idx, line in enumerate(lines, 1):
        if line.startswith("}") and idx < len(lines):
            prev = next((l for l in reversed(lines[: idx - 1]) if l.strip()), "")
            if prev.rstrip().endswith(("(", "[", ",", "=")):
                problems.append(f"line {idx}: closing brace after an incomplete expression")
    return problems


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--src", default=str(root / "Sources" / "Xosvi"))
    args = ap.parse_args()

    if args.files:
        files = [Path(f) for f in args.files]
    else:
        files = sorted(Path(args.src).glob("*.swift"))
    if not files:
        print(f"no swift files under {args.src}", file=sys.stderr)
        return 2

    bad = 0
    for f in files:
        problems = check(f)
        if problems:
            bad += 1
            print(f"FAIL {f.name}")
            for p in problems:
                print("   ", p)
    print(f"checked {len(files)} files, {bad} with problems")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
