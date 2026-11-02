# Gateway 接入文档（D1a/b/c）

> 让 Mac / 局域网内的 MCP 客户端把本机当作远程工具服务器。

## 1. 启动（手机侧）

```
gateway command:start            # 默认 127.0.0.1:8765
gateway command:start bind_lan:true port:8765   # 允许局域网（不可信网络勿开）
gateway command:status           # 端口 / token / 连接数 / LAN 告警
```

返回 `token`（全权）、`read_token`（只读）与 6 位 `pairing_code`。

## 2. 配对（客户端，二选一）

```bash
# A. POST /pair
curl -X POST http://<iphone-ip>:8765/pair -d '{"code":"123456"}'
# → {"token": "...", "read_token": "..."}

# B. 或直接用 gateway command:status 显示的 token
```

## 3. 调用

| 通道 | 用法 |
|---|---|
| HTTP | `POST /` + `Authorization: Bearer <token>`，body 为 JSON-RPC |
| SSE | `GET /sse`（带 Bearer）→ 收到 `endpoint` 事件；请求仍经 `POST /` 收发 |
| WebSocket | `GET /ws`（带 Bearer）→ 握手后双向 JSON-RPC 文本帧 |

只读令牌：只能调用显式标注 `readOnly` 的工具，写工具返回 `-32003`。

## 4. stdio 宿主（Claude Desktop / Cursor）

```bash
python3 tools/mcp_bridge_stdio.py --host <iphone-ip> --port 8765 --code <pairing_code>
```

宿主配置里把 command 指向该脚本即可；脚本自动配对并逐行转发。

## 5. 断线重连与隔离

- 每个连接独立处理、工具执行在连接上下文内串行：一个慢请求不会阻塞其它连接。
- 连接断开后 token 不失效；`gateway command:rotate` 吊销重发。
- 连接级 inode/backlog 由 accept loop 回收，异常帧直接断连（WS close 帧）。

## 6. 安全清单

- 默认只绑 127.0.0.1；`bind_lan:true` 会返回显式告警。
- 令牌只经 /pair 一次性下发；丢失即 `rotate`。
- 对外暴露的工具仍是白名单 + 权限体系，不会绕过 App 内策略。
