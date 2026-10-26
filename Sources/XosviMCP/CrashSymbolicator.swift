// CrashSymbolicator.swift — 用 dSYM 把崩溃栈帧地址还原成函数名（v6.6.27）
//
// 以前只能给出 offset（帧地址 - base），要靠开发者手工 atos 换算。
// 这里解析 dSYM 的 LC_SYMTAB 建地址索引，直接输出「函数名 + 偏移」。
//
// 关键点：dSYM 里的地址是链接期地址，必须
//   loadAddr = __TEXT.vmaddr + (frameAddr - runtimeBase)
// 直接拿 frameAddr - base 去查是错的。

import Foundation

enum CrashSymbolicator {

    struct Entry { let addr: UInt64; let name: String }

    private static var index: [Entry] = []
    private static var textVMAddr: UInt64 = 0
    private static var loadedUUID: String = ""
    /// v6.6.28：dSYM 的 LC_UUID。必须与崩溃二进制一致，否则符号全错（比没有符号更危险）
    private(set) static var uuid: String = ""

    static var isLoaded: Bool { !index.isEmpty }

    /// 载入 dSYM 里的可执行文件（*.app.dSYM/Contents/Resources/DWARF/<name>）
    @discardableResult
    static func load(dsymExecutable path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        guard let magic = u32(data, 0), magic == 0xfeedfacf else { return false }
        let ncmds = u32(data, 16) ?? 0
        var off = 32
        var symoff = 0, nsyms = 0, stroff = 0
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32(data, off), let size = u32(data, off + 4), size >= 8 else { break }
            if cmd == 0x1b {                                   // LC_UUID
                var hex = ""
                for i in 0..<16 { hex += String(format: "%02x", data[off + 8 + i]) }
                uuid = hex
            } else if cmd == 0x19 {                           // LC_SEGMENT_64
                let name = cstr(data, off + 8, 16)
                if name == "__TEXT" { textVMAddr = u64(data, off + 24) ?? 0 }
            } else if cmd == 0x2 {                             // LC_SYMTAB
                symoff = Int(u32(data, off + 8) ?? 0)
                nsyms = Int(u32(data, off + 12) ?? 0)
                stroff = Int(u32(data, off + 16) ?? 0)
            }
            off += Int(size)
        }
        guard symoff > 0, nsyms > 0, nsyms < 2_000_000 else { return false }

        var items: [Entry] = []
        items.reserveCapacity(nsyms)
        for i in 0..<nsyms {
            let base = symoff + i * 16                        // nlist_64
            guard let strx = u32(data, base), let value = u64(data, base + 8), value != 0 else { continue }
            let name = cstr(data, stroff + Int(strx), 512)
            guard !name.isEmpty else { continue }
            items.append(Entry(addr: value, name: name))
        }
        index = items.sorted { $0.addr < $1.addr }
        loadedUUID = path
        return !index.isEmpty
    }

    /// 单帧符号化；runtimeBase 来自崩溃日志的 base=
    static func symbolicate(frame: UInt64, runtimeBase: UInt64) -> String? {
        guard !index.isEmpty, frame >= runtimeBase else { return nil }
        let loadAddr = textVMAddr + (frame - runtimeBase)
        var lo = 0, hi = index.count - 1, best = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if index[mid].addr <= loadAddr { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard best >= 0 else { return nil }
        let e = index[best]
        return "\(e.name) + 0x" + String(loadAddr - e.addr, radix: 16)
    }

    static func reset() { index = []; textVMAddr = 0; loadedUUID = ""; uuid = "" }

    /// 校验 dSYM 是否对应当前二进制（大小写不敏感）
    static func matches(binaryUUID: String) -> Bool {
        !uuid.isEmpty && uuid.lowercased() == binaryUUID.lowercased()
    }

    // MARK: 小工具

    private static func u32(_ d: Data, _ o: Int) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }
    }
    private static func u64(_ d: Data, _ o: Int) -> UInt64? {
        guard o >= 0, o + 8 <= d.count else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }
    }
    private static func cstr(_ d: Data, _ o: Int, _ maxLen: Int) -> String {
        guard o >= 0, o < d.count else { return "" }
        var bytes: [UInt8] = []
        var i = o
        while i < d.count, d[i] != 0, bytes.count < maxLen { bytes.append(d[i]); i += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
