# 注入链路冒烟 Runbook（R2 / PR-H4）

> 目标：10 步内确认「注入 → 启动 → 连接 → UI 控制 → 截图」整条链路可用。
> 前提：TrollStore 已开启「编辑 Entitlements」且 Xosvi 为卸载后重装。
> 全程对**测试用 App**（建议系统「设置」或自建 Demo）执行，不要拿主力 App 试。

| 步 | 动作 | 工具调用 | 期望 |
|---|---|---|---|
| 1 | 环境自检 | `device` command:info | `environment` 与 `jb` 字段正常 |
| 2 | 检查注入二进制 | `diagnose` command:toolchain | 「签名/可执行」两项 PASS |
| 3 | 选目标 | `app` command:status bundle_id:<BUNDLE_ID> | `installed: true` |
| 4 | 判加密 | `app` command:encrypt_info bundle_id:<BUNDLE_ID> | `cryptid=0`；为 1 先砸壳 |
| 5 | 注入 | `inject` command:enable bundle_id:<BUNDLE_ID> | `injected: true`，返回备份路径 |
| 6 | 启动 | `app` command:launch bundle_id:<BUNDLE_ID> | 进程起来，等 2–3 s |
| 7 | 验证注入 | `inject` command:status bundle_id:<BUNDLE_ID> | `injected: true` |
| 8 | 控制通道 | `control` command:status | `connected: true`（4789） |
| 9 | 取 UI 树 | `control` command:ui_tree | 返回节点数 > 0 |
| 10 | 截图 | `control` command:screenshot | 返回图片路径，文件存在且 > 10 KB |

## 失败分支

| 现象 | 判定 | 处置 |
|---|---|---|
| 步骤 5 `ENV_PERMISSION` | Entitlements 未生效 | 卸载重装 Xosvi，重开 TrollStore「编辑 Entitlements」 |
| 步骤 5 `TARGET_INCOMPATIBLE` | 加密/架构不符 | 先 `app` command:decrypt → command:replace_decrypted |
| 步骤 6 闪退 | 注入不兼容 | `inject` command:restore 回滚，再 `diagnose` command:crash |
| 步骤 8 `connected:false` | ControlAgent 未注入/未重启 | `control` command:inject → `app` command:restart |
| 步骤 10 路径不存在 | 截图失败 | 回到步骤 9 确认 UI 树可用，再重试一次 |

## 留档

每次执行记录：日期 / 设备与 iOS / 目标 bundle_id / 10 步结果 / 失败步骤与证据（错误原文 + 绝对路径）。
