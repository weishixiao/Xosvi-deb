import SwiftUI

// MARK: - v7.6.3 Color(hex:) 工具（项目内此前没有，LiteLLM 供应商色板需要）

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            let r = String(s[s.startIndex])
            let g = String(s[s.index(s.startIndex, offsetBy: 1)])
            let b = String(s[s.index(s.startIndex, offsetBy: 2)])
            s = r + r + g + g + b + b
        }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
