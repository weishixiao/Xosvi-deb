import SwiftUI

// MARK: - v7.10.0 技能回放（设置 → 技能回放）
//
// 列表 = Workspace/ghost-skills/*.json。每行显示名字、步数、上次结果，点一下就能回放；
// 底部是"扫描当前 App"（BFS 探索）和"从当前界面生成技能骨架"。

struct GhostSkillsView: View {
    @State private var skills: [GhostSkill] = []
    @State private var running: UUID?
    @State private var result: (id: UUID, ok: Bool, text: String)?
    @State private var exploring = false
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                if skills.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有技能").font(.system(size: 15))
                        Text("让 AI「把刚才那套操作存成技能」，或用下面的按钮生成骨架。")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(skills) { s in
                    Button {
                        play(s)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: running == s.id ? "hourglass" : "play.circle")
                                .font(.system(size: 18))
                                .foregroundColor(.primary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 15))
                                Text(subtitle(s))
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if running == s.id { ProgressView().scaleEffect(0.7) }
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            GhostSkillStore.shared.delete(s.id)
                            reload()
                        } label: { Label("删除技能", systemImage: "trash") }
                    }
                }
            } header: {
                Text("技能")
            } footer: {
                Text("回放不调用模型——已知流程秒级重放，不花 token。长按可删除。")
                    .font(.caption2)
            }

            Section {
                Button {
                    explore()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.3x3").frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("扫描当前 App 界面")
                                .font(.system(size: 15)).foregroundColor(.primary)
                            Text("从当前界面出发，逐个点按记录可跳转的页面")
                                .font(.system(size: 11.5)).foregroundColor(.secondary)
                        }
                        Spacer()
                        if exploring { ProgressView().scaleEffect(0.7) }
                    }
                }
                .disabled(exploring)
            } header: {
                Text("探索")
            } footer: {
                Text("扫描会真的点按目标 App，可能产生副作用（发消息/下单）。先保证目标 App 在前台且已注入 ControlAgent。")
                    .font(.caption2)
            }

            if let r = result {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: r.ok ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(r.ok ? .secondary : .red)
                        Text(r.ok ? "回放完成" : "回放失败")
                            .font(.system(size: 13))
                    }
                    Text(r.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.secondary)
                } header: {
                    Text("上次结果")
                }
            }
        }
        .navigationTitle("技能回放")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
    }

    private func subtitle(_ s: GhostSkill) -> String {
        var parts = ["\(s.steps.count) 步"]
        if let b = s.bundleId, !b.isEmpty { parts.append(b) }
        if let r = s.lastResult { parts.append(r) }
        return parts.joined(separator: " · ")
    }

    private func reload() {
        skills = GhostSkillStore.shared.list()
    }

    private func play(_ s: GhostSkill) {
        guard running == nil else { return }
        running = s.id
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let r = GhostRunner.run(s)
            var updated = s
            updated.runs += 1
            updated.lastResult = r.ok ? "成功（\(r.steps.count) 步）" : "失败：\(r.error ?? "")"
            GhostSkillStore.shared.save(updated)

            let lines = r.steps.map { "\($0.index). \($0.action)\($0.ok ? " ✓" : " ✗") \($0.detail) (\($0.ms)ms)" }
            let text = (r.error.map { "错误：\($0)\n" } ?? "") + lines.joined(separator: "\n")

            DispatchQueue.main.async {
                running = nil
                result = (s.id, r.ok, text)
                reload()
            }
        }
    }

    private func explore() {
        guard !exploring else { return }
        exploring = true
        DispatchQueue.global(qos: .userInitiated).async {
            let tool = GhostTool()
            let r = (try? tool.invoke(["command": "explore", "max_screens": 15, "max_depth": 3])) ?? [:]
            DispatchQueue.main.async {
                exploring = false
                if let e = r["error"] as? String {
                    toast = e
                } else {
                    let n = r["screens"] as? Int ?? 0
                    let m = r["edges"] as? Int ?? 0
                    toast = "扫描完成：\(n) 个界面 / \(m) 条跳转"
                }
            }
        }
    }
}
