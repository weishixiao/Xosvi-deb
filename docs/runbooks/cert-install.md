# 证书安装 Runbook（R3 / PR-C3）

> 目标：让 `vpn.capture` 的 MITM 根证书被系统信任，`verify` 返回 `TRUSTED`。
> 证书只在设备本地生成，不上传任何地方。

## 1. 生成

```
vpn.capture command:cert
```

产物：`Workspace/certs/XosviCA.mobileconfig`（根 CA + 私钥留在本机）。

## 2. 安装描述文件（两条路径）

**A. Safari（推荐）**

```
vpn.capture command:serve_profile
```

返回 `http://127.0.0.1:18080/XosviCA.mobileconfig` → 用 Safari 打开 → 允许下载 → 设置 → 已下载描述文件 → 安装。

**B. 文件 App**

直接把 `Workspace/certs/XosviCA.mobileconfig` 用文件 App 打开安装。

## 3. 开启完全信任（最容易漏）

设置 → 通用 → 关于本机 → 证书信任设置 → 打开 **Xosvi MITM CA** 的完全信任。

> 只安装不信任 = TLS 必然失败，`verify` 会返回 `NOT_TRUSTED`。

## 4. 验证

```
vpn.capture command:start      # VPN 失败会自动降级为本地代理，mode=fallen_back
vpn.capture command:verify     # 期望 TRUSTED
```

| 返回 | 含义 | 处置 |
|---|---|---|
| `TRUSTED` | 拦截链路可用 | 正常抓包 |
| `NOT_TRUSTED` | 未安装/未信任 | 回步骤 2–3 |
| `PROXY_DOWN` | 代理没起 | 先 `command:start` 或 `command:local_start` |
| `mode: fallen_back` | VPN 未起来，已降级 | 按 `next_step` 设 WiFi 代理 127.0.0.1:18180，或修复 VPN |

## 5. 卸载/清理

设置 → 通用 → 关于本机 → 证书信任设置 → 关闭信任；设置 → 通用 → VPN与设备管理 → 删除描述文件。
`Workspace/certs/` 可整体删除（下次 `cert` 会重新生成）。

## 已知限制

- QUIC/HTTP3 不解密；TLS pinning 的 App 抓不到明文。
- 系统代理与 VPN 同开可能互斥：`vpn.capture command:status` 的 `warnings` 会提示 `proxy_conflict`。
- 本机自签证书仅对信任它的进程有效；不要外传 `ca_key.pem`。
