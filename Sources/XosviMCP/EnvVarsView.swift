// EnvVarsView.swift — 设置 → 环境变量（v6.6.19）

import SwiftUI

struct EnvVarsView: View {
    @ObservedObject private var store = EnvVarsStore.shared
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var revealed: Set<String> = []
    @State private var errorMsg: String?

    var body: some View {
        Form {
            Section(header: Text("已配置（\(store.vars.count)）"),
                    footer: Text("这些变量会注入：所有子进程（python3/r2/bsdtar…）与进程内 Python（py 工具）。已运行的解释器需重新 eval 才生效。")) {
                if store.sortedKeys.isEmpty {
                    Text("还没有环境变量").foregroundColor(.secondary)
                }
                ForEach(store.sortedKeys, id: \.self) { key in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.system(.body, design: .monospaced))
                            Text(revealed.contains(key) ? (store.vars[key] ?? "") : "••••••")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button {
                            if revealed.contains(key) { revealed.remove(key) } else { revealed.insert(key) }
                        } label: {
                            Image(systemName: revealed.contains(key) ? "eye.slash" : "eye")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                }
                .onDelete { idx in
                    for i in idx { store.remove(store.sortedKeys[i]) }
                }
            }

            Section(header: Text("新增"), footer: Text("名称只能是字母/数字/下划线，且不以数字开头（大小写敏感）。")) {
                TextField("名称，如 HTTP_PROXY", text: $newKey)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                TextField("值", text: $newValue)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                Button {
                    addVar()
                } label: {
                    Label("添加", systemImage: "plus.circle.fill")
                }
                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if let e = errorMsg {
                    Text(e).font(.caption).foregroundColor(.red)
                }
            }
        }
        .navigationTitle("环境变量")
    }

    private func addVar() {
        let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            errorMsg = "名称不合法：只能是字母、数字、下划线，且不能以数字开头"
            return
        }
        store.set(newValue, for: k)
        newKey = ""
        newValue = ""
        errorMsg = nil
    }
}
