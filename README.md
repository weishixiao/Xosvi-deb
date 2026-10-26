# Xosvi

**AI 驱动的 iOS 越狱 / TrollStore 实验与 QA 工作台。**
Swift + SwiftUI + SwiftPM，iOS 15+，内置 **50 个工具、200+ 子命令**，用一句自然语言就能驱动整条工具链。

```
你说：帮我看看这个 deb 里是什么
AI  ：解包 → 解析 Mach-O → 提符号 → 定位关键逻辑 → 给结论
```


## 1. 它解决什么问题

iOS 上做逆向 / 调试 / 自动化，通常要在「电脑 + SSH + 一堆工具」之间来回倒。Xosvi 把这些能力收进一个 App：

- **模型直连工具**：MCP 风格的工具注册表，模型看到的是工具 schema，不是预设脚本
- **双运行时**：能原生跑的就原生跑；需要完整 Linux 用户空间的走内置 iSH
- **无子进程也能干活**：越狱环境常把 `posix_spawn` 掐掉（见 §5），关键能力（解压 / 反汇编 / Python）已改为**进程内**实现
- **每一步可见**：工具调用、耗时、错误都作为消息卡片实时上屏

---

## 2. 能力总览

### 注入与逆向
`inject`（enable / disable / remove / restore / status / inspect / list / mem / static / verify / load_dylib / hook_apply / probe_inspect）· `rescue`（scan / recover_all / cleanup）· `binary.symbols` · `ipa.inspect` · `dylib.inspect`
注入失败自动回滚，`.bak_macho` 备份，注入后启动自检。

### 二进制分析
`macho`（Mach-O 结构 / 段 / 符号 / entitlements）· `disasm`（**进程内反汇编**，capstone）· `py`（**进程内 CPython**）· `file` · `strings`（原生过滤）

### App 管理
`app`（launch / stop / restart / status / stats / install / uninstall / duplicate / diagnose）· `app.decrypt`（内置砸壳：task_for_pid + vm_read → 重建镜像）· `app.entitlements / deps / cache_inspect / cache_clear`

### 文件与数据
`package`（deb/ipa **进程内解包**：ar + tar + gzip/lzma/xz，含 `selftest`）· `artifact` · `container` · `db`（原生 sqlite3）· `bind_app` · `save`

### 浏览器与网络
`browser`（navigate / screenshot / snapshot / text / click / type / fill_form / eval / wait）· `web.search` / `web.fetch` · `network.capture`（MITM）· `vpn` · `wifi`

### 设备与控制
`device`（info / probe / snapshot / fake / restore / keychain_wipe）· `location` · `control`（跨 App UI 树 / 点击 / 输入）· `automation` · `macro` · `cron`

### 构建与 CI
`github`（account_status / trigger_build / fetch_runs / download_artifact）· `build`（run / environment）· `tool.install` · `env.setup_re`

### AI 与记忆
多上游模型（OpenAI 兼容 / Anthropic Messages）· SSE 流式 · 推理强度 · `skills` · `knowledge` · `memory` · `assistant_memory` · `prompt.read_mode`

### 诊断
`diagnose`（startup / injection / **spawn** / rootchain）· `engine`（status / on / off / restart / **reset-rootfs** / probe）· `verify` · `audit` · `system.overview`

---

## 3. 架构

```
┌─────────────── SwiftUI 层 ───────────────┐
│  ChatView / SettingsView / Tools UI       │
└───────────────┬──────────────────────────┘
                │ 模型流式（SSE）
┌───────────────▼──────────────────────────┐
│ ConversationStore（会话 / 后台并发运行）   │
│  ├─ runLoop → tool_calls                  │
│  └─ BackgroundRunManager（并发会话隔离）   │
└───────────────┬──────────────────────────┘
                │ MCPTool.invoke(params)
┌───────────────▼──────────────────────────┐
│ ToolRegistry（50 个工具）                  │
└───┬───────────┬──────────────┬───────────┘
    │           │              │
 原生 Swift   进程内 C 库     iSH（Alpine，模拟 ARM64）
 MachOKit    CLZMA / CCapstone / CPyEmbed
```

