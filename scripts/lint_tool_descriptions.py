#!/usr/bin/env python3
# -*- coding: utf-8 -*-
r"""Xosvi 工具描述 lint（CI 友好）。

检查项（对每个 ToolDefinition(...) 块）：
  L1 [ERROR] 必须包含三段式描述标记：Use for / Don't use for / Example
  L2 [ERROR] 描述中的点分工具引用（如 "use injection.enable"）
             必须命中注册表（源码扫描到的 ToolDefinition name），否则视为失效引用
  L3 [ERROR] 工具名规范：^[a-z][a-z0-9_]*(\.[a-z0-9_]+)*$
  L4 [WARN]  建议包含 verified: / category:；建议有 parameters/paramSpecs 之一
  L5 [WARN]  出现 "ta " 前缀调用提示（旧契约残留）

说明：
  - 启发式解析：按 ToolDefinition( 分块，块首 400 字符内取 name，
    块首 6000 字符内做 L1/L2/L5 检查。
  - 误报豁免：在块内任意处加注释 `// lint:ignore` 可跳过该块。
  - 首次接入建议先 `--warn-only` 盘点存量，清零 ERROR 后再进 CI。

用法：
  python3 scripts/lint_tool_descriptions.py
  python3 scripts/lint_tool_descriptions.py --src Sources/Xosvi --warn-only

退出码：有 ERROR 且非 --warn-only -> 1；否则 0。
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

DEF_START_RE = re.compile(r"ToolDefinition\s*\(")
NAME_RE = re.compile(r"name\s*:\s*\"([^\"]+)\"")
REF_RE = re.compile(r"\buse[sd]?\s+([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)\b", re.I)
NAME_OK_RE = re.compile(r"^[a-z][a-z0-9_]*(\.[a-z0-9_]+)*$")
TA_RE = re.compile(r"\bta\s+[a-z]", re.I)
IGNORE_MARK = "lint:ignore"

HEAD_LIMIT = 6000
NAME_LIMIT = 400


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi tool description lint")
    p.add_argument("--src", default="Sources/Xosvi",
                   help="源码目录（默认相对仓库根 Sources/Xosvi）")
    p.add_argument("--warn-only", action="store_true",
                   help="只报告，不因 ERROR 失败")
    p.add_argument("--fail-on-refs", action="store_true",
                   help="只把 L2 失效引用当作失败（L1 三段式存量先不阻断）")
    return p.parse_args(argv)


def resolve_src(raw: str) -> Path:
    p = Path(raw)
    if not p.is_absolute():
        p = (REPO_ROOT / p).resolve()
    if not p.exists() or not p.is_dir():
        print(f"[FATAL] 源码目录不存在: {p}")
        sys.exit(2)
    return p


def iter_def_blocks(text: str):
    """把源码按 ToolDefinition( 切成块；返回 (块起始 index, 块内容)。"""
    starts = [m.start() for m in DEF_START_RE.finditer(text)]
    for i, s in enumerate(starts):
        e = starts[i + 1] if i + 1 < len(starts) else len(text)
        yield s, text[s:e]


def collect_registered_names(src: Path) -> set[str]:
    names: set[str] = set()
    for f in sorted(src.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        for _, block in iter_def_blocks(text):
            m = NAME_RE.search(block[:NAME_LIMIT])
            if m:
                names.add(m.group(1))
    return names


def main(argv=None) -> int:
    args = parse_args(argv)
    src = resolve_src(args.src)

    registry = collect_registered_names(src)
    print(f"registry names collected: {len(registry)}")

    errors = 0
    warns = 0
    ref_errors = 0
    total_blocks = 0

    for f in sorted(src.rglob("*.swift")):
        text = f.read_text(encoding="utf-8", errors="replace")
        for start, block in iter_def_blocks(text):
            total_blocks += 1
            if IGNORE_MARK in block[:HEAD_LIMIT]:
                continue

            line_no = text.count("\n", 0, start) + 1
            name_m = NAME_RE.search(block[:NAME_LIMIT])
            name = name_m.group(1) if name_m else "(unknown)"
            head = block[:HEAD_LIMIT]
            loc = f"{f.name}:{line_no}"

            # L3 名称规范
            if name != "(unknown)" and not NAME_OK_RE.match(name):
                errors += 1
                print(f"[ERROR] {loc} 工具名不合规: '{name}'（要求小写字母开头，仅 [a-z0-9_.]）")

            # L1 三段式
            missing = [tag for tag in ("Use for", "Don't use for", "Example") if tag not in head]
            if missing:
                errors += 1
                print(f"[ERROR] {loc} [{name}] 描述缺少三段式标记: {', '.join(missing)}")

            # L2 点分引用有效性
            for m in REF_RE.finditer(head):
                ref = m.group(1).lower()
                if ref not in {n.lower() for n in registry}:
                    errors += 1
                    ref_errors += 1
                    print(f"[ERROR] {loc} [{name}] 疑似失效引用: 'use {m.group(1)}' "
                          f"（不在注册表中；请改为目标工具+子命令的表述）")

            # L5 ta 前缀残留（只认 "ta <字母>" 的真实调用形态；代码里的字符串字面量不算）
            if TA_RE.search(head):
                warns += 1
                print(f"[WARN]  {loc} [{name}] 描述中出现 'ta ' 前缀痕迹，请核对（契约已禁用 ta 前缀）")

            # L4 建议项
            if "verified:" not in block:
                warns += 1
                print(f"[WARN]  {loc} [{name}] 缺少 verified: 标记")
            if "category:" not in block:
                warns += 1
                print(f"[WARN]  {loc} [{name}] 缺少 category:")
            if "parameters:" not in block and "paramSpecs:" not in block:
                warns += 1
                print(f"[WARN]  {loc} [{name}] 没有 parameters/paramSpecs")

    print(f"\nblocks={total_blocks} errors={errors} warnings={warns}")
    if args.fail_on_refs:
        # L2 失效引用单独统计（A6 的验收口径）
        if ref_errors:
            print(f"FAILED: L2 失效引用 {ref_errors} 处")
            return 1
        print("OK: L2 引用检查通过（L1 三段式存量不阻断）")
        return 0
    if errors and not args.warn_only:
        print("FAILED: 存在 ERROR（可先用 --warn-only 盘点，修完后进 CI）")
        return 1
    print("OK: 描述 lint 通过" + ("（warn-only 模式）" if args.warn_only else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())