import SwiftUI

// MARK: - v7.8.0 深度思考设置（移植 Kelivo 的 reasoning 配置）
//
// 每个模型单独一套：方言（思考强度用什么字段表达）、采样策略、思考回传、自定义 token 预算。

struct ReasoningSettingsView: View {
    @State private var selectedModel: String = ""
    @State private var spec = ReasoningSpec()
    /// v8.1：深度思考专用模型选择（"" = 跟随当前模型）
    @State private var deepThinkSelection: String = ReasoningSettings.shared.deepThinkModelIdRaw ?? ""

    private var models: [ModelConfig] { ModelStore.shared.configs }

    var body: some View {
        List {
            Section {
                if models.isEmpty {
                    Text("还没有配置模型").foregroundColor(.secondary)
                } else {
                    Picker("模型", selection: $selectedModel) {
                        ForEach(models) { m in
                            Text(m.name).tag(m.model)
                        }
                    }
                    .onChange(of: selectedModel) { _ in load() }
                }
            } header: {
                Text("选择模型")
            } footer: {
                Text("不同模型接受的思考参数不一样。Claude 用 thinking.budget_tokens，Gemini 用 thinkingConfig，OpenAI 用 reasoning_effort，这里可以逐个指定。")
                    .font(.caption2)
            }

            // v7.15.3：自我精炼改为显式开关（默认关）。开着等于每条长回答都多发一次
            // 完整 LLM 请求并把第二次结果追加到同一条消息，成本翻倍且难以预期。
            Section {
                Toggle("回答后自动精炼", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "chat_auto_refine") },
                    set: { UserDefaults.standard.set($0, forKey: "chat_auto_refine") }
                ))
            } header: {
                Text("回答质量")
            } footer: {
                Text("开启后，长回答（>120 字）且思考开启时，会再请求一次模型做「批判 → 改进」，把改进内容追加到同一条消息末尾。会增加约一倍 token 消耗。")
                    .font(.caption2)
            }

            // v8.1：深度思考专用模型——跟随当前模型（默认）或手动锁定某个配置。
            // 动态解析方案：请求时才解析用哪个配置，切换当前模型无需重新配置。
            Section {
                Picker("深度思考模型", selection: $deepThinkSelection) {
                    Text("跟随当前模型（自动）").tag("")
                    ForEach(models) { m in
                        Text(m.name).tag(m.id.uuidString)
                    }
                }
                if deepThinkSelection.isEmpty {
                    Text("深度思考将自动使用你当前选中的模型；切换模型时无需重新配置。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("已锁定指定模型，不再跟随当前模型切换。")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } header: {
                Text("专用模型")
            } footer: {
                Text("上面逐模型的参数方言按「模型名」生效；这里只决定深度思考请求发给哪个配置。")
                    .font(.caption2)
            }

            if !selectedModel.isEmpty {
                Section {
                    Picker("方言", selection: $spec.dialect) {
                        ForEach(ReasoningDialect.allCases, id: \.self) { d in
                            Text(d.displayName).tag(d)
                        }
                    }
                    Toggle("支持思考", isOn: $spec.supportsReasoning)
                } header: {
                    Text("参数方言")
                } footer: {
                    Text(spec.dialect == .none
                         ? "当前模型被标记为不支持思考，不会发送任何思考参数。"
                         : "默认按模型名自动推断，选错了会导致请求被拒，可按服务商文档修改。")
                        .font(.caption2)
                }

                Section {
                    Picker("采样参数", selection: $spec.sampling) {
                        ForEach(SamplingPolicy.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                } header: {
                    Text("采样策略")
                } footer: {
                    Text("很多推理模型开启思考后不接受 temperature / top_p，会直接返回 400。「仅在思考关闭时」会把它们自动去掉。")
                        .font(.caption2)
                }

                Section {
                    Picker("思考回传", selection: $spec.replay) {
                        ForEach(ReasoningReplayPolicy.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    if spec.replay != .none {
                        Picker("回传字段", selection: $spec.replayField) {
                            ForEach(ReasoningReplayField.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                    }
                } header: {
                    Text("多轮回传")
                } footer: {
                    Text("Claude 的工具轮必须把 thinking 块带回去，否则下一轮请求会被拒——这类模型请选「仅工具轮」。")
                        .font(.caption2)
                }

                Section {
                    ForEach([ReasoningLevel.minimal, .low, .medium, .high, .xhigh, .max], id: \.self) { lv in
                        HStack {
                            Text(lv.displayName)
                            Spacer()
                            TextField("默认 \(lv.defaultBudget ?? 0)",
                                      value: Binding(
                                        get: { spec.budgets[lv.rawValue] ?? lv.defaultBudget ?? 0 },
                                        set: { spec.budgets[lv.rawValue] = $0 }
                                      ),
                                      format: .number)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                                .foregroundColor(.secondary)
                            Text("tokens").font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    Button("恢复默认值") { spec.budgets = [:] }
                } header: {
                    Text("Token 预算")
                } footer: {
                    Text("「最高 / 极限」到底是多少由这里决定。Claude 要求至少 1024，且必须小于 max_tokens。")
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("深度思考")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selectedModel.isEmpty { selectedModel = models.first?.model ?? "" }
            load()
        }
        .onChange(of: spec) { newValue in
            guard !selectedModel.isEmpty else { return }
            let proto = models.first { $0.model == selectedModel }?.apiProtocol ?? "OpenAI Chat Completions"
            ReasoningSettings.shared.setSpec(newValue, for: selectedModel, protocol: proto)
        }
        // v8.1：深度思考专用模型选择落库（"" → nil = 跟随当前模型）
        .onChange(of: deepThinkSelection) { v in
            ReasoningSettings.shared.deepThinkModelIdRaw = v.isEmpty ? nil : v
        }
    }

    private func load() {
        guard !selectedModel.isEmpty else { return }
        let proto = models.first { $0.model == selectedModel }?.apiProtocol ?? "OpenAI Chat Completions"
        spec = ReasoningSettings.shared.spec(for: selectedModel, protocol: proto)
    }
}