### 关键 SwiftPM 目标

| 目标 | 作用 |
|---|---|
| `CISH` | iSH 内核 + fakefs 的 C 桥接，提供 Alpine 用户空间 |
| `CLZMA` | LZMA SDK + xz-embedded，**进程内** gzip/lzma/xz 解码 |
| `CCapstone` | capstone 5.0.3 静态库，**进程内**反汇编 |
| `CPyEmbed` | `dlopen` Python.framework，**进程内** CPython |
| `VansonEngine` | 内存扫描/读写/冻结引擎（GPL-3.0） |
| `CMitm` / `MitmCore` | OpenSSL 抓包内核 |
| `CHev` / `VpnTunnel` | hev-socks5 转发 + Network Extension |
| `CLaunch` | 提权 spawn 的 C 层 |

---

## 4. 会话级并发

一个会话在跑时，切到另一个会话直接发消息即可并行执行：

- 第二个会话由 `BackgroundRunManager` 分配**独立的 `ConversationStore` 实例**，拥有完整独立的运行状态（`isLoading`、网络 client、流式缓冲、纠正计数器）
- 后台实例不读也不写共享存储（`save()` 直接返回），跑完由主实例合并结果
- `TaskNotify` / `BackgroundKeepAlive` 改为**引用计数**，先结束的会话不会关掉另一个的后台保活

> 取舍：后台会话不做逐字流式，完成后一次性出现。

---

## 5. 进程内工具链（为什么必须有）

真机实测：在 rootHide / Relaxin 这类越狱下，App 容器内的**第三方二进制一律 `posix_spawn` → `ENOSYS(85)`**。
`diagnose spawn` 可以给出完整证据链：

```
python3   mach_o=true  code_signature=true  cryptid=0  team_id=(none)  adhoc=true  → errno 85
r2        mach_o=true  code_signature=true  cryptid=0  team_id=(none)  adhoc=true  → errno 85
system    /usr/bin/plutil                                                   → spawn ok
```

也就是说：**文件没坏、签名在、依赖齐全**，是越狱在隐藏上下文里拒绝执行。重装、重签、`chmod u+s` 都不会改变结果。

所以关键能力改为链进主二进制，运行在进程内：

| 能力 | 实现 | 工具 |
|---|---|---|
| gzip 解压 | zlib（**注意**：必须把完整 gzip 流交给 zlib，跳过 10 字节头再用 `wbits=31` 会恒失败） | `package` |
| lzma-alone | LZMA SDK（公有领域） | `package` |
| xz | xz-embedded（0BSD，CRC32/CRC64 + BCJ） | `package` |
| 反汇编 | capstone 5.0.3 | `disasm` |
| Python | `dlopen` Python.framework + `dlsym` | `py` |

自检：

```
package {command:"selftest"}      # gzip / lzma / xz / tar 四个用例，期望 4/4
diagnose {command:"spawn"}        # 二进制可执行性 + 签名身份对照
```

> 进程内 Python 与 App 同生命周期：死循环无法安全强杀，需要重启 App。

---

## 6. 环境变量

设置 → **环境变量**（或让 AI 调 `env` 工具）：

