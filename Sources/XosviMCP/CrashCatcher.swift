import Foundation
import SwiftUI
import Darwin

/// v2.9.145c：崩溃日志捕获——闪退自动落盘到工作区 crash/，设置页「崩溃日志」可查看。
/// 解决"闪退原因不可见"的排障盲区：此前用户报闪退只能靠猜，加上这个后每次闪退都有现场留痕。
enum CrashCatcher {
    static var crashDir: URL {
        Workspace.root.appendingPathComponent("crash", isDirectory: true)
    }

    // v2.9.150：signal-safe 预分配缓冲（install() 时在正常上下文分配，
    // handler 内只做指针写入，绝不触发 Swift 堆分配/字符串/ObjC）
    private static var sigPathBuf: UnsafeMutablePointer<CChar>?
    private static var sigMsgBuf: UnsafeMutablePointer<CChar>?
    private static let sigPathCap = 1024
    private static let sigMsgCap = 256   // v6.2.8：头行新增 slide 字段，扩容防溢出
    /// v6.2.2：backtrace 帧缓冲也预分配——旧版在信号处理器内每次 allocate，
    /// 而 malloc 非 async-signal-safe，崩溃现场堆已损坏时 allocate 可能二次段错误，
    /// 导致日志只写了一半/为空（实测"最新的三次日志全部为空"）。
    private static let sigFrameCap = 64
    private static var sigFramesBuf: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    // v2.9.172：crash 目录的 C 字符串路径在 install() 正常上下文一次性固化。
    // 旧版 handler 里 `crashDir.path` 每次访问都重新计算 URL（Swift/ObjC runtime），
    // 在信号上下文二次崩溃，导致 4 次 Segfault 全部只记录到 writeSignal 自身、
    // 真实崩溃点被掩盖（libsystem_platform.dylib 0x... + 480）。
    private static var crashDirC: UnsafeMutablePointer<CChar>?
    private static let crashDirCap = 1024
    /// v6.6.9：Workspace 父目录 C 路径也固化——handler 里先 mkdir 父目录再 mkdir crash，
    /// 修复"首次启动/重置数据后 Workspace 不存在 → mkdir 失败 → 崩溃日志丢失"的根因
    /// （install() 早于 Workspace.ensure()，App 启动早期崩溃时父目录可能还没建）。
    private static var crashParentC: UnsafeMutablePointer<CChar>?
    /// v6.2.4：handler 重入保护——backtrace 遍历 iSH 线程栈（swapcontext 边界）可能二次崩溃；
    /// 若 handler 自身段错误引发重入，直接恢复默认处理让系统兜底，避免无限递归。
    private static var inHandler: Int32 = 0
    /// v6.2.8：主镜像加载基址（mach header 地址）——install() 正常上下文固化。
    /// 崩溃日志里写出 base= 后，可用 tipa 内二进制符号化：
    ///   offset = 帧地址 - base（即该符号在二进制中的文件偏移，可直接喂 nm/llvm-nm 或 atos -l base）
    /// 此前日志只有裸地址，无法定位崩溃函数（用户两次崩溃都无法符号化）。
    private static var sigImageBase: Int = 0
    /// dladdr 探测用的本镜像内静态变量地址
    private static var sigLocalProbe: Int = 0

    // v6.6.9：信号处理器内禁止访问 Swift/ObjC 运行时——以下全部在 install() 正常上下文预缓存。
    // 旧版在 handler 里调 strsignal()（可能 malloc）、Bundle.main.infoDictionary（Swift runtime）、
    // UserDefaults.bool(forKey:)（文件 IO + 锁），崩溃现场堆已损坏时会二次段错误/死锁，
    // 导致崩溃日志为空或只写一半——这是"闪退日志没记录"的根因。
    private static let sigVersionCap = 64
    private static var sigVersionBuf: UnsafeMutablePointer<CChar>?
    private static var sigIshFlag: CChar = 48   // '0'=关 '1'=开，install() 时预读

    // v6.6.9：信号名表——install() 用正常上下文填 7 个槽（6 个已 arm 信号 + "SIG?"），
    // handler 内只用纯算术索引，完全不碰 Swift 字符串/字典。
    private static let sigNameCap = 16
    private static let sigSlotCount = 7
    private static var sigNameTable: UnsafeMutablePointer<CChar>?

    private static func sigSlot(_ s: Int32) -> Int {
        switch s {
        case SIGILL:  return 0
        case SIGTRAP: return 1
        case SIGABRT: return 2
        case SIGFPE:  return 3
        case SIGBUS:  return 4
        case SIGSEGV: return 5
        default:      return 6
        }
    }

