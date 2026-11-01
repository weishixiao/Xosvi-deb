# Xosvi AI 无缝化：从分析到落地（v7.17.0）

> 本文对应两份输入材料：
> ① 《Xosvi 深入分析（续）——运行机制、核心子系统与工程方法论》
> ② 《Xosvi 优化建议书 v1.0 —— 让 AI 无缝衔接使用项目工具 + 待完善功能清单》
>
> 目标不是复述，而是：**把两份材料整理成可执行项 → 逐条对照真实代码核验 → 实现 P0 → 记录剩余项**。
> 所有「现状」结论都以仓库当前源码为依据，并标注了核验位置。

---

## 一、材料整理（去重后的结构）

两份材料其实是三层内容，混在一起读容易失焦：

### 第 1 层：运行时机制（分析篇 8–16 节）

| 子系统 | 一句话结论 | 对本次改动的意义 |
|---|---|---|
| `runAsRoot` 四级降级链 | 直写 → persona → 越狱 spawn → native 兜底；早期 `early return` 跳过兜底、argv 污染都造成过静默失败 | 说明「多路径降级 + 参数约定一致」是本项目的生存方式；新校验器因此只做**调用前**校验，不干预工具内部降级 |
| ControlAgent（4789） | 目标进程内手写 HTTP server + UI 树 + 私有 API 穿透 + 进程内砸壳 | UI 树文案是不可信外部输入 → 本次加 `_untrusted` 标记 |
| HIDTouchInjector | 绕过注入直接合成系统触摸，未经真机验证 | 保持原状，列入剩余验证项 |
| DeviceProbe | 环境自检、runLock 串行、entitlements 判据修正 | 本次新增的「环境能力投影」直接复用 `JBEnvironment`，不重复造检测 |
| 崩溃知识库 | 29 条种子 + 命中计数，但只有 AI 主动 `kb.query` 才用 | 本次把它接进 dispatch 失败出口（自动 `kb_fix`） |
| AuditLog | 500 条内存 + 按天滚动 + 工具健康度聚合 | 本次错误码统计沿用现有 `logTool(code:reason:nextStep:)` |
| CPython 嵌入 / kfd helper | 一切绕过 spawn；codesign 大端解析细节 | 不影响本次协议层改动 |
| 工程方法论 | 注释即知识库、修复写清为什么、多路径降级、为 AI 而设计、可观测性内建 | 本次所有改动按同一风格写注释与版本号 |

### 第 2 层：优化建议（建议书 A1–H4）

原文按「发现 → 问题 → 建议 → 验收」组织，但优先级表与正文有重复，且部分数字（37/162）互相矛盾。整理后只有 6 个真正的目标：

1. **可发现**：AI 看得到工具、参数类型、前置条件、环境约束。
2. **会调用**：一次传对参数，不靠试错。
3. **能自愈**：错误结构化 + 知识库自动挂载。
4. **不空转**：熔断 + 去重 + 预算。
5. **结果可用**：统一信封 + 截断/落盘元数据。
6. **安全可控**：外部内容不当指令、默认提示词不埋雷、破坏性操作有闸。

### 第 3 层：功能清单（VPN / HID / iSH / 技能 / 传输 / 远程 / 知识 / 可观测 / Memory）

这些是产品功能，不属于「AI 无缝用工具」的 P0，本次只做与工具契约直接相关的部分，其余保留为路线图。

---

## 二、逐条核验：材料说的，代码里到底是不是这样

