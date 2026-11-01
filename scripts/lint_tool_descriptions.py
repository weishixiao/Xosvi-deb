#!/usr/bin/env python3
"""Lint Xosvi tool descriptions / registry consistency.

P0 checks (exit 1):
  * ToolDefinition(name:) duplicates
  * apiName collisions after sanitisation
  * registered big tool referenced via a bare dotted name that is not a registered
    tool (e.g. "use injection.enable" while only `inject command:enable` exists)
  * ToolDefinition with an empty summary

P1 warnings (exit 0 unless --strict):
  * summary missing "Use for:" / "Don't use for:" / "Example:"
  * registered tool not reachable from defaultEnabledTools

Usage:
  python3 scripts/lint_tool_descriptions.py [--src Sources/Xosvi] [--strict]
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# 文件扩展名 / 域名后缀 / 常见英文缩写，不是工具名
NOT_TOOL_SUFFIX = {
    "com", "org", "net", "io", "cn", "dev", "app", "plist", "dylib", "deb", "ipa",
    "txt", "md", "json", "db", "log", "sh", "swift", "x", "png", "jpg", "zip",
    "tar", "gz", "tgz", "bz2", "sqlite", "xml", "html", "js", "css", "framework", "bundle",
    "mobileprovision", "entitlements", "macho", "pic", "so", "a", "h", "m", "c",
    "py", "rb", "go", "rs", "kt", "java", "mm", "hpp", "cpp", "yml", "yaml", "bin",
    "out", "bak", "bak_macho", "dsym", "tipa", "tar.gz",
}
# 描述里合法出现的「资源.类型」写法
ALLOW_TOKENS = {
    "e.g", "i.e", "etc.", "v1.0", "v2.0", "system.overview", "tools.audit",
    "skills.list", "skills.read", "skills.set_enabled", "web.search", "web.fetch",
    "network.capture", "vpn.capture", "shell.exec", "tool.install", "env.setup_re",
    "app_write_file", "bind_app", "bind_app_write", "prompt.read_mode",
}


def strip_comments(src: str) -> str:
    """Remove // and /* */ comments while preserving string literals."""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            # triple quote
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


def find_definition_blocks(src: str):
    """Yield the text of each `ToolDefinition(` call, brace/paren balanced, string aware."""
    for m in re.finditer(r"ToolDefinition\s*\(", src):
        i = m.end() - 1  # at '('
        depth = 0
        j = i
        n = len(src)
        while j < n:
            c = src[j]
            if c == '"':
                if src.startswith('"""', j):
                    k = j + 3
                    while k < n and not src.startswith('"""', k):
                        k += 2 if src[k] == "\\" else 1
                    j = min(k + 3, n)
                    continue
                k = j + 1
                while k < n:
                    if src[k] == "\\":
                        k += 2
                        continue
                    if src[k] == '"':
                        k += 1
                        break
                    k += 1
                j = k
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    yield src[m.start():j + 1]
                    break
            j += 1


def string_arg(block: str, key: str) -> str | None:
    m = re.search(rf'\b{re.escape(key)}\s*:\s*("""[\s\S]*?"""|"(?:\\.|[^"\\])*")', block)
    if not m:
        return None
    raw = m.group(1)
    if raw.startswith('"""'):
        return raw[3:-3]
    return raw[1:-1].replace('\\"', '"').replace("\\n", "\n")


def declared_name(block: str) -> str | None:
    return string_arg(block, "name")


def registered_classes(src: str) -> list[str]:
    m = re.search(r"func\s+registerBuiltinTools\(\)\s*\{", src)
    if not m:
        return []
    i = src.find("{", m.start())
    depth = 0
    j = i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = src[i:j]
    return re.findall(r"register\(\s*(\w+)\s*\(\s*\)\s*\)", body)


