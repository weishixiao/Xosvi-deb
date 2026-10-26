import Foundation

// MARK: - v7.14.0：jb-p1lot 技能包（照搬上游 skills/jb-p1lot 的路由指引）
//
// 与技能存储共用一份正文：设置页「技能」里能看到、能开关；
// 系统提示词里只放一行指针，AI 判定要上真机时才 jb command:skill（或 skills.read）取全文。

enum JBPlotSkill {

    static let name = "jb-p1lot 真机 Tweak 闭环"
    static let summaryName = "jb-p1lot"

    /// 给 skills.json 用的条目（name/summary/instruction）
    static var entry: [String: String] {
        ["name": summaryName, "summary": summaryText, "instruction": content()]
    }

    static let summaryText = "drive a paired rootless jailbroken iOS device through the jb-p1lot bridge for tweak development, UI automation, debugging, diagnostics, screen capture, package deployment, userspace-only recovery. Use for: build+install+verify a tweak on a real jailbroken device, root shell on another device, HID/UI automation, LLDB/Frida, sysdiagnose. Don't use for: this device's own tools (shell.exec / app / inject). Load it with jb command:skill or skills.read before a non-trivial device flow."

    /// 上游 SKILL.md + references/*.md 的中文化压缩版（保持"先发现设备、显式 UDID"的硬约束）
    static func content() -> String {
        """
        当用户要在已配对的越狱设备（Dopamine/rootless）上做 tweak 开发、UI 自动化、调试、诊断、截屏、装包或用户态恢复时执行本技能。

        ## 0. 硬约束
        - 先 `jb command:devices`；配对设备 >1 时每条命令都要带 `device:<udid>`，不要依赖默认设备。
        - 输出一律有界：大结果走 `artifactPath`（宿主沙箱），不要让日志/截图整段进 context。
        - `ui_snapshot` 返回的 node id **只在当帧有效**：快照后立刻 `ui_action`，否则重新快照（frameId 会变）。
        - 所有 reboot 类动作（`device_action` reboot / userspace_reboot / respring / sbreload）都映射到 Dopamine 的用户态重启；硬件重启会被拒绝——不要试图绕过，越狱会丢。

        ## 1. 设备与连通性
        1. `jb command:devices` → 拿到 UDID / 地址；`jb command:status` → 桥接、越狱、传输、后端状态。
        2. 未配对：设置 → jb-p1lot → 配对新设备（需要设备 SSH 地址）或 `jb command:pair ssh_host:<ip>`。
        3. 不通时先看 status 的 transport 字段：USB 优先 USBMux，WiFi 走 TLS 1.3 双向认证；两条都不通再查 daemon 是否在跑（`jb command:run subcommand:shell_exec params:{"command":"launchctl list | grep jb"}`）。

        ## 2. Tweak 闭环（本技能的核心）
        1. 源码：AI 写 Tweak.xm / Makefile / Filter.plist（rootless 方案 THEOS_PACKAGE_SCHEME=rootless）。
        2. 拷到设备：`file_write`（小文件）或 `file_transfer`（整目录，direction:host-to-device）。
        3. 一条龙：`jb command:run subcommand:tweak_cycle project:<设备上的工程目录> timeout:1800`，参数 `reload`（要重载的进程）、`processes`（心跳校验进程名）、`rollbackOnCrash:true`（崩溃自动回滚上一版包）。
        4. 分步调试：`tweak_build`（只要产物）→ `tweak_deploy`（装+校验心跳）→ `log_query`（predicate 过滤目标进程）→ `crash_manage`。
        5. 失败判读：build 错看 gmake 输出；deploy 后心跳无输出＝dylib 没被加载（先查 Filter.plist 的 Executables/Classes 与 rootless 路径 `/var/jb`）。

        ## 3. UI 自动化（语义优先）
        - `ui_snapshot application:<bundleId>` → 取 frameId + nodeId → `ui_action action:press frameId:.. nodeId:..`。
        - 语义选择器可用时别用坐标；坐标只用于游戏 canvas / 无无障碍信息的界面。
        - 输入文本：`ui_action action:type text:"..."`；按键/手势走 `button`、`points`。
        - 等界面稳定：`ui_wait selector:... timeoutMs:...`，别用固定 sleep。

        ## 4. 调试与诊断
        - 崩溃：`crash_manage action:list process:<name>` → `action:retrieve path:<...>`（可 symbolicate）。
        - 日志：`log_query predicate:"process == 'X'" limit:200`；需要持续跟踪时建长驻会话再 `session_read`。
        - 卡死/性能：`metrics_stream durationMs:5000 process:<name>`。
        - 网络：`network_capture filter:"tcp port 443" durationMs:10000` → PCAP 落 artifactPath。
        - 断点/动态：`debug_session`（LLDB）、`frida_session`（Frida 脚本 attach）；结束后务必 stop 会话。

        ## 5. 恢复（用户态优先）
        1. 目标 App 崩循环：先 `tweak_deploy` 回滚包，或 `package_manage action:rollback package:<id>`。
        2. SpringBoard 异常：`device_action action:respring`（用户态），失败再 `userspace_reboot`。
        3. 始终避免硬件重启；恢复后复查 `device_status` 与 `log_query` 确认根因已消除。

        ## 6. 与 Xosvi 本机工具的分工
        - 本机（这台 iPhone 本身）的文件/注入/UI：`shell.exec` / `app` / `inject` / `control`。
        - 另一台越狱设备、或需要真 Theos gmake + dpkg + 心跳验证：`jb`。
        - 离线编译、无设备时：`github`（CI 出 dylib）+ `inject`；有设备后用 `jb tweak_cycle` 才有心跳证据。
        """
    }
}
