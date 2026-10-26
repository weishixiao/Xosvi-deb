import SwiftUI
import UIKit

// MARK: - v7.11.0 控制台（把 control 的 10 个子命令做成可点操作）
//
// 原来「远程控制」页只有说明文字、「AI 控制中心」是自动流程的展示页，两个按你的要求删掉了。
// 这里补一个**真正能手动操作**的页面，把 control 的能力全部暴露出来：
//   inject / status / ui_tree / screenshot / tap / swipe / type / key（+ tap_text / type_text）

struct ControlConsoleView: View {
    @State private var bundleId = UserDefaults.standard.string(forKey: "control.lastBundle") ?? ""
    @State private var connected = false
    @State private var statusText = "未连接"
    @State private var busy = false

    // UI 树
    @State private var treeSummary = "未读取"
    @State private var treeLoading = false

    // 截图
    @State private var shot: UIImage?
    @State private var shotPath = ""

    // 输入
    @State private var tapX = ""
    @State private var tapY = ""
    @State private var swX1 = "", swY1 = "", swX2 = "", swY2 = ""
    @State private var typeText = ""

    @State private var toast: String?

    var body: some View {
        List {
            // ── 目标 ─────────────────────────────
            Section {
                HStack(spacing: 10) {
                    TextField("com.example.app", text: $bundleId)
                        .font(.system(size: 14, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(.plain)
                    Button("注入") { inject() }
                        .disabled(bundleId.isEmpty || busy)
                }
                Button {
                    checkStatus()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: connected ? "checkmark.circle" : "circle.dashed")
                            .foregroundColor(connected ? .green : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("连接状态").font(.system(size: 15)).foregroundColor(.primary)
                            Text(statusText).font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if busy { ProgressView().scaleEffect(0.7) }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            } header: {
                Text("目标 App")
            } footer: {
                Text("先点「注入」把 ControlAgent 注入目标 App，再启动它，之后才能读界面/点按。")
                    .font(.caption2)
            }

            // ── 界面 ─────────────────────────────
            Section {
                Button {
                    loadTree()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "list.bullet.indent").frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(treeLoading ? "读取中…" : "读取 UI 树").foregroundColor(.primary)
                            Text(treeSummary).font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if treeLoading { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(treeLoading || busy)

                Button {
                    screenshot()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "camera").frame(width: 24)
                        Text("截图").foregroundColor(.primary)
                        Spacer()
                        if !shotPath.isEmpty {
                            Text((shotPath as NSString).lastPathComponent)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
                if let img = shot {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            } header: {
                Text("读取")
            } footer: {
                Text("UI 树只做连通性检查，不再展开成列表；要按文字点某个元素，直接让 AI 调 control tap_text。")
                    .font(.caption2)
            }

            // ── 点按 / 滑动 ───────────────────────
            Section {
                HStack(spacing: 8) {
                    numField("X", $tapX)
                    numField("Y", $tapY)
                    Button("点按") { tapXY() }
                        .disabled(tapX.isEmpty || tapY.isEmpty || busy)
                }
            } header: {
                Text("点按坐标")
            }

            Section {
                HStack(spacing: 6) {
                    numField("x1", $swX1)
                    numField("y1", $swY1)
                    numField("x2", $swX2)
                    numField("y2", $swY2)
                }
                Button("滑动") { swipe() }
                    .disabled(swX1.isEmpty || swY1.isEmpty || swX2.isEmpty || swY2.isEmpty || busy)
            } header: {
                Text("滑动")
            }

            // ── 输入 / 按键 ───────────────────────
            Section {
                TextField("要输入的文字", text: $typeText)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                Button("输入到当前焦点") { typeInto() }
                    .disabled(typeText.isEmpty || busy)
            } header: {
                Text("输入文字")
            } footer: {
                Text("先点一下目标输入框让它获得焦点，再执行输入。")
                    .font(.caption2)
            }

            Section {
                HStack(spacing: 10) {
                    keyButton("主屏", "home")
                    keyButton("返回", "back")
                    keyButton("回车", "enter")
                }
            } header: {
                Text("按键")
            }
        }
        .navigationTitle("控制台")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if bundleId.isEmpty, let last = UserDefaults.standard.string(forKey: "control.lastBundle") {
                bundleId = last
            }
            checkStatus()
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    // MARK: 小组件

    private func numField(_ ph: String, _ binding: Binding<String>) -> some View {
        TextField(ph, text: binding)
            .font(.system(size: 13, design: .monospaced))
            .keyboardType(.numberPad)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 70)
    }

    private func keyButton(_ title: String, _ key: String) -> some View {
        Button {
            run(["command": "key", "key": key], "按键 \(key)")
        } label: {
            Text(title)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.tertiarySystemFill)))
                .foregroundColor(.primary)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(busy)
    }

    // MARK: 动作

    private func run(_ params: [String: Any], _ label: String, then: (([String: Any]) -> Void)? = nil) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = (try? ToolRegistry.shared.dispatch(name: "control", params: params)) ?? [:]
            DispatchQueue.main.async {
                busy = false
                if let err = r["error"] as? String {
                    toast = "\(label)失败：\(err)"
                } else {
                    toast = "\(label) 完成"
                    then?(r)
                }
            }
        }
    }

    private func inject() {
        UserDefaults.standard.set(bundleId, forKey: "control.lastBundle")
        run(["command": "inject", "bundle_id": bundleId], "注入")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { checkStatus() }
    }

    private func checkStatus() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = (try? ToolRegistry.shared.dispatch(name: "control", params: ["command": "status"])) ?? [:]
            DispatchQueue.main.async {
                busy = false
                connected = (r["connected"] as? Bool) ?? (r["ok"] as? Bool) ?? false
                statusText = connected
                    ? ((r["bundle_id"] as? String) ?? "已连接 ControlAgent")
                    : ((r["error"] as? String) ?? "未连接（先注入并启动目标 App）")
            }
        }
    }

