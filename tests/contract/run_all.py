#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L1 契约层总入口：依次跑注册一致性 / 描述引用 / 注册表快照。

用法：
  python3 tests/contract/run_all.py
  python3 tests/contract/run_all.py --warn-only   # 只报告，不因失败退出非 0

退出码：0 = 全绿；1 = 有失败；2 = 环境问题（缺脚本）。
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CHECKS = [
    ("注册一致性", [sys.executable, "scripts/check_tool_registration.py", "--src", "Sources/Xosvi"]),
    ("描述引用有效性", [sys.executable, "scripts/lint_tool_descriptions.py", "--src", "Sources/Xosvi", "--fail-on-refs"]),
    ("注册表快照", [sys.executable, "scripts/dump_registry.py", "--src", "Sources/Xosvi",
                    "--check", "docs/registry.snapshot.json"]),
]


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description="Xosvi L1 contract checks")
    p.add_argument("--warn-only", action="store_true", help="失败不退出非 0")
    args = p.parse_args(argv)

    results = []
    for name, cmd in CHECKS:
        print(f"\n=== {name} ===")
        try:
            r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        except FileNotFoundError as e:
            print(f"[FATAL] {e}")
            results.append((name, 2, "script missing"))
            continue
        out = (r.stdout or "") + (r.stderr or "")
        # 只打印尾部，避免刷屏
        print("\n".join(out.strip().splitlines()[-12:]))
        results.append((name, r.returncode, out.strip().splitlines()[-1] if out.strip() else ""))

    print("\n=== 汇总 ===")
    failed = 0
    for name, code, tail in results:
        status = "PASS" if code == 0 else ("SKIP" if code == 2 else "FAIL")
        if status == "FAIL":
            failed += 1
        print(f"{status:4}  {name:12}  {tail[:80]}")

    if failed:
        print(f"\n{failed} 项失败")
        return 0 if args.warn_only else 1
    print("\nALL CONTRACT CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
