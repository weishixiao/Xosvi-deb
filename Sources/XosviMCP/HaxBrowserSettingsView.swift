import SwiftUI

// MARK: - v7.3.0 浏览器设置页（原「Hax 电脑」页删除后，浏览器独立成一项）

/// 设置 → 工具与管理 → 浏览器
///
/// 原来这些开关挂在「Hax 电脑」页里；随着引擎/终端/文件浏览一并删除，
/// 这里只保留浏览器自己的东西：搜索引擎、桌面版开关、清数据，加一个全屏入口。
struct HaxBrowserSettingsView: View {
    @ObservedObject private var browser = HaxBrowser.shared
    @State private var toast: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("默认引擎")
                    Spacer()
                    Picker("", selection: Binding(
                        get: { browser.engine },
                        set: { browser.engine = $0 }
                    )) {
                        ForEach(HaxSearchEngine.fallbackOrder) { e in
                            Text(e.displayName).tag(e)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: Binding(
                    get: { browser.desktopMode },
                    set: { browser.desktopMode = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("请求桌面版页面")
                        Text("搜索结果页移动版结构常变，桌面版更稳")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("搜索引擎")
            } footer: {
                Text("百度为默认引擎；结果为空时自动换必应 / 搜狗 / 360 / Google / DuckDuckGo。")
                    .font(.caption2)
            }

            Section {
                NavigationLink {
                    HaxBrowserFullView()
                } label: {
                    Label("打开浏览器", systemImage: "globe")
                }

                Button {
                    browser.load("https://www.baidu.com")
                    toast = "已打开百度首页"
                } label: {
                    Label("回到首页（百度）", systemImage: "house")
                }

                Button(role: .destructive) {
                    browser.clearCookies()
                    toast = "已清除浏览数据"
                } label: {
                    Label("清除浏览数据（Cookie / 缓存）", systemImage: "trash")
                }
            } header: {
                Text("操作")
            }

            Section {
                HStack {
                    Text("当前页面")
                    Spacer()
                    Text(browser.pageTitle.isEmpty ? "（未打开）" : browser.pageTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !browser.currentURL.isEmpty {
                    Text(browser.currentURL)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            } header: {
                Text("状态")
            } footer: {
                Text("AI 思考、查资料时会自己用这个浏览器搜索，页面是真实渲染的，你能看到它每一步在做什么。")
                    .font(.caption2)
            }
        }
        .navigationTitle("浏览器")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast = toast {
                Text(toast)
                    .font(.footnote)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .foregroundColor(.white)
                    .padding(.bottom, 20)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { self.toast = nil }
                        }
                    }
            }
        }
    }
}