- 注入**所有子进程**（BuildRunner 的 env 合并）
- 注入**进程内 Python**（`os.environ`，执行前从临时 JSON 更新）
- 值默认掩码显示，左滑删除；名称须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`

```
env {command:"set", key:"HTTP_PROXY", value:"http://127.0.0.1:8080"}
env {command:"list"}
```

---

## 7. 构建

### CI（GitHub Actions）

`.github/workflows/build-xosvi-ios.yml`，推 `main` 自动构建并发布滚动 Release。

| Job | 产物 |
|---|---|
| `native-tools` | bsdtar / lua / node / r2 / cstool / jq / **libcapstone.a** |
| `native-python` | Python.xcframework |
| `native-wheels` | numpy / pandas（可选） |
| `native-nmap` | nscan.py（可选） |
| `native-llvm` | llvm-objdump / nm / readelf / jtool2（可选） |
| `build` | 主 App + tweaks + iSH 引擎 → `Xosvi.tipa` |

`build` 只硬依赖 `native-tools`（其余下载步骤 `continue-on-error`）；只在 `main` 上发布 Release。

下载：<https://github.com/weishixiao/xosvi-ios/releases/download/latest/Xosvi.tipa>

### 本地

需要 macOS + Xcode（交叉编译 iOS 二进制与 tweaks）：

```bash
bash scripts/build-openssl.sh
bash scripts/build-vanson.sh
bash scripts/build-ipa.sh          # 产出 build/Xosvi.app + tipa
```

---

## 8. 排障

| 现象 | 命令 | 说明 |
|---|---|---|
| 内置二进制跑不起来 | `diagnose spawn` | 看 `team_id/adhoc/errno`，区分"签名身份"与"文件损坏" |
| deb/ipa 解不开 | `package selftest` | 解码器自检，4/4 才说明工具本身没问题 |
| Alpine 命令报 `rc=-2` | `engine reset-rootfs` → **完全关闭 App** → 重开 | iSH 内核挂在坏 rootfs 上无法进程内卸载 |
| 注入后 App 打不开 | `rescue scan` / `rescue recover_all` | 自动回滚 `.bak_macho` |
| 启动崩 | `diagnose startup` | 崩溃日志 + 注入残留判定 |

### 已知限制

- **rootHide/Relaxin**：App 内第三方二进制 exec 被拒（ENOSYS 85）→ 用 §5 的进程内工具，或进 iSH
- **iSH**：guest 进程不经过宿主 spawn，但 rootfs 损坏时 `rc=-2`，需重置 + 冷启动
- **进程内 Python**：与主进程同生命周期
- **`package` 的 bz2/zstd**：仍走内置 python3（若 python3 被拦则不可用）；gz/lzma/xz 已完全进程内

---

## 9. 目录结构

```
Sources/Xosvi/     主 App（Swift，~59k 行）
  MCPCore.swift        工具注册与分发
  Models.swift         会话 / 模型流 / 工具循环
  PackageTools.swift   deb/ipa 解包（进程内解码）
  DisasmTool.swift     进程内反汇编
  PyEvalTool.swift     进程内 CPython
  EnvVars*.swift       环境变量
CISH/                  iSH 桥接（C）
CLZMA/                 LZMA SDK + xz-embedded
CCapstone/             capstone 封装
CPyEmbed/              Python dlopen 桥接
VansonEngine/          内存引擎（GPL-3.0）
tweaks/                内置 tweak（Theos）
scripts/               构建脚本
Support/               Info.plist / entitlements
```

---

## 10. 开发约定

新增工具三步：

```swift
final class FooTool: MCPTool {
    let definition = ToolDefinition(
        name: "foo",
        summary: "一句话说清用途 + 什么时候别用 + 一个调用示例",   // 模型主要看这个
        parameters: ["command": "子命令", "path": "参数说明"],
        verified: true, category: "xxx", prerequisites: ["前置条件"])
    func invoke(_ params: [String: Any]) throws -> [String: Any] { ... }
}
```

1. 在 `MCPCore.register(...)` 注册
2. 错误用 `MCPError.classified`，**明确写 retry 是否有用**（否则模型会无脑重试）
3. 大输出走 `ToolRegistry.spillLarge`，诊断日志走 `ShellDiag` / `AuditLog`

---

## 11. 许可与致谢

仓库未附统一 LICENSE。第三方组件各自遵循原协议，分发时需一并遵守：

- **VansonEngine** — GPL-3.0（内存引擎衍生，含该目标的产物需按 GPL-3.0 分发）
- **capstone** — BSD-3-Clause
- **xz-embedded** — 0BSD
- **LZMA SDK** — Public Domain
- **iSH** — GPL-3.0
- **ZIPFoundation**（MIT）、**MachOKit**（MIT）、**RSKGrowingTextView**（MIT）

感谢 TrollStore / TrollFools / TrollSpeed / OpenMinis / iSH 等项目的公开实现。
