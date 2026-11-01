#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""L3 设备驱动：向 Xosvi 的本地 HTTP MCP 服务发 JSON-RPC 并断言。

用法：
  python3 tests/device/runner.py --case tests/device/cases/smoke_core.json
  python3 tests/device/runner.py --host 127.0.0.1 --port 8790 --token <token> --case ...
  python3 tests/device/runner.py --case smoke_injection.json --var BUNDLE_ID=com.xingxiao.discover

用例格式（JSON）：
{
  "name": "smoke_core",
  "cases": [
    {"id": "ping", "method": "ping", "expect": {"result": {}}},
    {"id": "list", "method": "tools/list", "expect": {"result.tools": {"min_len": 20}}},
    {"id": "call", "method": "tools/call",
     "params": {"name": "device", "arguments": {"command": "info"}},
     "expect": {"result.content.0.text": {"contains": "\"ok\""}}}
  ]
}

expect 支持：
  - 精确值（字符串/数字/布尔）
  - {"contains": "..."} / {"not_contains": "..."}
  - {"min_len": N} / {"exists": true}
  - 点号路径读取嵌套；数组下标用数字（如 result.content.0.text）
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def parse_args(argv):
    p = argparse.ArgumentParser(description="Xosvi device-side JSON-RPC runner")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8790)
    p.add_argument("--token", default="")
    p.add_argument("--case", default="tests/device/cases/smoke_core.json")
    p.add_argument("--var", action="append", default=[], help="模板变量 K=V，可重复")
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    return p.parse_args(argv)


def resolve_var(value, variables):
    if not isinstance(value, str):
        return value
    for k, v in variables.items():
        value = value.replace("${" + k + "}", v)
    return value


def deep_get(obj, path):
    cur = obj
    for part in path.split("."):
        if isinstance(cur, dict):
            cur = cur.get(part)
        elif isinstance(cur, list):
            try:
                cur = cur[int(part)]
            except (ValueError, IndexError):
                return None
        else:
            return None
    return cur


def check(expect, actual):
    """返回 (passed, detail)"""
    if isinstance(expect, dict) and len(expect) == 1:
        key, val = next(iter(expect.items()))
        if key == "contains":
            ok = isinstance(actual, str) and val in actual
            return ok, f"contains {val!r} -> {'yes' if ok else 'no'}"
        if key == "not_contains":
            ok = not (isinstance(actual, str) and val in actual)
            return ok, f"not_contains {val!r} -> {'yes' if ok else 'no'}"
        if key == "min_len":
            n = len(actual) if actual is not None else 0
            return n >= val, f"len={n} >= {val}"
        if key == "exists":
            return (actual is not None) == bool(val), f"exists={actual is not None}"
    return actual == expect, f"expected {expect!r}, got {actual!r}"


def call(host, port, token, payload, timeout):
    url = f"http://{host}:{port}/"
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", "replace")
    return json.loads(body) if body.strip() else {}


def main(argv=None) -> int:
    args = parse_args(argv)
    variables = {}
    for kv in args.var:
        if "=" in kv:
            k, v = kv.split("=", 1)
            variables[k] = v

    case_path = Path(args.case)
    if not case_path.is_absolute():
        case_path = ROOT / case_path
    if not case_path.exists():
        print(f"[FATAL] 用例文件不存在: {case_path}")
        return 2

    spec = json.loads(case_path.read_text(encoding="utf-8"))
    cases = spec.get("cases", [])
    results = []
    req_id = 1

    for case in cases:
        cid = case.get("id", f"case{req_id}")
        payload = {"jsonrpc": "2.0", "id": req_id, "method": case["method"]}
        params = case.get("params")
        if params:
            payload["params"] = json.loads(resolve_var(json.dumps(params), variables))
        req_id += 1

        try:
            resp = call(args.host, args.port, args.token, payload, args.timeout)
        except urllib.error.URLError as e:
            results.append({"id": cid, "passed": False, "detail": f"transport: {e}"})
            continue
        except Exception as e:  # noqa: BLE001
            results.append({"id": cid, "passed": False, "detail": f"error: {e}"})
            continue

        expect = case.get("expect", {})
        if "error" in resp and "error" not in expect:
            results.append({"id": cid, "passed": False, "detail": f"rpc error: {resp['error']}"})
            continue

        ok = True
        details = []
        for path, want in expect.items():
            actual = deep_get(resp, path)
            passed, detail = check(want, actual)
            ok = ok and passed
            details.append(f"{path}: {detail}")
        results.append({"id": cid, "passed": ok, "detail": "; ".join(details)})

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    else:
        print(f"case file: {case_path.name}  ({len(results)} cases)")
        for r in results:
            print(f"{'PASS' if r['passed'] else 'FAIL'}  {r['id']:24} {r['detail'][:110]}")

    failed = [r for r in results if not r["passed"]]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