    static func install() {
        // v6.2.8：固化主镜像基址——先试 dlsym(_mh_execute_header)（主可执行文件 mach header），
        // 失败则用 dladdr 探测本文件静态变量地址所在镜像的 dli_fbase（均为 Darwin/dlopen API，稳定可用）
        if let h = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_mh_execute_header") {
            sigImageBase = Int(bitPattern: h)
        } else {
            var info = Dl_info()
            let rc = withUnsafeMutablePointer(to: &sigLocalProbe) { ptr -> Int32 in
                dladdr(UnsafeRawPointer(ptr), &info)
            }
            if rc != 0, let fb = info.dli_fbase {
                sigImageBase = Int(bitPattern: fb)
            }
        }
        // 正常上下文：分配缓冲 + 固化目录 C 路径（handler 内不再碰任何 Swift 对象）
        let dir = crashDir.path
        let c = UnsafeMutablePointer<CChar>.allocate(capacity: crashDirCap)
        if let u = (dir as NSString).utf8String { strcpy(c, u) }
        crashDirC = c
        // v6.6.9：父目录（Workspace）C 路径固化 + 正常上下文预建目录树。
        // install() 早于 Workspace.ensure()，不预建的话启动早期崩溃会因父目录不存在而丢日志。
        let parent = Workspace.root.path
        let pc = UnsafeMutablePointer<CChar>.allocate(capacity: crashDirCap)
        if let u = (parent as NSString).utf8String { strcpy(pc, u) }
        crashParentC = pc
        try? FileManager.default.createDirectory(at: crashDir, withIntermediateDirectories: true)
        if sigPathBuf == nil { sigPathBuf = .allocate(capacity: sigPathCap) }
        if sigMsgBuf == nil { sigMsgBuf = .allocate(capacity: sigMsgCap) }
        if sigFramesBuf == nil {
            sigFramesBuf = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: sigFrameCap)
            sigFramesBuf?.initialize(repeating: nil, count: sigFrameCap)
        }
        // v6.6.9：预缓存版本号 + iSH 开关——handler 里绝不碰 Bundle/UserDefaults
        if sigVersionBuf == nil {
            let cap = sigVersionCap
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: cap)
            let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            var i = 0
            for ch in v.utf8 where i < cap - 1 { buf[i] = CChar(bitPattern: ch); i += 1 }
            buf[i] = 0
            sigVersionBuf = buf
        }
        sigIshFlag = UserDefaults.standard.bool(forKey: "alpineEngineEnabled") ? 49 : 48
        // v6.6.9：预填信号名表（7 槽 × 16 字节），handler 内纯算术索引
        if sigNameTable == nil {
            let tbl = UnsafeMutablePointer<CChar>.allocate(capacity: sigSlotCount * sigNameCap)
            tbl.initialize(repeating: 0, count: sigSlotCount * sigNameCap)
            let names = ["SIGILL", "SIGTRAP", "SIGABRT", "SIGFPE", "SIGBUS", "SIGSEGV", "SIG?"]
            for (i, n) in names.enumerated() {
                var j = 0
                for ch in n.utf8 where j < sigNameCap - 1 {
                    tbl[i * sigNameCap + j] = CChar(bitPattern: ch)
                    j += 1
                }
                tbl[i * sigNameCap + j] = 0
            }
            sigNameTable = tbl
        }

        // 1) ObjC 未捕获异常（Swift fatalError / 强解包 / 数组越界等走这里）
        NSSetUncaughtExceptionHandler { exception in
            let ts = time(nil)
            let dir = CrashCatcher.crashDir.path
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var lines: [String] = [
                "=== Uncaught Exception @ \(ts) ===",
                "name: \(exception.name.rawValue)",
                "reason: \(exception.reason ?? "(nil)")",
                "userInfo: \(exception.userInfo ?? [:])",
                "--- callStackSymbols ---"
            ]
            lines += exception.callStackSymbols
            let path = "\(dir)/exc_\(ts).txt"
            try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }

        // 2) POSIX 信号（EXC_BAD_ACCESS 等内存错误走这里）——handler 只做 signal-safe 的最小写盘
        // v6.2.4：改用 sigaction + SA_SIGINFO 获取崩溃地址(si_addr)。此前用 signal() 拿不到
        // 崩溃地址；且旧 handler 调 backtrace_symbols_fd（符号化器，重）在 iSH 线程栈上
        // 触碰 guest 地址二次段错误（实测 frame 0 = writeSignal+356，fault @0x1792235033 高位 guest
        // 映射区），导致崩溃日志全空。新实现：头行先写崩溃地址（先落盘，后续即使崩也有留痕），
        // backtrace 改用裸帧 hex 手写输出（零符号化、纯算术、signal-safe）。
        func arm(_ sig: Int32) {
            var sa = sigaction()
            sa.__sigaction_u.__sa_sigaction = { sig, info, _ in
                // 让编译器从属性类型推断参数类型，避免 SDK 版本间 __siginfo_t/__ucontext 命名差异
                let addr: UInt = info.map { UInt(bitPattern: $0.pointee.si_addr) } ?? 0
                CrashCatcher.writeSignal(sig, fault: addr)
            }
            sa.sa_flags = SA_SIGINFO
            sigemptyset(&sa.sa_mask)
            sigaction(sig, &sa, nil)
        }
        arm(SIGABRT)
        arm(SIGSEGV)
        arm(SIGBUS)
        arm(SIGILL)
        arm(SIGTRAP)
        arm(SIGFPE)
    }

    /// v2.9.150b：纯 signal-safe 写盘——上一版用 Swift String 插值/Date/数组，
    /// 在信号上下文里二次崩溃，导致日志全部只记录到 writeSignal 自身、
    /// 真正崩溃点被掩盖。现在只用 C 函数与手写整数拼接：
    ///   time/mkdir/strcpy/strlen/strsignal/open/write/backtrace/close
    /// 全部 async-signal-safe。
    /// v6.2.4：① 接收 si_addr 崩溃地址，头行先写崩溃地址并立即 write（先落盘留痕，
    /// 后续动作即使二次崩溃，头行已保存）；② 弃用 backtrace_symbols_fd（符号化器在
    /// iSH 线程栈上读 guest 地址会二次段错误），改手写 hex 输出裸帧地址。
    private static func writeSignal(_ s: Int32, fault: UInt) {
        // v6.2.4：重入保护——若 backtrace 遍历异常栈二次崩溃引发信号重入，
        // 直接恢复默认处理并重发（不再写盘），避免无限递归
        if OSAtomicCompareAndSwap32(0, 1, &inHandler) == false {
            signal(s, SIG_DFL)
            raise(s)
            return
        }
        let ts = time(nil)
        // v2.9.172：直接用启动时固化的 C 路径，零 Swift runtime 访问
        guard let d = crashDirC, let pb = sigPathBuf, let mb = sigMsgBuf else { return }
        // v6.6.9：先建父目录（Workspace）再建 crash——修复启动早期崩溃丢日志
        if let par = crashParentC { _ = mkdir(par, 0o755) }
        _ = mkdir(d, 0o755)
        // 路径: dir + "/sig_" + ts + ".txt"
        var p = pb
        strcpy(p, d)
        p += strlen(p)
        p[0] = 47  // '/'
        p += 1
        strcpy(p, "sig_")
        p += 4
        p = appendInt(p, ts)
        strcpy(p, ".txt")
        let fd = open(pb, O_CREAT | O_WRONLY | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        // 头部: "signal <name> fault=0x<hex> <ts>\n"——崩溃地址最先落盘，
        // 头行先 write，后续 backtrace 即使二次崩溃，头行已保存留痕
        var m = mb
        strcpy(m, "signal ")
        m += 7
        // v6.6.9：信号名查预填表（strsignal 非 signal-safe，崩溃现场可能二次崩溃）
        if let tbl = sigNameTable {
            let slotName = tbl + sigSlot(s) * sigNameCap
            strcpy(m, slotName)
            m += strlen(slotName)
        } else {
            m = appendInt(m, Int(s))
        }
        strcpy(m, " fault=")
        m += 7
        if fault != 0 {
            m = appendHex(m, fault)
        } else {
            strcpy(m, "0x0")
            m += 3
        }
        // v6.2.8：写出主镜像基址，便于事后符号化（offset = 帧地址 - base）
        strcpy(m, " base=")
        m += 6
        m = appendHex(m, UInt(bitPattern: sigImageBase))
        // v6.6.0：写出构建版本与引擎开关状态（排障关键：区分构建代次 / 是否开了 iSH）
        // v6.6.9：版本/开关均由 install() 预缓存，handler 内零 Swift 运行时访问
        strcpy(m, " ver=")
        m += 5
        if let vb = sigVersionBuf {
            strcpy(m, vb)
            m += strlen(vb)
        }
        strcpy(m, " ish=")
        m += 5
        m[0] = sigIshFlag
        m += 1
        strcpy(m, " ")
        m += 1
        m = appendInt(m, ts)
        strcpy(m, "\n")
        _ = write(fd, mb, strlen(mb))
        // backtrace/backtrace 均为 async-signal-safe；裸帧地址手写 hex 输出，
        // 不做符号化（符号化器在异常栈上可能二次崩溃——v6.2.4 修复）
        guard let frames = sigFramesBuf else {
            close(fd)
            return
        }
        let n = backtrace(frames, Int32(sigFrameCap))
        for i in 0..<Int(n) {
            m = mb
            m = appendHex(m, UInt(bitPattern: frames[i]))
            strcpy(m, "\n")
            _ = write(fd, mb, strlen(mb))
        }
        close(fd)
        // 恢复默认处理并重发，让系统也生成官方崩溃报告
        signal(s, SIG_DFL)
        inHandler = 0
        raise(s)
    }

    /// 手写 UInt→hex ASCII 追加到 p（signal-safe：纯算术、无字符串，零 Swift 运行时）
    /// 返回结尾（'\0' 位置）的下一位置
    private static func appendHex(_ p: UnsafeMutablePointer<CChar>, _ v: UInt) -> UnsafeMutablePointer<CChar> {
        var q = p
        var started = false
        var shift: UInt = 60
        while true {
            let d = (v >> shift) & 0xF
            if d != 0 || started {
                started = true
                // 0-9 → '0'+d; 10-15 → 'a'+(d-10)
                q[0] = d < 10 ? CChar(48 + Int(d)) : CChar(97 + Int(d) - 10)
                q += 1
            }
            if shift == 0 { break }
            shift -= 4
        }
        if !started {
            q[0] = 48  // '0'
            q += 1
        }
        q[0] = 0
        return q
    }

    /// 手写整数→ASCII 追加到 p 末尾（signal-safe：纯算术+指针，零 Swift 运行时）
    /// 返回结尾（'\0' 位置）的下一位置
    private static func appendInt(_ p: UnsafeMutablePointer<CChar>, _ v: Int) -> UnsafeMutablePointer<CChar> {
        if v == 0 {
            p[0] = 48
            p[1] = 0
            return p + 1
        }
        var n = v
        var neg = false
        if n < 0 { neg = true; n = -n }
        let start = p
        var q = p
        while n > 0 {
            q[0] = CChar(48 + (n % 10))
            q += 1
            n /= 10
        }
        if neg {
            q[0] = 45
            q += 1
        }
        var lo = start
        var hi = q - 1
        while lo < hi {
            let t = lo[0]
            lo[0] = hi[0]
            hi[0] = t
            lo += 1
            hi -= 1
        }
        q[0] = 0
        return q
    }

    /// v2.9.152：导出全部崩溃日志为一份文本（供分享/保存，用户反馈"不能分享保存"）
    static func exportAll() -> String {
        var out = "Xosvi 崩溃日志导出\n导出时间: \(Date())\n\n"
        for p in list() {
            out += "===== \(URL(fileURLWithPath: p).lastPathComponent) =====\n"
            out += content(p)
            out += "\n\n"
        }
        return out
    }

    // MARK: - 崩溃日志列表（设置页入口）

    static func list() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: crashDir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return [] }
        // 显式 sorted(by:) 避免 iOS16 SDK 的 SortComparator 重载歧义
        let urls: [URL] = entries.filter { $0.pathExtension == "txt" }
        let sortedUrls: [URL] = urls.sorted(by: { l, r in
            let lv = try? l.resourceValues(forKeys: [.contentModificationDateKey])
            let rv = try? r.resourceValues(forKeys: [.contentModificationDateKey])
            return (lv?.contentModificationDate ?? Date.distantPast) > (rv?.contentModificationDate ?? Date.distantPast)
        })
        return sortedUrls.map { $0.path }
    }

    static func content(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? "(读取失败)"
    }

    /// v2.9.177：分段读取预览——列表页不再全量读全文（大文件多次全读会卡死/内存抖），
    /// 详情页也限制最大字符数，避免超大 sig_ 文本把 Text 渲染拖崩。
    static func preview(_ path: String, maxChars: Int) -> String {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return "(读取失败)" }
        if s.count > maxChars {
            return String(s.prefix(maxChars)) + "\n…(截断，完整内容见文件)"
        }
        return s
    }

    static func clear() {
        try? FileManager.default.removeItem(at: crashDir)
    }
}

