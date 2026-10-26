import Foundation

// MARK: - v7.14.2：构建与注入技能（对齐 jb-p1lot 的核心定位）
//
// jb-p1lot 是「执行引擎」：它不生成代码，只负责 构建(build) → 部署(deploy) → 注入+验证(heartbeat) → 回滚(rollback)。
// 生成环节由本 App 的 AI 承担，落盘用 workspace（沙盒），再用 jb push 推到设备。
// 三者的接线由 JB 工具的 scaffold / push 子命令固定下来，避免"写完了却推不上设备"。

enum JBPlotSkill {

    static let name = "jb-p1lot 真机 Tweak 闭环"
    static let summaryName = "jb-p1lot"

    /// 给 skills.json 用的条目（name/summary/instruction）
    static var entry: [String: String] {
        ["name": summaryName, "summary": summaryText, "instruction": content()]
    }

    static let summaryText = "build+deploy+inject a tweak on a paired rootless jailbroken device through jb-p1lot: AI writes the .xm, jb builds (Theos gmake), installs (dpkg), reloads, verifies a heartbeat and rolls back on crash. Also root shell, UI automation, LLDB/Frida, sysdiagnose on that device. Use for: any real-device tweak cycle or root-level op on a paired device. Don't use for: this device's own tools (shell.exec / app / inject). Load with jb command:skill before a non-trivial device flow."

    /// 正文：分工 → 三段式流程 → 硬约束 → 与 Xosvi 本机工具的分工
    static func content() -> String {
        """
        ## 0. 分工（先看清楚谁干什么）
        - **AI（你）负责生成**：写 Tweak 源码（Logos .xm / .x / Makefile / Filter.plist），追求可编译、钩子精准、范围最小。
        - **jb-p1lot 负责执行**：构建（Theos gmake package）→ 部署（dpkg 安装）→ 注入验证（reload + 心跳）→ 崩溃回滚。它**不会**替你写代码，也不会替你判断钩子对不对。
        - **Xosvi 的 jb 工具负责接线**：`scaffold` 生成工程骨架、`push` 把工程送到设备、`run` 调用上游子命令。

        ## 1. 生成：写工程（workspace 里）
        1. `jb {command:"scaffold", name:"MyTweak", bundle_id:"com.apple.Preferences"}` → 在沙盒 `Workspace/projects/MyTweak/` 生成 Makefile / Tweak.xm / Filter.plist，并返回它们的**绝对路径**。
        2. 用 `artifact {command:"write"}` 覆盖其中的 Tweak.xm（或直接 `shell.exec` 写文件）。
        3. 钩子选择守则：
           - 先 `jb {command:"run", subcommand:"ui_snapshot", application:"<bundleId>"}` 看界面，再 `jb … ui_action` 验证目标控件确实存在；
           - 反查方法名：`inject {command:"probe_inspect", bundle_id:"<...>"}`（本机）或设备侧 `jb … shell_exec params:"{\\"command\\":\\"class-dump …\\"}"`；
           - 能用 %init 的最小钩子就别钩 SpriteKit 循环，范围越小越不容易被 App 检测。
        4. Filter.plist 的 Executables 必须写**真实进程名**（不是 bundleId），写错＝dylib 不加载且不报错。

        ## 2. 构建 + 部署 + 注入（一条命令）
        - 先推工程：`jb {command:"push", project:"MyTweak"}` → 设备路径 `/var/jb/tweak/MyTweak`。
          传输走 App 内置通道（本地分块 base64 → 设备 file_write → 设备侧 cat 拼回），不依赖上游 file_transfer，也不受单帧大小限制；`.theos/`、`packages/`、`*.deb` 自动跳过。
        - 再一次跑完：`jb {command:"run", subcommand:"tweak_cycle", project:"/var/jb/tweak/MyTweak", reload:"Preferences", processes:"Preferences", rollbackOnCrash:true, timeout:1800}`
        - 分步（要定位问题时才拆）：
          `tweak_build {project, clean:true}` → 返回最新 .deb → `tweak_deploy {package, reload, processes}`（装 + 校验心跳）→ `log_query {predicate:"process == 'Preferences'", limit:200}` → `crash_manage {action:"list"}`。
        - 失败判读：
          - gmake 报错 → 看 output 里的第一个 error，常见是 SDK 版本 / 缺 framework（Makefile 里补 `<name>_FRAMEWORKS`）；
          - 装上了但心跳空 → Filter.plist 进程名错、或 rootless 路径不在 /var/jb（Makefile 必须 `THEOS_PACKAGE_SCHEME = rootless`）；
          - 装了直接崩 → 立刻 `tweak_deploy` 用上一版包回滚，或 `package_manage {action:"rollback"}`，再读崩溃栈定位。

        ## 3. 验证：拿证据，不靠"应该生效了"
        - 界面类：`ui_snapshot` 前后对比（新控件出现 / 文案变化）。
        - 行为类：`log_query` 找到你自己 NSLog 的那一行；
        - 崩溃类：`crash_manage action:list` 必须为空，才算过。
        - 数值类：`metrics_stream` 或设备上直接读数据文件（`file_read`）。
        没有以上任一条证据，不要说"已生效"。

        ## 4. 硬约束
        - 先 `jb {command:"devices"}`；配对设备 >1 台时每条命令带 `device:<udid>`。
        - `ui_snapshot` 的 nodeId **只在当帧有效**，快照后立即 `ui_action`。
        - 所有 reboot（device_action reboot / userspace_reboot / respring / sbreload）都是 Dopamine 用户态重启；硬件重启会被拒——越狱会丢，不要尝试绕过。
        - 大输出走 `artifactPath`，别把整段日志灌进 context。

        ## 5. 与 Xosvi 本机工具的分工
        - 生成 / 静态分析 / 代码审阅：本机（`shell.exec`、`inject probe_inspect`、`macho`、`disasm`）。
        - **构建 + 注入 + 心跳验证**：只有 `jb` 能给出真机证据（本机没有 Theos + dpkg）。
        - 完全没设备时：`github` 走 CI 出 dylib，再由用户手动装；有设备就用 `jb tweak_cycle`。
        """
    }