    private func loadTree() {
        treeLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = (try? ToolRegistry.shared.dispatch(name: "control", params: ["command": "ui_tree"])) ?? [:]
            let items = GhostRunner.tappables(r)
            DispatchQueue.main.async {
                treeLoading = false
                if let err = r["error"] as? String {
                    treeSummary = "读取失败"
                    toast = "读取失败：\(err)"
                } else {
                    let sig = GhostRunner.screenSignature(r)
                    treeSummary = items.isEmpty
                        ? "读到了，但没有可点元素"
                        : "\(items.count) 个可点元素 · 签名 \(sig.prefix(6))"
                    toast = "UI 树读取成功"
                }
            }
        }
    }

    private func screenshot() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = (try? ToolRegistry.shared.dispatch(name: "control", params: ["command": "screenshot"])) ?? [:]
            let path = (r["path"] as? String) ?? ""
            let img = path.isEmpty ? nil : UIImage(contentsOfFile: path)
            DispatchQueue.main.async {
                busy = false
                if let err = r["error"] as? String {
                    toast = "截图失败：\(err)"
                } else {
                    shotPath = path
                    shot = img
                    toast = "已保存到工作区"
                }
            }
        }
    }

    private func tapXY() {
        guard let x = Int(tapX), let y = Int(tapY) else { toast = "坐标要填数字"; return }
        run(["command": "tap", "x": x, "y": y], "点按 (\(x),\(y))")
    }

    private func swipe() {
        guard let x1 = Int(swX1), let y1 = Int(swY1),
              let x2 = Int(swX2), let y2 = Int(swY2) else { toast = "坐标要填数字"; return }
        run(["command": "swipe", "x1": x1, "y1": y1, "x2": x2, "y2": y2], "滑动")
    }

    private func typeInto() {
        run(["command": "type", "text": typeText], "输入")
    }
}