/// 崩溃日志查看页
/// v6.2.7：sheet(item:) 标识——每次打开新建详情视图，杜绝状态残留
private struct CrashLogItem: Identifiable {
    let path: String
    var id: String { path }
}

struct CrashLogView: View {
    @State private var paths: [String] = []
    // v6.2.7：修复"新日志点开空白"——旧实现用单一 @State detailContent + 共享
    // sheet(isPresented:)，首次弹出时内容视图未随新值重建（状态残留），必须先点开
    // 旧日志再开新日志才有内容。改 sheet(item:)：每次打开创建全新详情视图，
    // onAppear 自行读文件，无状态残留。
    @State private var detailItem: CrashLogItem?
    @State private var toast: String?
    @State private var newestFirst = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    newestFirst.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: newestFirst ? "clock.fill" : "clock.arrow.circlepath")
                        Text(newestFirst ? "最新" : "最早").font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 4)
            }
            List {
                if paths.isEmpty {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.shield")
                                .foregroundColor(.green)
                            Text("暂无崩溃记录")
                                .font(.footnote)
                        }
                        .padding(.vertical, 8)
                    }
                } else {
                    Section(header: Text("共 \(paths.count) 条 · \(newestFirst ? "最新在前" : "最早在前")")) {
                        let displayed = newestFirst ? paths : Array(paths.reversed())
                        ForEach(displayed, id: \.self) { p in
                        Button {
                            detailItem = CrashLogItem(path: p)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: p).lastPathComponent)
                                    .font(.subheadline)
                                    .foregroundColor(.primary)
                                Text(CrashCatcher.preview(p, maxChars: 800))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(6)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("崩溃日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { paths = CrashCatcher.list() }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .foregroundColor(.white)
                    .padding(.bottom, 40)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            self.toast = nil
                        }
                    }
            }
        }
        .sheet(item: $detailItem) { item in
            CrashLogDetailView(path: item.path)
        }
        .toolbar {
            // v2.9.179：同样只复制不弹分享面板
            ToolbarItem(placement: .navigationBarLeading) {
                if !paths.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = CrashCatcher.exportAll()
                            toast = "已复制全部 \(paths.count) 条日志"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button {
                            ShareCenter.shared.presentSystemTextShare(CrashCatcher.exportAll(),
                                                                      title: "崩溃日志×\(paths.count)")
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    CrashCatcher.clear()
                    paths = []
                    toast = "已清空"
                }
                .disabled(paths.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.75))
                    .foregroundColor(.white)
                    .cornerRadius(16)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toast = nil }
                    }
            }
        }
    }
    }
}

