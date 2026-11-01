# Xosvi

> 部署在 iOS 设备上的原生 MCP 工具服务 + 内置 AI 对话。让 AI 直接操作真实 iOS 系统：
> App 管理、dylib 注入、网络抓包、SQLite 取证、跨环境文件、内存修改、包解剖、设备/定位。

## 定位

Xosvi 是一个装在 iPhone 上的**原生工具宿主**：把 iOS 上原本要手工敲命令的逆向/取证/自动化动作，
收敛成一组带结构化元数据（参数、前置条件、返回值、注解、缓存策略、示例）的工具，供内置 AI 或外部客户端调用。
设计取向是"少而厚"：**大工具 + 子命令**（`app`、`inject`、`control`、`device` 等），而不是几百个碎片化小工具；
工具总数不写死，以运行时注册表为准。

- 双 Shell 环境：**iOS 原生**（真实文件系统、真实进程）+ **iSH Alpine**（Linux 工具链）
- 面向 **TrollStore / 越狱**环境（需要 no-sandbox 与相关 entitlement），无法上架 App Store
- AI 使用工具的完整契约见 `AGENTS.md`（入口）与 `RULES.md`（操作契约）

## 环境要求

| 环境 | 支持版本 | 备注 |
|---|---|---|
| TrollStore | iOS 14.0–15.4.1 / 15.5–16.6.1 / 17.0–17.0.3 | 运行时注入（ct_bypass）上限 iOS 17.0 |
| 越狱（rootHide / Relaxin / Dopamine 等） | iOS 15.0–17.3.x（实测 17.1 + Relaxin 可用） | 走越狱提权路径，不需要 persona spawn；`root` 工具需装 rootd LaunchDaemon |
| 不支持 | 无越狱且超出 TrollStore 覆盖范围的版本 | 例如 iOS 17.1 未越狱：CoreTrust/kfd 已修补，注入类工具不可用 |

> 同一份矩阵由 `system.overview` 的 `ios_version_support` 字段实时返回，安装前可用它复核当前设备。

## 安装与权限（关键：权限只在安装时写入）

1. 用 TrollStore 安装本 App；
2. **在 TrollStore 设置里开启「编辑 Entitlements」**（不开启则注入、容器写入、`task_for_pid` 全部失败）；
3. **卸载后重新安装 Xosvi**——覆盖安装**不会**重新应用 entitlement，这是最常见的失败原因；
4. 打开 App → 设备页自检应全绿（task_for_pid / 容器读写 / 注入二进制 / amfid 推断）；
5. 若仍报 `ENV_PERMISSION` / `Operation not permitted`，回到第 2 步核对，而不是反复重试工具。

`Resources/bin/` 下的 helper（ldid、insert_dylib、ct_bypass、opainject 等）需要 setuid root 位，
同样由 TrollStore 安装时写入；`diagnose command:toolchain repair:true` 可做签名自检与重签。

## 快速上手

```
# 0) 看当前设备与工具目录（实时口径）
device command:info
system.overview

# 1) 注入并控制任意 App（先注入，再操作）
inject command:enable bundle_id:com.example.app
control command:inject bundle_id:com.example.app
control command:status
control command:screenshot
control command:ui_tree

# 2) 抓包
network.capture action:start bundle_id:com.example.app   # NSURLSession 栈
vpn.capture command:cert                                  # 生成 CA 描述文件（首次）
vpn.capture command:start                                 # 系统级 MITM（失败可退 local_start）
vpn.capture command:logs

# 3) 取证
db command:list path:/var/mobile/Containers/Data/Application/<UUID>/Documents/x.db
db command:query path:/var/mobile/.../x.db sql:"select * from t limit 20"
file command:inspect path:/var/mobile/.../Payload/App.app/App

# 4) 排障
diagnose command:startup bundle_id:com.example.app
diagnose command:lasttool        # 上次崩溃前最后执行的工具
diagnose command:rootchain       # 提权链路（spawnRoot / setuid / entitlement）
tools.audit                      # 注册表一致性：描述里引用的幽灵工具名
```

> 子命令一律用 `command:` 传（抓包工具用 `action:`）；`app` 的 `launch`、`inject` 的 `enable` 等
> 都是参数值，不是独立工具名。完整可调用名清单见 `AGENTS.md`。

### 接入方式

