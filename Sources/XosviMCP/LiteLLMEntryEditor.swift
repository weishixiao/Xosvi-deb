import SwiftUI

// MARK: - v7.6.3 单条 deployment 编辑器
//
// 对齐 litellm deployment 字段：模型组名 / provider / 协议 / baseURL / key / weight / priority / rpm / tpm
// 保存时把 ModelEntry 交回调用方。

struct LiteLLMEntryEditor: View {
    @State private var entry: ModelEntry
    var onDone: (ModelEntry) -> Void
    var onCancel: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var showKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var fetchModels = false

    init(entry: ModelEntry, onDone: @escaping (ModelEntry) -> Void, onCancel: @escaping () -> Void) {
        _entry = State(initialValue: entry)
        self.onDone = onDone
        self.onCancel = onCancel
    }

    private var provider: LiteLLMProvider? { LiteLLMProvider.find(entry.provider) }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("模型组名（同名=同一模型的多个部署）", text: $entry.modelName)
                    HStack {
                        Text("供应商")
                        Spacer()
                        Text(provider?.name ?? entry.provider)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("模型")
                } footer: {
                    Text("\(entry.provider)/\(entry.modelName)")
                        .font(.system(size: 11, design: .monospaced))
                }

                Section("接入") {
                    TextField("Base URL", text: $entry.baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    HStack {
                        if showKey {
                            TextField("API Key", text: $entry.apiKey)
                                .autocapitalization(.none)
                        } else {
                            SecureField("API Key", text: $entry.apiKey)
                        }
                        Button(action: { showKey.toggle() }) {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    Picker("鉴权方式", selection: $entry.authMethod) {
                        ForEach(["Bearer", "x-api-key", "api-key", "Query key", "Body api_key", "None"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }

                    Picker("协议", selection: $entry.apiProtocol) {
                        ForEach(["OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages",
                                 "Gemini", "Bedrock", "Custom Endpoint"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                }

                Section("路由参数") {
                    Stepper(value: $entry.weight, in: 1...10) {
                        HStack {
                            Text("权重")
                            Spacer()
                            Text("\(entry.weight)").foregroundColor(.secondary)
                        }
                    }
                    Stepper(value: $entry.priority, in: 1...999) {
                        HStack {
                            Text("优先级")
                            Spacer()
                            Text("\(entry.priority)").foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        Text("RPM 上限")
                        Spacer()
                        TextField("0=不限", value: $entry.rpm, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    HStack {
                        Text("TPM 上限")
                        Spacer()
                        TextField("0=不限", value: $entry.tpm, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }

                Section("采样") {
                    HStack {
                        Text("temperature")
                        Slider(value: $entry.temperature, in: 0...2, step: 0.05)
                        Text(String(format: "%.2f", entry.temperature))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 40)
                    }
                    HStack {
                        Text("max_tokens")
                        Spacer()
                        TextField("4096", value: $entry.maxTokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Text("context 预算")
                        Spacer()
                        TextField("32000", value: $entry.contextTokens, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                }

                Section {
                    Toggle("设为默认模型组", isOn: $entry.isDefault)
                }

                if let r = testResult {
                    Section {
                        Text(r)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(r.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
            .navigationTitle("Deployment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        onCancel()
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        onDone(entry)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(entry.modelName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
