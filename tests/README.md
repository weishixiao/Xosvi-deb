# tests — 三层测试体系

> 不引入 XCTest：仓库是 iOS App 工程，CI 跑在 ubuntu/macOS 上且设备侧无法自动安装测试宿主。
> 用「静态契约 + 设备内自检 + 外部驱动」三层覆盖，全部是纯标准库 Python + 一个 Swift 自检工具。

## L1 契约层（CI 必跑，无需设备）

```bash
python3 tests/contract/run_all.py
```

包含：
- `scripts/check_tool_registration.py`：`register(XxxTool())` ↔ `class XxxTool` 一致性、工具名唯一
- `scripts/lint_tool_descriptions.py --fail-on-refs`：描述中的裸点分引用必须命中注册表
- `scripts/dump_registry.py --check docs/registry.snapshot.json`：注册表快照 diff

破坏性变更（删工具 / 改必填参数 / 改子命令）必须运行 `dump_registry.py --out` 更新快照并提交。

## L2 设备内自检

`debug.selftest`（Swift 工具，DEBUG 或设置页开关启用）在本机执行只读自检：
文件系统、SQLite、注入二进制、iSH 桥接、JSON 序列化、缓存。它**不修改任何状态**，
RunScope 用例使用独立 token，不干扰当前会话。

## L3 外部驱动（真机/局域网）

```bash
python3 tests/device/runner.py --host 127.0.0.1 --port 8790 --token <token> \
    --case tests/device/cases/smoke_core.json
```

用例是 JSON：`method` + `params` + `expect`（点号路径 + `contains` / `min_len` / `exists`）。
支持 `--var K=V` 注入模板变量（如 `BUNDLE_ID`）。

| 用例 | 覆盖 |
|---|---|
| `smoke_core.json` | initialize / ping / tools.list / device.info / unknownTool 结构化错误 |
| `smoke_injection.json` | inject status/list/inspect + 缺参PARAM_INVALID 契约 |
| `smoke_ish.json` | ish.doctor / shell.exec 执行 / 外部内容包装 |

## 压测

```bash
python3 scripts/stress_mcp.py --host 127.0.0.1 --port 8790 --sessions 8 --seconds 60
```

统计成功率 / 延迟分位 / 错误码分布，用于验证 ToolRegistry 并发收口（不崩溃、无 SIGSEGV）。

## 加用例

1. 在 `tests/device/cases/` 新增 JSON；
2. 工具名必须是注册表真实名（`python3 scripts/dump_registry.py | head`）；
3. 断言优先用 `contains`（返回文案会随版本微调），不要断言整段 JSON。
