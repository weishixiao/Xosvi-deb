import Foundation

/// v7.1.0：联网检索默认全开、不再给用户开关。
///
/// 老版本有「搜索·开/关」胶囊，关掉后会把 web.search / web.fetch / knowledge.search
/// 从工具集里摘掉——用户升级后如果以前关过，工具就永远看不到，表现为"AI 不会联网"。
/// 这里在 App 启动时一次性把它强制成开（幂等，重复调用无副作用）。
enum SearchAlwaysOn {
    static func apply() {
        let key = "chat_smart_search"
        if UserDefaults.standard.object(forKey: key) != nil,
           UserDefaults.standard.bool(forKey: key) == false {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.set(true, forKey: key)
        }
    }
}