| 编号 | 材料结论 | 真实代码核验 | 判定 |
|---|---|---|---|
| A1 | `tools/list` 只导出 name/description/parameters/verified | `JSONRPC.swift` 原第 21–31 行确实只有 4 个字段；`ToolDefinition` 已有 returns/prerequisites/环境字段 | ✅ 成立 |
| A2 | 缓存白名单写 `skill.list/skill.read`，真实工具是 `skills.*` | `MCPCore.swift` `longCacheTools` 确为 `skill.list/skill.read` | ✅ 成立（已修） |
| A2 | `RULES.md` 还写 `ta list` | `RULES.md` 路由契约第 4 条确为 `ta list`；`AGENTS.md` 明确禁止 ta 前缀 | ✅ 成立（已修） |
| A3 | 描述里大量裸点分名 | 全仓原文扫描 57 个不同 token；但**已注册工具**里只有 3 处（`knowledge.search`、`automation.cron_fire`、`app.launch`）。其余在已删除/未注册的旧工具描述与注释里 | ⚠️ 部分成立：AI 可见面只有 3 处（已修），旧工具描述不在调用面 |
| A4 | 37 / 162 / 动态三种口径 | `AGENTS.md`=37；`MCPCore` 注释=162；实际注册 **49**、定义类 167 | ✅ 成立（已统一为「以 system.overview 为准」） |
| A5 | 协议版本写死 2024-11-05 / 2.0.0-m1，缺 ping/notifications/分页 | `JSONRPC.swift` 原样 | ✅ 成立（已修） |
| B1 | 子命令参数契约未强制校验；`paramSpecs/variants` 只有极少数工具 | 全仓只有 `inject` 与 `app` 声明了 variants；dispatch 无校验 | ✅ 成立（已加校验器） |
| B1 | `app install` 的 variants 含伪参数 | 原为 `requires: ["ipa_path 或 path（二选一）"]`——一旦启用校验会**永久拒绝合法 install** | ⚠️ 材料没提到，实现时发现并修（新增 `requiresAny`） |
| C1 | 结构化 `MCPError.classified` 已存在但少用 | 定义存在；绝大多数工具仍 throw `.failed`/`.invalidParams` | ✅ 成立（dispatch 统一升级为 `.diagnosed`） |
| C2 | 知识库未自动挂载 | 只有 `kb.query` 工具会调 `FailureKnowledgeBase.match` | ✅ 成立（已接入失败出口） |
| C3 | prerequisites 仅文档 | 正确，dispatch 无预检 | ✅ 成立（本次**未**做，见剩余项） |
| D1 | 缓存策略是前缀数组 + 白名单硬编码 | 正确 | ✅ 成立（新增 `CachePolicy`，保留兼容兜底） |
| E1 | 共享可变状态缺锁 | `sessionApproved`、`resultCache`、`cacheHitCounts`、`recentCalls`、`failureStreak`、`apiNameToOriginal` 均有无锁读写 | ✅ 成立（已全部加锁） |
| F1 | 返回字段五花八门，靠 `defaultSuccessMessage` 猜 | 正确；无统一信封 | ✅ 成立（已加信封） |
| F2 | tool_spill 元数据未标准化 | `truncated` 在 data 内；落盘路径只在提示文本里 | ✅ 成立（信封提取 `spill_path`） |
| G1 | 提示注入防护只在 web.fetch | 正确 | ✅ 成立（已推广到 artifact read / file analyze / control ui_tree） |
| G2 | 默认种子 7+ 条破甲提示词 | 实际 **10 条**，带自动播种 + 版本迁移 | ✅ 成立（默认改为中性契约；实验包手动导入） |
| H1 | README 0 字节；GPL 义务未显性化 | 正确；根目录也没有 LICENSE | ✅ 成立（已补 README + GPL-3.0） |
| H2 | `check_tool_registration.py` 硬编码 `C:\Users\q3711\...` | 正确 | ✅ 成立（已参数化 + 入 CI） |
| H3 | 缺「文档即代码」与 schema 快照 | 正确 | ✅ 快照 + CI diff 已做；AGENTS.md 段落自动生成未做 |
| — | 「system.overview / tools.audit 是权威工具清单」 | 两者**注册了但不在 defaultEnabledTools**，AI 实际看不到 | ⚠️ 材料没发现（已修） |
| — | 「OpenAI schema 会把 remoteOnly 工具发给内置 AI」 | `enabledOpenAIToolSchema` 未过滤 `remoteOnly` | ⚠️ 材料没发现（已修） |

---

## 三、本次实现（P0 全部 + 部分 P1）

### 1. 新增 `Sources/Xosvi/ToolContract.swift`（契约层，唯一事实来源）

