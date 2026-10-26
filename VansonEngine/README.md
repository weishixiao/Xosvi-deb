# VansonEngine —— Xosvi 内置内存引擎

本目录是 [VansonMod](https://github.com/vaenshine/VansonMod) 内存引擎部分的移植，供 Xosvi 的 `memory` MCP 工具直接调用，无需向目标 App 注入 dylib。

## 来源与许可

- **上游项目**：VansonMod v3.5.2 — <https://github.com/vaenshine/VansonMod>
- **上游许可**：GNU General Public License v3.0（全文见本目录 `LICENSE`）
- **本目录**：上游代码的衍生作品，同样以 GPL-3.0 分发。

因为 Xosvi 主程序静态链接了本引擎，**Xosvi 整体须以 GPL-3.0 分发**（提供对应源码）。

## 相对上游的修改

| 文件 | 修改内容 |
|---|---|
| `src/utils/helpers/VMLocalization.mm` | **重写**为轻量实现。上游依赖 `LocalizationCore` + 13 个语言表（约 1.1 万行 UI 文案），Xosvi 只需引擎错误/状态文案，故用 9 个 key 的中英对照表替代，保留同样接口。 |
| `src/utils/helpers/VMStoragePathHelper.mm` | 存储目录 `Documents/VansonMod/` → `Documents/MemoryEngine/`，避免与独立版 VansonMod 抢目录。 |
| `src/utils/managers/StorageCore.mm` | 同上，工作目录同步改为 `MemoryEngine`。 |
| `include/VMPointerChain.h` | 修正 `#include "../src/core/ModelCore.hpp"` → `"src/core/ModelCore.hpp"`：移植后目录层级变化，原相对路径失效。 |
| `include/VansonEngine.h` | **新增**。SwiftPM 模块伞形头，只导出 `VMMemoryEngine.h` + `VMLockEngine.h`（均为纯 ObjC，可被 Swift 安全导入）。 |

其余文件与上游一致，未做逻辑改动。

## 上了哪些文件（依赖闭包）

上游是完整 App（约 6 万行，含 UI）；这里只取内存引擎及其编译依赖，共 13 个编译单元：

```
src/memory/VMMemoryEngine.mm          引擎门面（搜索/读写/冻结/指针链，ObjC++）
src/memory/core/MemoryCore.cpp        扫描内核（NEON 加速，异步）
src/memory/core/SessionCore.mm        结果快照栈
src/core/SystemCore.cpp               远端模块列表 / Mach-O 解析 / 进程枚举
src/utils/helpers/VMStoragePathHelper.mm  沙盒路径探测
src/utils/helpers/VMLocalization.mm   文案（已重写）
src/utils/managers/StorageCore.mm     配置读写
src/utils/managers/PatchCore.mm       RVA 补丁记录
src/utils/managers/LockCore.mm        冻结项持久化
src/utils/managers/VMLockEngine.mm    定时回写（冻结）
src/utils/managers/VMLockManager.mm   冻结项管理
src/utils/managers/VMPointerChain.mm  指针链模型
src/utils/managers/VMRVAPatch.mm      RVA 补丁模型
```

**未引入**：全部 UI（`src/ui/`）、脚本引擎、备份、更新检查、审计、watchpoint —— 这些不影响内存搜索/读写能力。

依赖只有系统框架（Foundation / UIKit / JavaScriptCore 之外的部分均未使用），无第三方库。

## 构建

`scripts/build-vanson.sh` 把上述源码编成 `vanson-stage/lib/libVansonEngine.a`（arm64 + arm64e fat），流程与 `build-hud.sh` 相同，由 `build-ipa.sh` 在主 App 编译前调用。

## 已知约束

- 引擎的扫描 API 是**异步 completion 风格**（`dispatch_async` + block 回调），Swift 侧由 `VansonMemoryBridge` 用信号量转同步。
- `attachToPid:` 直接调 `task_for_pid`，需要 `task_for_pid-allow` entitlement；越狱环境下目标进程若有加固/AMFI 保护仍可能拿不到 task port。
- 上游写死仅 arm64（`ARCHS = arm64`）；本移植额外尝试 arm64e，失败自动回退 arm64。
