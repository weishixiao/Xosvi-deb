#!/usr/bin/env python3
"""Registry / contract invariants that must hold on every commit.

Run: python3 tests/test_registry_contract.py
No third-party deps; mirrors the checks in scripts/ but asserts cross-file invariants
(snapshot freshness, variant/param consistency) that the standalone scripts do not.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import lint_tool_descriptions as L  # noqa: E402

SRC = ROOT / "Sources" / "Xosvi"


def load():
    files = {f: L.strip_comments(f.read_text(encoding="utf-8", errors="ignore"))
             for f in sorted(SRC.glob("*.swift"))}
    classes = {}
    for f, text in files.items():
        for m in re.finditer(r"(?:final\s+)?class\s+(\w+)\s*:\s*MCPTool\b", text):
            blocks = list(L.find_definition_blocks(text[m.end(): m.end() + 20000]))
            if blocks:
                classes[m.group(1)] = (f, blocks[0], L.declared_name(blocks[0]))
    core = files.get(SRC / "MCPCore.swift", "")
    registered = [classes[c] for c in L.registered_classes(core) if c in classes]
    return files, classes, registered


def main() -> int:
    files, classes, registered = load()
    names = [r[2] for r in registered if r[2]]
    assert len(names) >= 40, f"unexpectedly few registered tools: {len(names)}"
    assert len(names) == len(set(names)), "duplicate tool names in registry"

    by_name = {r[2]: r for r in registered if r[2]}
    for required in ("app", "inject", "control", "db", "file", "package", "system.overview", "tools.audit"):
        assert required in by_name, f"core tool missing from registry: {required}"

    # app / inject 的子命令契约必须与 switch 分支同名
    for tool in ("app", "inject"):
        block = by_name[tool][1]
        vm = re.search(r"variants\s*:\s*\[([\s\S]*?)\n\s*\]", block)
        assert vm, f"{tool}: variants block not found"
        variants = re.findall(r'\.init\("([^"]+)"', vm.group(1))
        assert len(variants) >= 15, f"{tool}: too few variants ({len(variants)})"
        assert len(variants) == len(set(variants)), f"{tool}: duplicate variant"

    # 每个 variant 的必填参数必须是真实参数（只看 paramSpecs 块）
    for tool in ("app", "inject"):
        block = by_name[tool][1]
        pm = re.search(r"paramSpecs\s*:\s*\[([\s\S]*?)\n\s*\],", block)
        assert pm, f"{tool}: paramSpecs block not found"
        param_names = set(re.findall(r'\.\w\("([a-zA-Z0-9_]+)"', pm.group(1)))
        vm = re.search(r"variants\s*:\s*\[([\s\S]*?)\n\s*\]", block)
        for chunk in re.findall(r"\.init\(\s*\"[^\"]+\"([\s\S]*?)\)\s*,", vm.group(1)):
            for req in re.findall(r'requires(?:Any)?\s*:\s*\[([^\]]*)\]', chunk):
                for p in re.findall(r'"([^"]+)"', req):
                    assert p in param_names, f"{tool}: variant requires unknown param {p}"

    # snapshot 必须与源码一致
    with tempfile.TemporaryDirectory() as td:
        out = Path(td) / "registry.json"
        subprocess.run([sys.executable, str(SCRIPTS / "dump_registry.py"),
                        "--src", str(SRC), "--out", str(out)],
                       check=True, capture_output=True, text=True)
        fresh = out.read_text(encoding="utf-8")
    snapshot_path = ROOT / "docs" / "registry.snapshot.json"
    assert snapshot_path.exists(), "docs/registry.snapshot.json missing"
    assert snapshot_path.read_text(encoding="utf-8") == fresh, (
        "registry snapshot is stale; run: python3 scripts/dump_registry.py --out docs/registry.snapshot.json")

    print(f"OK: {len(names)} registered tools, snapshot up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