- `ToolAnnotations`：`readOnly / destructive / idempotent / openWorld`，默认**保守**（写操作绝不误标只读）。
- `RelatedTool`：结构化交叉引用，渲染成 `inject command:enable`，禁止再手写裸点分名。
- `CachePolicy`：`ttl + invalidatedBy`，把缓存策略从「前缀数组」上收到工具定义。
- `ToolContract.inputSchema`：统一 JSON Schema 生成器，MCP 与 OpenAI 两条路径共用。
- `ToolContract.mcpTool`：下发 `inputSchema`、`returns`、`prerequisites`、`environment`、`available`、`variants`、`related`、`annotations`、`outputSchema`，并保留 `parameters` 兼容旧客户端。
- `ToolParamValidator`：调用前校验缺参 / 类型 / 枚举 / 未知子命令 / `requiresAny` / `bundle_id` 形态；错误附完整可照抄模板。
- `ToolResultEnvelope`：统一 `ok/code/message/data/next_step/evidence/truncated/spill_path/cache_age`。
- `ToolExternalContent`：`<external_content>` 包装 + `_untrusted` 标记 + `injection_suspected`。
- `TrollStorePresence`：进程内缓存一次，供环境投影使用。

### 2. `MCPCore.swift`

- `ToolDefinition` 追加 `annotations / cache / related / outputSchema / examples`（全部带默认值，150 个旧工具无需改动）。
- `MCPError` 新增 `.diagnosed(...)`：带 `kbFix` 与 `evidence`，并提供 `structured` 机器可读字典。
- `ToolRegistry`：
  - 新增 `stateLock`，保护 `resultCache / cacheHitCounts / recentCalls / failureStreak`；
  - `sessionApproved`、`apiNameToOriginal`、`searchTools` 全部纳入锁；
  - `resolveTool()` 统一加锁解析原名 / apiName；
  - dispatch 前置：环境判定 → 参数校验 → 执行；
  - 成功：写后精准失效 + 统一信封；
  - 失败：`diagnose()` 升级为 `.diagnosed`，自动挂 `FailureKnowledgeBase.match` 的 `kb_fix`；
  - `loopBlockedError` 改为 `.diagnosed(code: LOOP_BLOCKED)`；
  - 修正 `longCacheTools` 的 `skill.*` → `skills.*`；
  - `defaultEnabledTools` 补 `system.overview / tools.audit / prompt.read_mode`；
  - OpenAI schema 过滤 `remoteOnly`，并改用统一投影。
- `enabledOpenAIToolSchema` / `openAISchema(for:)` 不再各自拼 schema。

### 3. `JSONRPC.swift`

- `initialize`：echo 客户端协议版本（2024-11-05 / 2025-03-26 / 2025-06-18），版本号从 Bundle 读。
- 新增 `ping`、`notifications/*`（无响应）。
- `tools/list`：完整元数据 + `cursor/pageSize` 分页。
- `tools/call`：失败时 `error.data` 带 `code/reason/next_step/kb_fix/evidence`；成功带 `isError:false` 与 `structuredContent`。

### 4. 安全

- `DeveloperInstructionStore`：默认种子从 10 条破甲提示词改为 1 份中性《工具使用契约》；原内容移入 `DeveloperInstructionLegacyPack`，设置页「导入实验性指令包」手动导入，**导入后默认不启用**。
- `artifact read` / `file analyze` / `control ui_tree`：外部内容统一标记，UI 文案额外检测注入特征。

### 5. 工程卫生

- `scripts/check_tool_registration.py`：参数化（`--src` / `XOSVI_SRC`），修 167 类 → 49 注册的核验。
- `scripts/check_swift_braces.py`：重写，支持原始字符串，真正返回非零退出码。
- `scripts/lint_tool_descriptions.py`（新）：重复名 / apiName 碰撞 / 幽灵点分名 / 空摘要（P0），三段式描述与默认启用（P1 警告）。
- `scripts/dump_registry.py`（新）+ `docs/registry.snapshot.json`：注册表快照。
- `tests/test_registry_contract.py`（新）：注册表 / 子命令 / 必填参数 / 快照一致性断言，纯 Python 可跑。
- `.github/workflows/lint.yml`（新）：上述四项 + snapshot diff。
- `README.md`、根 `LICENSE`（GPL-3.0）、`AGENTS.md`、`RULES.md` 更新。

### 6. 实现过程中发现并顺手修掉的隐藏 bug

材料没提到，但在接线时暴露出来的真实问题：

