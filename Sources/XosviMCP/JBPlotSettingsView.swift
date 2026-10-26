import SwiftUI

// MARK: - v7.14.0：jb-p1lot 设置页
//
// 三件事：宿主二进制（安装/更新/自检）、设备配对与发现、默认设备选择。
// 全部黑白线条风格（deepseekPage / deepseekList），语义色只用于危险操作。

struct JBPlotSettingsView: View {
    @ObservedObject private var lang = LanguageManager.shared
    @State private var binaryState = JBPlot.binaryState

    // 安装 / 更新
    @State private var installing = false
    @State private var installLog = ""
    @State private var version = ""

    // 设备
    @State private var devices: [[String: Any]] = []
    @State private var scanning = false
    @State private var defaultDevice = JBPlot.defaultDevice

    // 配对
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUser = "root"
    @State private var sshPassword = ""
    @State private var pairing = false
    @State private var pairResult: String?

    // 自检
    @State private var statusText: String?
    @State private var copyStatus = ""

    var body: some View {
        List {
            binarySection
            devicesSection
            pairSection
            usageSection
            if let s = statusText {
                Section(header: Text("自检")) {
                    Text(s)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(DoubaoTheme.subText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("jb-p1lot")
        .deepseekPage()
        .deepseekList()
        .onAppear {
            binaryState = JBPlot.binaryState
            if deviceListIsCached { devices = JBPlot.pairedDevices }
        }
    }

    private var deviceListIsCached: Bool { !JBPlot.pairedDevices.isEmpty }

    // MARK: 宿主二进制

    private var binarySection: some View {
        Section(header: Text("宿主程序"),
                footer: Text(binaryState == "missing"
                             ? "Xosvi 需要一个 jb-p1lot 宿主程序来驱动已配对的越狱设备。点「安装」会从 GitHub Release 下载 darwin-arm64 并自动重签（jb-p1lot 为 GPL-3.0，不随 App 分发）。"
                             : "「更新」总是拉最新 Release；下载版放在本 App 沙盒，删除 App 即清除。")) {
            HStack {
                Text("状态")
                Spacer()
                Text(binaryState == "installed" ? "已安装（上游 Release 下载版）" : "未安装")
                    .foregroundColor(binaryState == "missing" ? .red : DoubaoTheme.subText)
            }
            if !version.isEmpty {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(version).foregroundColor(DoubaoTheme.subText)
                }
            }
            Button {
                installOrUpdate()
            } label: {
                HStack {
                    Label(binaryState == "missing" ? "安装" : "更新到最新", systemImage: "arrow.down.circle")
                    Spacer()
                    if installing { ProgressView() }
                }
            }
            .disabled(installing)
            Button {
                selfTest()
            } label: {
                Label("自检（--version / devices）", systemImage: "checkmark.seal")
            }
            .disabled(binaryState == "missing")
            Button {
                let r = JBPlot.copyToJailbreakPath()
                copyStatus = r.ok ? "已拷贝到 /var/jb/…" : r.message
            } label: {
                Label("拷贝到越狱路径（Relaxin / rootHide）", systemImage: "arrow.up.doc")
            }
            .disabled(binaryState == "missing")
            if !installLog.isEmpty {
                Text(installLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DoubaoTheme.subText)
            }
        }
    }

    // MARK: 设备

    private var devicesSection: some View {
        Section(header: HStack {
            Text("已配对设备")
            Spacer()
            Button {
                scanDevices()
            } label: {
                if scanning { ProgressView() } else { Label("发现", systemImage: "antenna.radiowaves.left.and.right") }
            }
            .disabled(scanning || binaryState == "missing")
        }, footer: Text("配对授予对设备的 root 权限；桥接走 WiFi TLS 1.3 双向认证，插入 USB 时优先走 USBMux。")) {
            if devices.isEmpty {
                Text("还没有已配对设备。先在目标设备上安装 jb-p1lot（deb / TrollStore），再在上面「配对」里填它的 SSH 地址。")
                    .font(.system(size: 12))
                    .foregroundColor(DoubaoTheme.subText)
            }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, d in
                let udid = (d["id"] as? String) ?? (d["udid"] as? String) ?? ""
                let name = (d["name"] as? String) ?? (d["product"] as? String) ?? "未知设备"
                let addr = (d["address"] as? String) ?? ""
                Button {
                    defaultDevice = udid
                    UserDefaults.standard.set(udid, forKey: "jb.defaultDevice")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).foregroundColor(.primary).lineLimit(1)
                            Text("\(udid)\(addr.isEmpty ? "" : " · \(addr)")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(DoubaoTheme.subText)
                                .lineLimit(1)
                        }
                        Spacer()
                        if udid == defaultDevice {
                            Image(systemName: "checkmark")
                                .foregroundColor(.primary)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: 配对

    private var pairSection: some View {
        Section(header: Text("配对新设备"),
                footer: Text("SSH 只用于首次下发身份与安装桥接 daemon；配对完成后由 TLS 桥接接管，密码不会保存在 App 里。")) {
            TextField("设备 IP / SSH 主机", text: $sshHost)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                TextField("端口", text: $sshPort).keyboardType(.numberPad).frame(width: 70)
                Divider()
                TextField("用户", text: $sshUser).frame(width: 80)
            }
            SecureField("密码（仅本次使用）", text: $sshPassword)
            Button {
                pair()
            } label: {
                HStack {
                    Label("配对", systemImage: "link.badge.plus")
                    Spacer()
                    if pairing { ProgressView() }
                }
            }
            .disabled(pairing || sshHost.isEmpty || binaryState == "missing")
            Button {
                startLocalSSH()
            } label: {
                HStack {
                    Label("远程 SSH · 本机（127.0.0.1）", systemImage: "network")
                    Spacer()
                    if pairing { ProgressView() }
                }
            }
            .disabled(pairing || binaryState == "missing")
            Text("Relaxin：App 内 spawn 会被拦，经 ssh 到本机 /var/jb 里的 jb-p1lot 是唯一稳定的本机路径。默认 root@127.0.0.1:22。")
                .font(.system(size: 11))
                .foregroundColor(DoubaoTheme.subText)
            if let r = pairResult {
                Text(r)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(DoubaoTheme.subText)
            }
        }
    }

    // MARK: 用法说明

    private var usageSection: some View {
        Section(header: Text("在对话里怎么用"),
                footer: Text("AI 生成 .xm 源码 → 拷到设备 → jb 调用 tweak_cycle 完成 gmake + dpkg + reload + 心跳校验 + 崩溃回滚。")) {
            Text("""
            jb command:devices                     发现设备
            jb command:run subcommand:shell_exec params:{"command":"uname -a"}
            jb command:run subcommand:tweak_cycle project:/var/jb/tweak/MyTweak
            jb command:run subcommand:ui_snapshot application:com.apple.Preferences
            jb command:commands                    全部子命令
            """)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DoubaoTheme.subText)
            if binaryState == "installed" {
                HStack {
                    Text("镜像到越狱路径")
                    Spacer()
                    Text(copyStatus.isEmpty ? JBPlot.jailbreakPath : copyStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(DoubaoTheme.subText)
                        .lineLimit(1)
                }
            }
            if binaryState == "downloaded" {
                HStack {
                    Text("下载路径")
                    Spacer()
                    Text("Application Support/jb-p1lot/bin").foregroundColor(DoubaoTheme.subText)
                }
            }
        }
    }

    // MARK: 动作

    private func installOrUpdate() {
        installing = true
        installLog = "开始下载…"
        DispatchQueue.global(qos: .userInitiated).async {
            let r = JBPlot.downloadBinary { msg in
                DispatchQueue.main.async { installLog = msg }
            }
            DispatchQueue.main.async {
                installing = false
                installLog = r.message
                binaryState = JBPlot.binaryState
                if r.ok { selfTest() }
            }
        }
    }

    private func selfTest() {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = JBPlot.exec(["--version"], timeout: 20)
            let d = JBPlot.run("device_list", timeout: 40, json: true)
            let text = """
            version: \(v.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? v.brief : v.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            devices: \(d.isOK ? "ok" : d.brief)
            """
            DispatchQueue.main.async {
                version = v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                statusText = text
                devices = JBPlot.pairedDevices
            }
        }
    }

    private func scanDevices() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            _ = JBPlot.run("device_list", timeout: 45, json: true)
            let list = JBPlot.pairedDevices
            DispatchQueue.main.async {
                scanning = false
                devices = list
            }
        }
    }

    /// Relaxin：先确认越狱路径里已放好宿主程序，再走 ssh 到本机
    private func startLocalSSH() {
        let copied = JBPlot.copyToJailbreakPath()
        copyStatus = copied.ok ? "已拷贝到 /var/jb/…" : copied.message
        sshHost = "127.0.0.1"
        if sshUser.isEmpty { sshUser = "root" }
        if sshPort.isEmpty { sshPort = "22" }
        pair()
    }

    private func pair() {
        pairing = true
        pairResult = nil
        var args = ["setup", "--all", "--ssh-host", sshHost.trimmingCharacters(in: .whitespaces),
                    "--ssh-port", sshPort.isEmpty ? "22" : sshPort,
                    "--ssh-user", sshUser.isEmpty ? "root" : sshUser]
        if !sshPassword.isEmpty { args += ["--ssh-password", sshPassword] }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = JBPlot.exec(args, timeout: 600)
            let list = { () -> [[String: Any]] in
                _ = JBPlot.run("device_list", timeout: 40, json: true)
                return JBPlot.pairedDevices
            }()
            DispatchQueue.main.async {
                pairing = false
                devices = list
                pairResult = r.isOK
                    ? "配对成功\(r.stdout.isEmpty ? "" : "：" + String(r.stdout.prefix(300)))"
                    : "配对失败：\(r.brief)"
                sshPassword = ""
            }
        }
    }
}
