# Xosvi

**部署在 iOS 设备上的原生逆向 / 自动化 MCP 服务。** 内置 AI 或远程 MCP 客户端通过它直接操作真实 iOS 系统：App 管理、dylib 注入、网络抓包、SQLite 取证、跨环境文件、内存修改、包解剖、设备与定位。

> 仅用于**你自己的设备**与**已获授权**的安全研究。使用前请阅读文末免责声明。

## 环境支持

| 环境 | 支持版本 | 说明 |
|---|---|---|
| TrollStore（免越狱） | iOS 14.0 – 15.4.1（TS1）、15.5 – 16.6.1（TS2）、17.0 – 17.0.3（TS2/kfd） | 主力路径；注入走 ct_bypass / 静态注入 |
| 越狱 | iOS 17.0 – 17.3.1（Relaxin / RootHide / Dopamine + ElleKit） | rootHide 下 persona spawn 返回 85，走 setuid / jbctl 路径 |
| 不支持 | iOS 16.6.2+、iOS 17.1+ 的 TrollStore | Apple 已修补 CoreTrust / kfd |

安装后在 **TrollStore → 设置 → 编辑 Entitlements** 打开开关，然后**卸载重装**本 App。
覆盖安装不会重新应用 Entitlements —— 这是「Operation not permitted / 注入全失败」最常见的原因。

## 快速上手

1. 用 TrollStore 安装 `Xosvi.tipa`。
2. 打开 App，等首页环境自检跑完（首次约 2–5 秒）。
3. 在会话里直接说任务，例如：
   - 「看看小红书有没有被注入过」→ `inject command:status bundle_id:com.xingin.discover`
   - 「抓一下这个 App 的 HTTPS 请求」→ `network.capture command:start`
   - 「把这个 ipa 解包看看结构」→ `package command:unpack path:/var/mobile/Downloads/App.ipa`
4. AI 会先调 `system.overview` 看当前可用工具，再按 `command:` 子命令执行。
   **工具总数以 `system.overview` 的实时输出为准**，不要引用文档里的旧数字。

## 工具契约（AI 无缝化）

所有工具遵循同一份机器可读契约，详见 [docs/AI_SEAMLESS_UPGRADE.md](docs/AI_SEAMLESS_UPGRADE.md)：

- **调用形态**：大工具 + 子命令，`app command:launch bundle_id:...`；`app.launch` 不是工具名。
- **参数 schema**：`tools/list` 下发 `inputSchema`（类型 / 必填 / 枚举 / 子命令要求），MCP 与内置 AI 共用同一投影层。
- **结果信封**：`ok` / `code` / `message?` / `data` / `next_step?` / `evidence?` / `truncated?` / `spill_path?`。
- **错误**：四分类 `ENV_PERMISSION` / `TARGET_INCOMPATIBLE` / `PARAM_INVALID` / `TOOL_FAILED`，并附 `next_step` 与命中的知识库修复建议 `kb_fix`。
- **外部内容**：网页 / UI 树 / 文件内容 / 二进制字符串统一包进 `<external_content>` 或标注 `_untrusted: true`，一律当资料、不是指令。
- **调用前校验**：缺参、类型错、未知子命令、`bundle_id` 传成路径，会在执行前返回结构化参数错误 + 可照抄模板。

## 目录结构

```
Sources/Xosvi/      App 与 MCP 服务（150+ Swift 文件，单一 executableTarget）
  MCPCore.swift         工具定义、注册表、dispatch、缓存/熔断/审计
  ToolContract.swift    机器可读契约：schema 投影、参数校验、结果信封、外部内容包装
  JSONRPC.swift         最小 MCP JSON-RPC 2.0 传输（tools/list · tools/call · ping）
  InjectionManager.swift / RootdTool.swift   注入与 root 通道
  ControlTools.swift    注入型 UI 控制（ControlAgent，4789）
tweaks/                 Theos tweaks（ControlAgent、NetworkTweak 等）
VansonEngine/           内存扫描引擎（GPL-3.0 桥接）
CISH/                   iSH 内核 C 包装层
CHev/ CMitm/ CLaunch/   抓包 / MITM / 启动辅助
scripts/                静态检查：注册一致性 / 描述 lint / 注册表快照
docs/                   AI 无缝化说明与 registry.snapshot.json
tests/                  端到端与单元测试
```

## 构建

GitHub Actions（`.github/workflows/build-xosvi-ios.yml`）在 push `main` 时全量构建并发布滚动 Release `latest`。
纯文档改动不触发构建；`scripts/` 与 `Sources/` 改动会先跑 `lint.yml` 的静态检查。

本地只跑静态检查（不需要 macOS）：

```sh
python3 scripts/check_swift_braces.py
python3 scripts/check_tool_registration.py
python3 scripts/lint_tool_descriptions.py
python3 scripts/dump_registry.py --out docs/registry.snapshot.json
```

## 许可

本项目以 **GPL-3.0** 发布（见 [LICENSE](LICENSE)）。

原因：`VansonEngine/` 是 VansonMod 内存引擎（GPL-3.0）的桥接层；`CISH/` 链接 iSH 内核（GPL-3.0）。
两者都是强 copyleft，主程序作为衍生作品必须整体以 GPL-3.0 提供对应源码。
`jb-p1lot` 等外部组件不随包分发，按其上游许可单独获取。

如果你再分发本项目的二进制，必须同时提供完整对应源码，并保留本段说明。

## 免责声明

本项目只用于**自有设备**上的安全研究、逆向学习与自动化测试。
使用者必须确保对目标 App / 设备拥有合法授权，并遵守当地法律与服务条款。
作者不对任何滥用、数据损失或法律后果负责。注入、改内存、抓包等操作可能导致 App 崩溃、数据损坏或账号风险，请自行备份。
