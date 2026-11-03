import SwiftUI
import UIKit

// MARK: - v9：输入框顶部状态条（余额胶囊 + 模型胶囊）
//
// 文档第三节：金额显示在输入框上方那条「工具条」区域，点一下刷新，长按看详情。
// 形态 A（胶囊）——最省空间，也是文档推荐的默认形态。
//
// 行为约束（文档第七节）：
//   · 不在 body 里查余额（网络请求会每帧触发）→ onAppear / onChange / 请求完成通知
//   · 失败静默：只显示「余额 ?」灰胶囊，长按才看原因
//   · 缓存 5 分钟（BalanceChecker 内），切模型 / 请求完成时 force 刷新

struct BalanceChipBar: View {
    /// 当前生效的模型配置
    let config: ModelConfig?

    @State private var balance: BalanceInfo?
    @State private var errorText: String?
    @State private var querying = false
    @State private var hidden = false
    @State private var copied = false

    var body: some View {
        if let cfg = config, !hidden {
            HStack(spacing: 8) {
                modelChip(cfg)
                balanceChip
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .onAppear { refresh() }
            .onChange(of: cfg.id) { _ in refresh(force: true) }
            .onReceive(NotificationCenter.default.publisher(for: .xosviRequestFinished)) { note in
                // 只刷新「刚刚真正发过请求」的那个配置，别被别的会话的请求带跑
                let id = (note.userInfo?["configID"] as? String) ?? ""
                if id.isEmpty || id == cfg.id.uuidString { refresh(force: true) }
            }
        }
    }

    // MARK: 模型胶囊

    private func modelChip(_ cfg: ModelConfig) -> some View {
        Menu {
            ForEach(ModelStore.shared.configs) { m in
                Button {
                    var c = m
                    c.isDefault = true
                    ModelStore.shared.update(c)
                    ModelStore.shared.markUsed(m.id.uuidString)
                } label: {
                    if m.id == cfg.id {
                        Label(m.name, systemImage: "checkmark")
                    } else {
                        Text(m.name)
                    }
                }
            }
            Divider()
            Button {
                hidden = true
            } label: { Label("隐藏余额", systemImage: "eye.slash") }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(cfg.isDefault ? DoubaoTheme.accent : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(cfg.name)
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(DoubaoTheme.card))
            .overlay(Capsule().strokeBorder(DoubaoTheme.hairline, lineWidth: 0.6))
        }
    }

    // MARK: 余额胶囊

    @ViewBuilder
    private var balanceChip: some View {
        if let b = balance {
            Button { refresh(force: true) } label: {
                HStack(spacing: 4) {
                    if querying {
                        ProgressView().scaleEffect(0.45).frame(width: 9, height: 9)
                    } else {
                        Image(systemName: "creditcard")
                            .font(.system(size: 9, weight: .medium))
                    }
                    Text(copied ? "已复制" : b.text)
                        .font(.system(size: 11.5, design: .monospaced))
                    if b.isLow {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                    }
                }
                .foregroundColor(b.isLow ? .orange : .secondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(DoubaoTheme.card))
                .overlay(Capsule().strokeBorder(
                    b.isLow ? Color.orange.opacity(0.4) : DoubaoTheme.hairline,
                    lineWidth: 0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                Button { refresh(force: true) } label: {
                    Label("刷新余额", systemImage: "arrow.clockwise")
                }
                Button { copy(b) } label: { Label("复制", systemImage: "doc.on.doc") }
                if let d = b.detail {
                    Button { UIPasteboard.general.string = d } label: {
                        Label(d, systemImage: "info.circle")
                    }
                }
                Button { hidden = true } label: { Label("隐藏", systemImage: "eye.slash") }
            }
        } else if errorText != nil {
            Button { refresh(force: true) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "creditcard").font(.system(size: 9))
                    Text(querying ? "查询中…" : "余额 ?").font(.system(size: 11.5))
                }
                .foregroundColor(.secondary.opacity(0.7))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(DoubaoTheme.card))
                .overlay(Capsule().strokeBorder(DoubaoTheme.hairline, lineWidth: 0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                if let e = errorText { Text(e) }
                Button { refresh(force: true) } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                Button { hidden = true } label: { Label("隐藏", systemImage: "eye.slash") }
            }
        } else if querying {
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.45).frame(width: 9, height: 9)
                Text("查询中").font(.system(size: 11.5)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(DoubaoTheme.card))
        }
    }

    // MARK: 动作

    private func refresh(force: Bool = false) {
        guard let cfg = config else { return }
        if !force, let c = BalanceChecker.shared.cached(cfg.id) {
            balance = c
            errorText = nil
            return
        }
        if BalanceChecker.shared.isQuerying(cfg.id) { querying = true; return }
        querying = true
        BalanceChecker.shared.check(cfg, force: force) { result in
            querying = false
            switch result {
            case .success(let info):
                balance = info
                errorText = nil
            case .failure(let e):
                // 失败静默：有旧值就留着旧值，没有才显示「余额 ?」
                if balance == nil { errorText = e.description }
            }
        }
    }

    private func copy(_ b: BalanceInfo) {
        UIPasteboard.general.string = b.text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - 额度换算设置行（文档第五节）

struct QuotaPerUnitRow: View {
    @AppStorage("xosvi.quota_per_unit") private var quotaPerUnit: Double = 500_000
    @AppStorage("xosvi.newapi_user_id") private var newAPIUserID: String = ""
    @State private var unitText: String = ""
    @State private var uidText: String = ""

    var body: some View {
        Group {
            HStack {
                Text("额度换算")
                Spacer()
                TextField("500000", text: $unitText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                    .onAppear { unitText = String(Int(quotaPerUnit)) }
                    .onChange(of: unitText) { v in
                        if let d = Double(v), d > 0 { quotaPerUnit = d }
                    }
                Text("单位 = $1")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            HStack {
                Text("New-Api-User")
                Spacer()
                TextField("可选，用户 ID", text: $uidText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 130)
                    .onAppear { uidText = newAPIUserID }
                    .onChange(of: uidText) { v in newAPIUserID = v }
            }
        }
    }
}