| 通道 | 入口 | 说明 |
|---|---|---|
| 内置 AI 对话 | App 内 Chat | 进程内直接 `ToolRegistry.dispatch`，享受缓存/熔断/信封/审计 |
| 本地 HTTP（REST） | `server command:start`（默认 8765） | `/health`、`/tools`、`/api/{tool_name}?param=value` |
| 远程终端 | 设置 → 远程终端（默认 8790） | Bearer token；危险工具默认拒绝，需显式开启"允许危险工具" |
| MCP JSON-RPC | `Sources/Xosvi/JSONRPC.swift` | 实现 `initialize` / `ping` / `tools/list`（200/页，游标分页）/ `tools/call`；当前为进程内处理器，协议版本 `2024-11-05` |

> 远程通道（8765 / 8790）直接调用工具实现，**不经过** `dispatch` 的缓存、熔断与信封，排障时注意区分。

## 目录结构

```
Xosvi/
├── Sources/
│   ├── Xosvi/        # App 主体：MCP 内核、工具注册表、dispatch、全部工具实现、SwiftUI 界面
│   ├── ISHBridge/        # iSH Alpine 沙盒桥接（移植自 Kelivo/OpenMinis，见 Sandbox/NOTICE）
│   ├── MitmCore/         # MITM 代理 + SOCKS5（TLS 拦截、CA 管理）
│   ├── PythonCLI/        # 进程内 CPython 入口（dlopen，无子进程）
│   └── VpnTunnel/        # NEPacketTunnelProvider appex（vpn.capture 的 VPN 模式）
├── tweaks/               # 注入用 tweak 源码：ControlAgent / TLSHook / NetworkTweak / MemoryTweak / ProbeAgent ...
├── CCapstone/ CHev/ CISH/ CLZMA/ CLaunch/ CMitm/ CPyEmbed/   # 内嵌 C 能力（反汇编 / 提权 / iSH / LZMA / 启动 / MITM / Python）
├── VansonEngine/         # 内存引擎（移植自 VansonMod，GPL-3.0）
├── Sandbox/              # iSH rootfs 构建脚本、overlay、patch、NOTICE
├── Resources/            # bin/（ldid、insert_dylib、ct_bypass、opainject…）、tweaks/、图标
├── Support/              # Info.plist、entitlements（App / appex / bin）
├── tools/ tests/         # 辅助二进制源码（kfd、sqlite_wipe 等）与引擎测试
├── scripts/              # 构建与静态检查（build-ipa.sh、check_tool_registration.py、括号检查等）
├── vpnxcode/             # VPN appex 的 Xcode 工程与构建脚本
├── docs/                 # 架构说明与 runbook（本目录）
├── Package.swift         # SwiftPM 工程定义（iOS 15+）
├── AGENTS.md / RULES.md  # AI 入口与操作契约（版本 v2.0）
└── ISH_RUNTIME_NOTES.md  # iSH 环境实测约束
```

## 工具数口径

**工具数量不写死**：以 `system.overview` 返回的 `total_tools`（以及 `tools/list` 的分页结果）为准。
README 与文档只描述口径，不做静态承诺——历史上曾出现 37 / 162 等过期数字，均已废弃。

当前源码状态：`MCPCore` 的注册函数共 166 个 `ToolDefinition` 名字，其中 **49 个默认启用**（其余为未启用的历史工具）。以 `system.overview` 的 `total_tools` 实时值为准。
校验方式：

```
system.overview        # 看 total_tools
tools.audit            # 看 total_tools / verified 分布 / 幽灵引用
```

## 许可

**GNU GPL-3.0**。本程序链接/包含以下 GPL-3.0 衍生作品，整体以 GPL-3.0 分发：

- `VansonEngine/` —— 移植自 VansonMod v3.5.2（内存引擎），许可全文见 `VansonEngine/LICENSE`
- iSH 沙盒桥接层 —— 移植自 Cuplivo/OpenMinis 的 ISHKernel，署名与来源见 `Sandbox/NOTICE`

**源码提供义务**：以二进制形式分发本 App（IPA / deb / 重打包）时，必须同时提供**对应的完整源码**，
包括上述衍生作品及其修改、以及生成二进制的构建脚本（`scripts/`、`Sandbox/`、`vpnxcode/`），
并保留所有版权声明与许可文本；不得附加 GPL-3.0 之外的额外限制。

> 说明：仓库根目录目前未放置 `LICENSE` 文件，GPL-3.0 全文暂以 `VansonEngine/LICENSE` 为准（待补根目录副本）。

## 免责声明

本工具面向**安全研究与自有设备自动化**。使用者需自行确保对目标设备与目标 App 拥有合法操作权限，
并遵守当地法律与相关服务条款。作者不对因使用本工具造成的设备损坏、数据丢失、账号封禁或法律责任负责。
请勿用于侵犯他人隐私、绕过他人设备保护或任何未经授权的渗透行为。