    // MARK: - 工程骨架（生成环节）

    /// 生成 rootless Theos 工程到 workspace，返回文件路径（供 JB 工具 scaffold 使用）
    static func scaffold(name: String, bundleId: String, executable: String) throws -> (dir: URL, files: [String]) {
        let safe = name.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let projectName = safe.isEmpty ? "MyTweak" : safe
        let dir = Workspace.root.appendingPathComponent("projects/\(projectName)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let process = executable.isEmpty ? (bundleId.isEmpty ? "SpringBoard" : bundleId) : executable
        let makefile = """
        # 由 jb scaffold 生成 —— rootless（/var/jb）方案，勿删第一行
        THEOS_PACKAGE_SCHEME = rootless
        TARGET = iphone:clang:latest:15.0
        ARCHS = arm64 arm64e
        INSTALL_TARGET_PROCESSES = \(process)

        TWEAK_NAME = \(projectName)
        \(projectName)_FILES = Tweak.xm
        \(projectName)_CFLAGS = -fobjc-arc

        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        let filter = """
        {
            Filter = {
                Bundles = ( "\(bundleId.isEmpty ? "com.apple.springboard" : bundleId)" );
                Executables = ( "\(process)" );
            };
        }
        """
        let tweak = """
        // \(projectName) — 由 jb scaffold 生成，AI 在此写钩子。
        // 守则：钩子范围最小、先 %orig 再改动、日志统一前缀 [\(projectName)] 便于 log_query 过滤。
        #import <UIKit/UIKit.h>

        %hook NSObject
        - (id)init {
            NSLog(@"[\(projectName)] init on %@", NSStringFromClass([self class]));
            return %orig;
        }
        %end
        """

        let files: [(String, String)] = [
            ("Makefile", makefile),
            ("\(projectName).plist", filter),
            ("Tweak.xm", tweak),
        ]
        for (f, body) in files {
            try body.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        return (dir, files.map { $0.0 })
    }
}
