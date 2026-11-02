# iOS 17.1 + Relaxin 设备专项改造清单（R①–⑱）

> 权威约束（来自用户提示词包）：
> - 目标设备 iOS 17.1 + Relaxin（RootHide 系，A14–A17）
> - TrollStore 不可用；ct_bypass 不可用（>17.0）；kfd 不可用（>16.6.1）；persona spawn 恒 85 (ENOSYS)；
>   rootHide 可能拦截 App 容器内第三方二进制执行（EBADEXEC 86）
> - 方向：注入支持静态路径；提权走 JB 侧二进制（/var/jb）与 native 直写；工具链优先 JB 侧；
>   一切策略由探测结果驱动（spawn_probe → ExecutionStrategy），禁止写死设备假设
> - 不得破坏 TrollStore（≤17.0）与其它越狱档既有路径；新逻辑一律「探测驱动/档位开关」

| # | 条目 | 状态 | 落地文件 | 说明 |
|---|---|---|---|---|
| R① | 环境探测（档位/jailbreak kind/spawn 结果） | ✅ | ExecutionStrategy.swift, Tools.swift | device.info/probe 返回 `execution_strategy` |
| R② | spawn_probe 四类探测（native/persona/jb/setuid） | ✅ | ExecutionStrategy.swift (SpawnProbe), InjectionManager.spawnRootProbe | 30s 缓存 |
| R③ | ExecutionStrategy 档位层 | ✅ | ExecutionStrategy.swift | trollStore/jailbroken/rootHide/containerOnly/locked |
| R④ | 档位开关收口 | ✅ | ExecutionStrategy.report/tier | 各模块只查策略层 |
| R⑤ | 工具链优先 JB 侧 | ✅ | ShellTool.effectivePATH / runIOSBundled | /var/jb 前缀 PATH |
| R⑥ | 跳过 persona | ✅ | InjectionManager.runAsRoot | personaExpectedBlocked → usePersona:false |
| R⑦ | 静态注入链 | ✅ | InjectionManager.injectStatic + installIPA | appinst/jbctl/trollstorehelper 链 |
| R⑧ | 内存直连 | ✅ | Tools.swift memory legacy 门 | rootHide 拒绝 legacy，引导 native |
| R⑨ | VPN + kfd 守卫 | ✅ | VpnManager.trustInjectionCapability, VpnTools.status | kfd 不可用→自动降级 |
| R⑩ | HID 优先 | ✅ | ControlToolsPolicy, ControlTools tap/swipe/status | HID 可用优先，回退注入 |
| R⑪ | 进程内注入器 | ✅ | InjectionManager.status 的 injection_strategy | 静态链 + 原生内存引擎 |
| R⑫ | iSH 路由 | ✅ | ShellTool.jbSideHas / autoRouteNeedsAlpine | JB 有工具→不送 Alpine |
| R⑬ | KB 条目 | ✅ | KnowledgeBaseAndCleanup v2Patterns | ENOSYS/EBADEXEC/NECP/kfd 等 7 条 |
| R⑭ | 文档 | ✅ | AGENTS.md, RULES.md | 双档矩阵 + 档位规则 |
| R⑮ | entitlements 指引 | ✅ | ExecutionStrategy.report | 越狱档无需 TS 编辑 Entitlements |
| R⑯ | UI 档位展示 | ✅ | DeviceDetectionView | 档位卡片 + 能力徽标 |
| R⑰ | 提速（探针缓存） | ✅ | ExecutionStrategy 30s 缓存 | report 暴露 ttl |
| R⑱ | 打包 --jb | ✅ | scripts/build-ipa.sh | Xosvi-jb.tar.gz + install.sh |

## 验收

- 手机：`device command:probe` 返回 `execution_strategy`（tier + spawn_probe 四类 + entitlements_guidance）
- 手机：`vpn.capture command:status` 返回 `trust_injection`
- 手机：`control command:status` 返回 `control_path`
- 电脑：`python3 tests/contract/run_all.py` 全绿；`git push main` 触发构建成功