| 问题 | 后果 | 修法 |
|---|---|---|
| `system.overview` / `tools.audit` / `prompt.read_mode` 注册了但不在 `defaultEnabledTools` | 系统提示词称它们是「权威工具清单」，AI 却根本看不到 | 补进默认启用 |
| `enabledOpenAIToolSchema` 未过滤 `remoteOnly` | 内置 AI 会调用「仅远程可用」的工具，必被拒 | 过滤 |
| `app install` 的 variant 写成 `requires: ["ipa_path 或 path（二选一）"]` | 一旦启用参数校验，合法 install 会被永久拒绝 | 新增 `ToolVariant.requiresAny`，写成真实参数名 |
| `control command:tap x:100 y:200` | JSON 把 100 解析成 Int，工具写 `as? Double` → 判为缺参 | 新增 `Dictionary.num/intValue/boolValue`，统一数值读取 |
| `app stats duration` 契约是 Int、实现读 Double | 传整数时静默退回默认 5s | 契约改 `.number`，实现用 `intValue` 兼容 |
| `FailureKnowledgeBase` 的 SQLite 句柄无锁 | dispatch 失败出口自动查库后，多会话并发可能崩 | `NSRecursiveLock` 串行化 |
| `PackageTools` 对 `MCPError` 的 switch 是穷举的 | 新增 `.diagnosed` 后编译不过 | 补 case |
| 内置 AI 只认 `.classified` | `.diagnosed` 会退化成一段字符串，丢掉 kb_fix | `Models.swift` 增加 `.diagnosed` 分支 + 全部错误带 `structured` |

---

## 四、验收方式

```sh
python3 scripts/check_swift_braces.py            # 155 files, 0 problems
python3 scripts/check_tool_registration.py       # 49 registered, 49 unique, OK
python3 scripts/lint_tool_descriptions.py        # 0 errors（30 条 P1 格式警告）
python3 scripts/dump_registry.py --out docs/registry.snapshot.json
python3 tests/test_registry_contract.py          # 49 tools, snapshot up to date
```

本轮已通过（本地 iSH，无 Swift 编译器；结构检查不等价于编译）。

真机验收建议（对应建议书 §6）：

- [ ] `tools/list` 每个工具都带 `inputSchema` + `annotations` + `environment`，`available=false` 时带原因。
- [ ] `unknownTool` = 0：AI 只按 `system.overview` 的名字调用。
- [ ] 首次调用成功率：注入 / 抓包 / 取证 / UI 控制 / 包解析各 5 例。
- [ ] 故意少传 `bundle_id`：返回 `PARAM_INVALID`，`next_step` 里有完整模板。
- [ ] 故意触发 `Operation not permitted`：返回里出现 `kb_fix`（TrollStore entitlements 那条）。
- [ ] 同一参数连错两次：`LOOP_BLOCKED` 且本轮 run 终止。
- [ ] `artifact read` 一个含「忽略之前的指令」的文件：返回 `injection_suspected=true`。

---

## 五、剩余项（未在本轮实现，按优先级）

| 编号 | 事项 | 原因 / 建议 |
|---|---|---|
| C3 | prerequisites 运行时预检 | 需要每个大工具把前置条件写成可判定函数（端口/进程/dylib），先做 `network.capture` 与 `memory` 两个试点 |
| D3 | per-run 工具预算 + 同参去重 | 已有 `recentCalls` 60s 窗口与成功 3 次提示；预算需要 run 生命周期钩子（RunScope 目前只有 abort 标志） |
| G3 | destructive 操作强制备份凭证 | 需要 dispatch 层接入 `_bak_macho` 现状并定义「不可备份」白名单；先做 `inject/app` |
| G4 | RemoteAgent / DeviceReporter 数据去向可视化 | 属设置页与审计 UI，改动面大 |
| H4 | 高危链路端到端冒烟 | 需要真机/CI runner；建议先补 `tests/` 下的 registry/schema 单元测试（纯 Python 可跑） |
| A3 | 旧工具描述全量清理 | 49 个已注册工具已 0 幽灵引用；剩余点分名在已删除工具的类定义里，不进入 AI 视野，可随手清理 |
| H3b | 由注册表生成 AGENTS.md 的「工具速查 / 前置关系」段落 | 需要先定义生成模板，避免生成内容与手写说明打架；快照已就位，可直接作为数据源 |
| A6 | iOS 版本区间强制拦截 | 有意只做 metadata 不做拦截：`inject` 这类大工具混着多版本可用子命令，整体拦截会误杀 |
| — | 33 条描述缺 `Use for/Don't use for/Example` | P1 格式债；`lint` 已能精确列出，按工具逐步补 |
| — | VPN 抓包闭环 / HID 真机验证 / iSH doctor / 技能编排 | 原建议书的功能清单，独立于本次契约层 |
