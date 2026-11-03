import SwiftUI

// MARK: - v8.4 删除说明：会话记录功能整体移除
//
// 旧 ConversationTranscriptView（当前会话的只读存档 + Markdown 导出）按需求删除：
// 聊天页本身可见全部历史，独立存档页冗余；设置页入口已一并移除。
//
// 原视图被删后，另外两个视图还引用它的 `tf`（静态 DateFormatter）做时间格式化——
// 这里保留同格式 formatter 供它们使用（不重新实现导出/存档逻辑）。

enum TranscriptTimeFormat {
    static let tf: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()
}