def default_enabled(src: str) -> set[str]:
    m = re.search(r"defaultEnabledTools:\s*Set<String>\s*=\s*\[([\s\S]*?)\]", src)
    if not m:
        return set()
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def api_name(name: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", name)
    if not safe:
        safe = "tool"
    if safe[0].isdigit():
        safe = "t_" + safe
    return safe


def main() -> int:
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--src", default=str(root / "Sources" / "Xosvi"))
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    src_dir = Path(args.src)
    if not src_dir.exists():
        print(f"src not found: {src_dir}", file=sys.stderr)
        return 2

    files: dict[Path, str] = {}
    for f in sorted(src_dir.glob("*.swift")):
        files[f] = strip_comments(f.read_text(encoding="utf-8", errors="ignore"))

    # class name -> (file, definition block, tool name)
    class_defs: dict[str, tuple[Path, str, str | None]] = {}
    defs: list[tuple[Path, str, str | None, str]] = []
    for f, src in files.items():
        for m in re.finditer(r"(?:final\s+)?class\s+(\w+)\s*:\s*MCPTool\b", src):
            cname = m.group(1)
            tail = src[m.end(): m.end() + 20000]
            blocks = list(find_definition_blocks(tail))
            if not blocks:
                continue
            block = blocks[0]
            nm = declared_name(block)
            class_defs[cname] = (f, block, nm)
            defs.append((f, block, nm, cname))

    core = files.get(src_dir / "MCPCore.swift", "")
    reg_classes = registered_classes(core)
    registered = []
    missing_class = []
    for c in reg_classes:
        if c in class_defs:
            nm = class_defs[c][2]
            if nm:
                registered.append(nm)
        else:
            missing_class.append(c)
    registered_set = set(registered)

    errors: list[str] = []
    warnings: list[str] = []

    # 1) 重复工具名
    seen: dict[str, str] = {}
    for f, block, nm, cname in defs:
        if not nm:
            continue
        if nm in seen:
            errors.append(f"duplicate tool name '{nm}' in {f.name}:{cname} (also declared elsewhere)")
        seen.setdefault(nm, f.name)

    # 2) apiName 碰撞
    api_seen: dict[str, str] = {}
    for nm in sorted(seen):
        a = api_name(nm)
        if a in api_seen and api_seen[a] != nm:
            errors.append(f"apiName collision: '{nm}' and '{api_seen[a]}' both sanitise to '{a}'")
        api_seen[a] = nm

    # 3) 注册类缺失 / 注册工具无定义
    for c in missing_class:
        errors.append(f"register({c}()) but class definition not found")

    # 4) 描述里的裸点分名（只查已注册工具）
    dotted = re.compile(r"\b[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]+)+\b")
    for f, block, nm, cname in defs:
        if nm not in registered_set:
            continue
        summary = string_arg(block, "summary") or ""
        texts = [summary]
        # parameters / returns / prerequisites 里的说明也算描述
        for key in ("returns", "prerequisites"):
            for m in re.finditer(rf"\b{key}\s*:\s*\[([\s\S]*?)\]", block):
                texts.append(m.group(1))
        for m in re.finditer(r"\bparameters\s*:\s*\[([\s\S]*?)\]", block):
            texts.append(m.group(1))
            break
        for tok in dotted.findall("\n".join(texts)):
            if tok in ALLOW_TOKENS or tok in registered_set:
                continue
            parts = tok.split(".")
            if parts[-1] in NOT_TOOL_SUFFIX or parts[0] in {"com", "org", "net", "io", "www"}:
                continue
            base = parts[0]
            if base in registered_set:
                errors.append(
                    f"{f.name}:{cname} summary references bare dotted name '{tok}'; "
                    f"use `{base} command:{'.'.join(parts[1:])}` instead")
        if not summary.strip():
            errors.append(f"{f.name}:{cname} has empty summary")

    # 5) 描述格式（P1）
    for f, block, nm, cname in defs:
        if nm not in registered_set:
            continue
        s = (string_arg(block, "summary") or "").lower()
        missing = [k for k in ("use for", "don't use for", "example") if k not in s]
        if missing:
            warnings.append(f"{f.name}:{cname} ({nm}) summary missing: {', '.join(missing)}")

    # 6) 默认启用（P1）
    enabled = default_enabled(core)
    for nm in sorted(registered_set - enabled):
        warnings.append(f"registered but not in defaultEnabledTools: {nm}")

    if not args.quiet:
        print(f"scanned {len(files)} files, {len(defs)} ToolDefinition, "
              f"{len(registered_set)} registered")
        if errors:
            print("\nERRORS:")
            for e in errors:
                print("  -", e)
        if warnings:
            print(f"\nWARNINGS ({len(warnings)}):")
            for w in warnings[:80]:
                print("  -", w)
            if len(warnings) > 80:
                print(f"  ... {len(warnings) - 80} more")
        if not errors and not warnings:
            print("OK: no issues")

    if errors:
        return 1
    if args.strict and warnings:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
