#!/usr/bin/env python3
"""Dump a deterministic snapshot of the tool registry (static analysis of Swift sources).

用途（H3 文档即代码）：
  * CI 生成 /tmp/registry.json 与 docs/registry.snapshot.json 对比；
  * 删工具、改子命令、改必填参数等破坏性变更会红灯，必须显式更新快照；
  * 便于回溯「AI 从哪个版本开始调不对了」。

Usage:
  python3 scripts/dump_registry.py [--src ...] [--out docs/registry.snapshot.json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import lint_tool_descriptions as L  # noqa: E402


def parse_param_specs(block: str) -> list[dict]:
    m = re.search(r"paramSpecs\s*:\s*\[([\s\S]*?)\n\s*\]", block)
    if not m:
        return []
    body = m.group(1)
    out = []
    for pm in re.finditer(r"\.([sibne])\s*\(\s*\"([a-zA-Z0-9_]+)\"\s*,([\s\S]*?)\)\s*,?\s*(?=\n\s*\.|\n\s*\]|\Z)", body):
        kind, name, rest = pm.group(1), pm.group(2), pm.group(3)
        required = bool(re.search(r"required\s*:\s*true", rest))
        example = re.search(r'example\s*:\s*"([^"]*)"', rest)
        values = []
        if kind == "e":
            vm = re.search(r"values\s*:\s*\[([\s\S]*?)\]", rest)
            if vm:
                values = re.findall(r'"([^"]+)"', vm.group(1))
        type_map = {"s": "string", "i": "integer", "b": "boolean", "e": "string", "n": "number"}
        item = {"name": name, "type": type_map.get(kind, "string"), "required": required}
        if values:
            item["enum"] = values
        if example:
            item["example"] = example.group(1)
        out.append(item)
    return out


def parse_variants(block: str) -> list[dict]:
    m = re.search(r"variants\s*:\s*\[([\s\S]*?)\n\s*\]", block)
    if not m:
        return []
    out = []
    for vm in re.finditer(r"\.init\(\s*\"([^\"]+)\"\s*,?([\s\S]*?)\)\s*,?\s*(?=\n\s*\.|\n\s*\]|\Z)", m.group(1)):
        cmd, rest = vm.group(1), vm.group(2)
        def arr(key):
            am = re.search(key + r"\s*:\s*\[([^\]]*)\]", rest)
            return re.findall(r'"([^"]+)"', am.group(1)) if am else []
        note = re.search(r'note\s*:\s*"([^"]*)"', rest)
        out.append({
            "command": cmd,
            "required": arr("requires"),
            "required_any": arr("requiresAny"),
            "accepts": arr("accepts"),
            **({"note": note.group(1)} if note else {}),
        })
    return out


def parse_annotations(contract_src: str) -> dict[str, dict]:
    m = re.search(r"safetyCatalog\s*:\s*\[String:\s*ToolAnnotations\]\s*=\s*\[([\s\S]*?)\n\s*\]", contract_src)
    if not m:
        return {}
    presets = {
        ".query": {"readOnly": True, "destructive": False, "idempotent": True, "openWorld": False},
        ".queryUnstable": {"readOnly": True, "destructive": False, "idempotent": False, "openWorld": False},
        ".write": {"readOnly": False, "destructive": False, "idempotent": False, "openWorld": False},
        ".writeIdempotent": {"readOnly": False, "destructive": False, "idempotent": True, "openWorld": False},
        ".destructive": {"readOnly": False, "destructive": True, "idempotent": False, "openWorld": False},
        ".networked": {"readOnly": False, "destructive": False, "idempotent": False, "openWorld": True},
        ".networkedWrite": {"readOnly": False, "destructive": True, "idempotent": False, "openWorld": True},
    }
    out = {}
    for line in m.group(1).splitlines():
        lm = re.match(r'\s*"([^"]+)"\s*:\s*(\.\w+)\s*,?', line)
        if lm and lm.group(2) in presets:
            out[lm.group(1)] = presets[lm.group(2)]
    return out


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=str(root / "Sources" / "Xosvi"))
    ap.add_argument("--out", default="")
    args = ap.parse_args()

    src = Path(args.src)
    if not src.exists():
        print(f"src not found: {src}", file=sys.stderr)
        return 2

    files = {f: L.strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
             for f in sorted(src.glob("*.swift"))}
    class_defs = {}
    for f, text in files.items():
        for m in re.finditer(r"(?:final\s+)?class\s+(\w+)\s*:\s*MCPTool\b", text):
            blocks = list(L.find_definition_blocks(text[m.end(): m.end() + 20000]))
            if not blocks:
                continue
            class_defs[m.group(1)] = (f, blocks[0], L.declared_name(blocks[0]))

    core = files.get(src / "MCPCore.swift", "")
    reg_classes = L.registered_classes(core)
    enabled = L.default_enabled(core)
    ann = parse_annotations(files.get(src / "ToolContract.swift", ""))

    tools = []
    for cname in reg_classes:
        if cname not in class_defs:
            continue
        f, block, name = class_defs[cname]
        if not name:
            continue
        summary = L.string_arg(block, "summary") or ""
        cat = re.search(r'category\s*:\s*"([^"]*)"', block)
        ver = re.search(r"verified\s*:\s*(true|false)", block)
        params = parse_param_specs(block)
        if not params:
            pm = re.search(r"parameters\s*:\s*\[([\s\S]*?)\n\s*\]", block)
            if pm:
                for k in re.findall(r'"([a-zA-Z0-9_]+)"\s*:', pm.group(1)):
                    params.append({"name": k, "type": "string", "required": False})
        env = {}
        for key, pat in [("requires_jailbreak", r"requiresJailbreak\s*:\s*true"),
                         ("requires_trollstore", r"requiresTrollStore\s*:\s*true"),
                         ("remote_only", r"remoteOnly\s*:\s*true")]:
            if re.search(pat, block):
                env[key] = True
        mi = re.search(r"minIOSMajor\s*:\s*(\d+)", block)
        ma = re.search(r"maxIOSMajor\s*:\s*(\d+)", block)
        if mi: env["min_ios_major"] = int(mi.group(1))
        if ma: env["max_ios_major"] = int(ma.group(1))
        tools.append({
            "name": name,
            "class": cname,
            "file": f.name,
            "category": cat.group(1) if cat else "misc",
            "verified": (ver.group(1) == "true") if ver else False,
            "default_enabled": name in enabled,
            "summary_sha256_8": hashlib.sha256(summary.encode("utf-8")).hexdigest()[:8],
            "params": params,
            "variants": parse_variants(block),
            "environment": env,
            "annotations": ann.get(name, {}),
        })

    tools.sort(key=lambda t: t["name"])
    snapshot = {
        "schema": 1,
        "generated_by": "scripts/dump_registry.py",
        "app_version": read_version(root),
        "tool_count": len(tools),
        "tools": tools,
    }
    text = json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out} ({len(tools)} tools)")
    else:
        sys.stdout.write(text)
    return 0


def read_version(root: Path) -> str:
    plist = root / "Support" / "Info.plist"
    if not plist.exists():
        return "unknown"
    m = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]+)</string>",
                  plist.read_text(encoding="utf-8", errors="ignore"))
    return m.group(1) if m else "unknown"


if __name__ == "__main__":
    raise SystemExit(main())