extension String: Identifiable {
    public var id: String { self }
}

/// v6.2.7：崩溃日志详情视图——sheet(item:) 每次打开新建本视图，
/// onAppear 自行读文件（保证读到最新落盘内容），彻底修复"新日志点开空白、
/// 必须先开旧日志再开新日志才有内容"的状态残留 bug。
struct CrashLogDetailView: View {
    let path: String
    @Environment(\.dismiss) private var dismissSheet
    @State private var content: String? = nil   // nil=未加载; ""=空文件; "(读取失败)"=IO 错误
    @State private var toast: String?

    var body: some View {
        NavigationView {
            Group {
                if content == nil {
                    ProgressView()
                } else if content!.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("崩溃日志为空或无法读取")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if content == "(读取失败)" {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text("读取失败，请到工作区 crash/ 目录用文件浏览器查看")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(content!)
                            .font(.system(.footnote, design: .monospaced))
                            // v6.6.9：允许长按选中片段复制（iOS 15+）
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // v6.6.9：复制 / 分享双入口（用户反馈此前无法直接复制、也无法分享到其他 App）
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            UIPasteboard.general.string = content ?? ""
                            toast = "已复制全文 \(content?.count ?? 0) 字符"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button {
                            ShareCenter.shared.presentSystemTextShare(content ?? "",
                                                                      title: URL(fileURLWithPath: path).lastPathComponent)
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .disabled((content ?? "").isEmpty)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("完成") { dismissSheet() }
                }
            }
            .onAppear {
                content = CrashCatcher.preview(path, maxChars: 60000)
            }
            .overlay(alignment: .bottom) {
                if let toast = toast {
                    Text(toast)
                        .font(.footnote)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        .padding(.bottom, 24)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.toast = nil }
                        }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
