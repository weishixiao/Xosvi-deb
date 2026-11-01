#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Mac 侧 stdio ↔ Xosvi Gateway 桥（纯标准库）。

用途：把 MCP 客户端（Claude Desktop / Cursor 等只支持 stdio 的宿主）接到 iPhone 上的 Xosvi。

用法：
  python3 tools/mcp_bridge_stdio.py --host 192.168.1.23 --port 8765 --code 123456
  # 或已有 token：
  python3 tools/mcp_bridge_stdio.py --host 192.168.1.23 --port 8765 --token <token>

行为：
  - 启动时 POST /pair（有 code 时）拿 token；
  - 读 stdin 的每行 JSON（JSON-RPC），POST / 到网关；
  - 把响应写回 stdout（每行一条）；
  - 通知（notifications/*）网关返回空体时不输出。
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
import urllib.error


def post(base, path, payload, token, timeout=120):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(base + path, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        body = e.read()
    except urllib.error.URLError as e:
        return {"jsonrpc": "2.0", "error": {"code": -32000, "message": f"gateway unreachable: {e}"}, "id": None}
    if not body:
        return {}
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        return {"jsonrpc": "2.0", "error": {"code": -32700, "message": "bad gateway response"}, "id": None}


def main() -> int:
    p = argparse.ArgumentParser(description="stdio ↔ Xosvi Gateway bridge")
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--code", default="")
    p.add_argument("--token", default="")
    p.add_argument("--timeout", type=float, default=120)
    args = p.parse_args()
    base = f"http://{args.host}:{args.port}"

    token = args.token
    if not token:
        if not args.code:
            print("need --code or --token", file=sys.stderr)
            return 2
        r = post(base, "/pair", {"code": args.code}, "", 20)
        token = r.get("token", "")
        if not token:
            print(f"pair failed: {r}", file=sys.stderr)
            return 1
        print(f"paired, token acquired ({len(token)} chars)", file=sys.stderr)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            out = {"jsonrpc": "2.0", "error": {"code": -32700, "message": "parse error"}, "id": None}
        else:
            out = post(base, "/", payload, token, args.timeout)
        if out:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
