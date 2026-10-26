import SwiftUI
import UIKit
import Combine

/// v6.6.9：iSH 终端界面（移植自 OpenMinis `ISHTerminalView`，对接 Xosvi `TerminalSession`）。
/// 组成：
///   - TerminalCanvasView：CoreText 渲染的终端画布（滚动 / 选择 / 复制）
///   - TerminalInputView：隐藏的键盘捕获层（含 Ctrl / 方向键 / 特殊键映射）
///   - TerminalKeyboardAccessory：贴键盘的快捷键栏
///   - TerminalEmulator：ANSI 解析 + 屏幕缓冲（OpenMinis 原版移植）
struct ISHTerminalView: View {
    var showCloseButton: Bool = true
    /// v6.6.11：启动后自动 cd /root（root 权限文件夹）
    var autoCdRoot: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = TerminalViewModel()
    @State private var ctrlActive = false
    @State private var keyboardActive = true
    @State private var softwareKeyboardVisible = false
    @State private var errorText: String?

    var body: some View {
        ZStack(alignment: .top) {
            TerminalCanvasView(
                emulator: vm.emulator,
                onResize: { cols, rows in vm.handleResize(cols: cols, rows: rows) },
                onPaste: { data in vm.sendInput(data) },
                onTap: {
                    if softwareKeyboardVisible {
                        keyboardActive = false
                    } else if keyboardActive {
                        keyboardActive = false
                        DispatchQueue.main.async { keyboardActive = true }
                    } else {
                        keyboardActive = true
                    }
                },
                onDoubleTap: {
                    vm.sendInput(Data([0x09]))   // Tab
                }
            )

            TerminalInputView(
                onInput: { data in vm.sendInput(data) },
                applicationCursorKeys: vm.emulator.applicationCursorKeys,
                isActive: $keyboardActive,
                ctrlActive: $ctrlActive,
                isTerminalVisible: true
            )
            .frame(width: 1, height: 1)
            .opacity(0)

            if let err = errorText {
                Text(err)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
        }
        .ignoresSafeArea(.keyboard)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TerminalKeyboardAccessory(
                onInput: { data in vm.sendInput(data) },
                ctrlActive: $ctrlActive,
                onShowFileBrowser: { },
                onShowRootfsManagement: { },
                keyboardActive: $keyboardActive,
                softwareKeyboardVisible: softwareKeyboardVisible,
                onPaste: {
                    guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
                    vm.sendInput(Data(text.utf8))
                }
            )
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(vm.emulator.title.isEmpty ? "终端" : vm.emulator.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // v6.6.10：条件必须放在 ToolbarItem 内部——ToolbarContentBuilder 的 if 需要 iOS 16，
            // 项目部署目标是 iOS 15，否则报 'buildIf' is only available in iOS 16.0 or newer。
            ToolbarItem(placement: .navigationBarLeading) {
                if showCloseButton {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { vm.clearScreen() } label: { Label("清屏", systemImage: "paintbrush") }
                    Button { vm.restart() } label: { Label("重启 Shell", systemImage: "arrow.clockwise") }
                    Button {
                        UIPasteboard.general.string = vm.exportText()
                    } label: { Label("复制全部输出", systemImage: "doc.on.doc") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            if let err = vm.start(autoCdRoot: autoCdRoot) {
                errorText = err
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            softwareKeyboardVisible = true
            keyboardActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            softwareKeyboardVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            keyboardActive = true
        }
    }
}

// MARK: - ViewModel

/// v6.6.9：终端 ViewModel——把 TerminalSession 的输出喂给 TerminalEmulator，
/// 把键盘输入写回 shell 的 stdin。
final class TerminalViewModel: ObservableObject {
    let emulator = TerminalEmulator()
    private let session = TerminalSession()
    private var started = false
    private var pendingCols = 80
    private var pendingRows = 24
    /// 本地回显开关（无 tty 时 shell 不自带回显）
    var localEchoEnabled = true

    /// 启动 shell；返回错误文案（nil = 成功）
    /// - Parameter autoCdRoot: 启动后自动执行 `cd /root`（用户要求：终端默认落在 root 目录）
    func start(autoCdRoot: Bool = false) -> String? {
        guard !started else { return nil }

        // 输出合批：iSH 的 read 会以 4–24 字节小碎片高频回调，
        // 每个碎片都 feed 会打爆主队列。攒到主队列下一轮再一次性 feed。
        let lock = NSLock()
        var pending = Data()
        session.onOutput = { [weak self] chunk in
            guard let self else { return }
            lock.lock()
            let wasEmpty = pending.isEmpty
            pending.append(chunk)
            lock.unlock()
            guard wasEmpty else { return }
            DispatchQueue.main.async {
                lock.lock()
                let drained = pending
                pending.removeAll(keepingCapacity: true)
                lock.unlock()
                guard !drained.isEmpty else { return }
                self.emulator.feed(drained)
            }
        }

        // 终端回写（DSR 光标查询应答等），否则 gh 等 TUI 会一直等
        emulator.onResponse = { [weak self] data in
            self?.session.send(data)
        }

        session.onExit = { [weak self] code in
            guard let self else { return }
            let msg = "\r\n[进程已退出 exit=\(code)] 点右上角 ⋯ → 重启 Shell\r\n"
            self.emulator.feed(Data(msg.utf8))
        }

        if let err = session.start(cols: pendingCols, rows: pendingRows) {
            return err
        }
        started = true
        // v6.6.11：shell 就绪后自动进入 /root（HOME 已是 /root，但 cwd 仍是 /）
        // v6.6.12：启动后先清屏，抹掉 "can't access tty; job control turned off" 噪声
        let initCmd = autoCdRoot ? "cd /root && clear\n" : "clear\n"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.session.send(initCmd)
        }
        return nil
    }

    func sendInput(_ data: Data) {
        // v6.6.12：Ctrl+C 在无 tty 下不会触发 SIGINT（0x03 只是普通字节），
        // 客户端直接给 guest 发信号，否则用户按 Ctrl+C 完全没反应。
        if data.count == 1 && data[0] == 0x03 {
            session.signal(SIGINT)
            localEcho("^C\r\n")
            return
        }
        session.send(data)
        localEcho(data)
    }

    /// v6.6.12：本地回显。
    /// cish_spawn 只接了管道、没有伪终端，shell 启动时明确报
    /// "can't access tty; job control turned off" 且**不回显输入**——
    /// 用户看不到自己打的字。这里在客户端补回显（等价于传统终端的 local echo）。
    /// 已知边界：程序自身也会输出时可能出现短暂的重复显示（如 read/echo），可接受。
    func localEcho(_ data: Data) {
        guard localEchoEnabled else { return }
        var out = Data()
        for b in data {
            switch b {
            case 0x7F:                       // 退格
                out.append(contentsOf: [0x08, 0x20, 0x08])
            case 0x0D:                       // 回车
                out.append(contentsOf: [0x0D, 0x0A])
            case 0x0A:                       // 换行（避免 CRLF 重复换行）
                out.append(contentsOf: [0x0D, 0x0A])
            case 0x00..<0x20:                // 其他控制字符不回显
                break
            default:
                out.append(b)                // 可打印 ASCII / UTF-8 多字节原样
            }
        }
        if !out.isEmpty { emulator.feed(out) }
    }

    private func localEcho(_ text: String) {
        localEcho(Data(text.utf8))
    }

    func handleResize(cols: Int, rows: Int) {
        pendingCols = cols
        pendingRows = rows
        emulator.resize(cols: cols, rows: rows)
    }

    func clearScreen() {
        // ED(2) 清屏 + CUP 归位
        emulator.feed(Data([0x1B, 0x5B, 0x32, 0x4A, 0x1B, 0x5B, 0x48]))
    }

    func restart() {
        session.stop()
        started = false
        emulator.feed(Data("\r\n[重启 Shell]\r\n".utf8))
        _ = start()
    }

    /// 导出当前可见缓冲文本（不含颜色）
    func exportText() -> String {
        var lines: [String] = []
        for row in emulator.visibleLines() {
            var s = ""
            for cell in row {
                s.append(cell.character)
            }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    deinit {
        session.stop()
    }
}


// MARK: - 快捷键按钮（移植自 OpenMinis ISHTerminalView.swift）

/// 终端键盘附件栏的单个按键
struct QuickCommandButton: View {
    let label: String
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption)
                Text(label).font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.blue : Color(white: 0.25))
            .foregroundColor(isActive ? .white : .green)
            .cornerRadius(6)
        }
    }
}
