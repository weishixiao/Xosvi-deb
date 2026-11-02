import Foundation

// MARK: - v8.3（P1）：spawn 失败按 errno 分类
//
// 旧实现把所有失败都归结为「越狱拦截（ENOSYS 85）」并写进 UserDefaults，
// 之后所有 App 内二进制都被提前短路——包括本来能跑的 jq / python3 / bsdtar。
// 实测：ENOENT(2) 是路径写错，ENOEXEC(8) 是把 .dylib/.a 当程序跑，EACCES(13) 是权限位，
// 只有 ENOSYS(85) 才是内核/越狱策略拦截。

enum SpawnFailure: String {
    case pathNotFound = "ENOENT"
    case notExecutable = "ENOEXEC"
    case permissionDenied = "EACCES"
    case blocked = "ENOSYS"
    case other = "OTHER"

    /// 是否属于「重试无意义」的拦截
    var retryUseless: Bool { self == .blocked }
}

enum SpawnClassifier {
    static func classify(_ errno: Int32, path: String) -> (SpawnFailure, String) {
        switch errno {
        case 2:
            return (.pathNotFound,
                    "路径不存在：\(path)。请用绝对路径（Bundle.main.bundlePath + \"/bin/…\"），不要依赖 PATH。")
        case 8:
            return (.notExecutable,
                    "不是可执行文件：\(path)。.dylib / .a / 架构不符都不能 exec；请改用对应 MCP 工具。")
        case 13:
            return (.permissionDenied,
                    "无执行权限：\(path)。检查 mode 是否 0755、属主是否正确。")
        case 85:
            return (.blocked,
                    "该二进制确实被内核策略拦（ENOSYS 85）：\(path)。仅此一种情况需要走进程内方案。")
        default:
            return (.other, "spawn 失败 errno=\(errno)：\(path)")
        }
    }

    /// 读 Mach-O 头，判断是否为可执行文件（MH_EXECUTE）
    static func isExecutableMachO(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 28), head.count >= 28 else { return false }
        let magicLE = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // 0xfeedfacf = MH_MAGIC_64（小端宿主上直接读即此值）；0xcffaedfe = 大端存储
        guard magicLE == 0xfeedfacf || magicLE == 0xcffaedfe || magicLE == 0xfeedface else { return false }
        let ftBig = head.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
        let ft = (magicLE == 0xcffaedfe) ? ftBig.byteSwapped : ftBig
        return ft == 0x2   // MH_EXECUTE
    }
}
