#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""导出 / 校验 Xosvi 工具注册表快照。

  python3 scripts/dump_registry.py                                  # 打印 JSON
  python3 scripts/dump_registry.py --out docs/registry.snapshot.json
  python3 scripts/dump_registry.py --check docs/registry.snapshot.json   # CI 用

快照内容：{"count": N, "names": [...], "tools": {name: {category, verified, ...}}}
（稳定输出，便于 diff）。
--check 模式：快照不一致时列出 added/removed 并退出 1。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEF_START_RE = re.compile(r"ToolDefinition\s*\(")
NAME_RE = re.compile(r"name\s*:\s*\"([^\"]+)\"")
CATEGORY_RE = re.compile(r"category\s*:\s*\"([^\"]+)\"")
NAME_LIMIT = 600
BLOCK_LIMIT = 8000


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi registry snapshot tool")
    p.add_argument("--src", default="Sources/XosviMCP")
    p.add_argument("--out", default=None, help="写入快照文件（不存在则创建父目录）")
    p.add_argument("--check", default=None, help="与快照文件比对，不一致退出 1")
    return p.parse_args(argv)


def resolve_src(raw: str) -> Path:
    p = Path(raw)
    if not p.is_absolute():
        p = (REPO_ROOT / p).resolve()
    if not p.exists():
        print(f"[FATAL] 源码目录不存在: {p}")
        sys.exit(2)
    return p


def collect_tools(src: Path) -> dict[str, dict]:
    tools: dict[str, dict] = {}
    for f in sorted(src.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        starts = [m.start() for m in DEF_START_RE.finditer(text)]
        for i, s in enumerate(starts):
            e = starts[i + 1] if i + 1 < len(starts) else len(text)
            block = text[s:e]
            m = NAME_RE.search(block[:NAME_LIMIT])
            if not m:
                continue
            name = m.group(1)
            head = block[:BLOCK_LIMIT]
            meta: dict = {
                "file": f.name,
                "category": (CATEGORY_RE.search(head).group(1) if CATEGORY_RE.search(head) else ""),
                "verified": bool(re.search(r"verified\s*:\s*true", head)),
                "requires_jailbreak": bool(re.search(r"requiresJailbreak\s*:\s*true", head)),
                "requires_trollstore": bool(re.search(r"requiresTrollStore\s*:\s*true", head)),
                "remote_only": bool(re.search(r"remoteOnly\s*:\s*true", head)),
            }
            # 同名冲突：保留第一个，并在报告里可见
            if name in tools:
                meta["duplicate_of"] = tools[name]["file"]
            tools[name] = meta
    return tools


def main(argv=None) -> int:
    args = parse_args(argv)
    src = resolve_src(args.src)
    tools = collect_tools(src)
    names = sorted(tools)
    payload = {
        "count": len(names),
        "names": names,
        "tools": {n: tools[n] for n in names},
    }
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)

    if args.out:
        out = Path(args.out)
        if not out.is_absolute():
            out = REPO_ROOT / out
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text + "\n", encoding="utf-8")
        print(f"snapshot written: {out} ({len(names)} tools)")
        return 0

    if args.check:
        snap = Path(args.check)
        if not snap.is_absolute():
            snap = REPO_ROOT / snap
        if not snap.exists():
            print(f"::warning:: 快照文件不存在: {snap}（先运行 --out 生成并提交）")
            return 0
        old = json.loads(snap.read_text(encoding="utf-8"))
        old_names = set(old.get("names", []))
        new_names = set(names)
        added = sorted(new_names - old_names)
        removed = sorted(old_names - new_names)
        if not added and not removed:
            print(f"snapshot OK ({len(names)} tools)")
            return 0
        print("[ERROR] 工具注册表与快照不一致：")
        for n in added:
            print(f"  + {n}")
        for n in removed:
            print(f"  - {n}")
        print("若为有意变更：运行 --out 更新快照并提交（破坏性变更请在 PR 说明里标注）。")
        return 1

    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
