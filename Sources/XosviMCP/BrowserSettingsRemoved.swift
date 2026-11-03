// MARK: - v8.4 删除说明：浏览器设置页未实现
//
// 文档主题 4（BrowserSettingsView 重构）经核实**无对应功能**：v7.5.0 内置浏览器已整体
// 删除（SettingsView.swift 注释留档："内置浏览器已删除；改为「联网搜索」"）。
// 现存 WorkspaceBrowserView 是工作区文件浏览器、AppBrowserTableUIKit 是 App 列表，
// 都不是"网页浏览器"，没有引擎/UA/缓存可配置项——文档基于旧快照视角，无需改动。
// 如将来恢复网页浏览器，再按 deepseekList 风格补此页。
