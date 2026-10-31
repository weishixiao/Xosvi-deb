import Foundation
import Darwin

/// v7.16.6：用 POSIX `lstat`/`stat` 读真实文件元数据。
///
/// 背景（2026-10-31 真机事故）：`FileManager.attributesOfItem` 在容器重定向 /
/// 越狱隐藏根（roothide）环境下会返回**错的属主与权限**——
/// 同一 inode，终端里是 `root wheel` + setuid，App 侧却是 `mobile mobile 0755`。
/// 结果 `helperIsPrivileged` 判定"没有 setuid、不能提权"，把整条提权链判死。
///
/// 规则：凡是要判断**属主 / 权限位 / setuid / inode**，一律走这里，不要用 FileManager。
/// （FileManager 仍适合读写内容、列目录。）
enum FSStat {

    struct Info {
        let path: String
        let uid: uid_t
        let gid: gid_t
        let mode: mode_t
        let size: Int64
        let inode: UInt64
        let device: UInt64

        var isDir: Bool { (mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) }
        var isSymlink: Bool { (mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) }
        var isSetuid: Bool { (mode & mode_t(S_ISUID)) != 0 }
        var isSetgid: Bool { (mode & mode_t(S_ISGID)) != 0 }
        var permOctal: String { String(mode & 0o7777, radix: 8) }
        var ownerName: String { FSStat.ownerName(uid) }
        var groupName: String { FSStat.groupName(gid) }
        var ownerDisplay: String { "\(ownerName)(\(uid))" }

        /// ls -l 风格的一句话描述
        var longLine: String {
            let t = isDir ? "d" : (isSymlink ? "l" : "-")
            return "\(t)\(permOctal) \(ownerDisplay) \(groupName) \(size)B \(path)"
        }
    }

    // MARK: - 取元数据

    /// 不跟随符号链接（判断 setuid 位要看文件本身）
    static func lstat(_ path: String) -> Info? {
        var st = Darwin.stat()
        let rc = path.withCString { Darwin.lstat($0, &st) }
        guard rc == 0 else { return nil }
        return Info(path: path,
                    uid: st.st_uid, gid: st.st_gid, mode: st.st_mode,
                    size: Int64(st.st_size),
                    inode: UInt64(st.st_ino),
                    device: UInt64(st.st_dev))
    }

    /// 跟随符号链接
    static func stat(_ path: String) -> Info? {
        var st = Darwin.stat()
        let rc = path.withCString { Darwin.stat($0, &st) }
        guard rc == 0 else { return nil }
        return Info(path: path,
                    uid: st.st_uid, gid: st.st_gid, mode: st.st_mode,
                    size: Int64(st.st_size),
                    inode: UInt64(st.st_ino),
                    device: UInt64(st.st_dev))
    }

    /// 文件是否真的可执行（用 access(2)，走真实 VFS，不走 NSFileManager 的容器视图）
    static func isExecutable(_ path: String) -> Bool {
        path.withCString { access($0, X_OK) } == 0
    }

    static func exists(_ path: String) -> Bool {
        path.withCString { access($0, F_OK) } == 0
    }

    // MARK: - 名字查询

    static func ownerName(_ uid: uid_t) -> String {
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return "\(uid)"
    }

    static func groupName(_ gid: gid_t) -> String {
        if let gr = getgrgid(gid) { return String(cString: gr.pointee.gr_name) }
        return "\(gid)"
    }

    /// 解析符号链接的真实路径（逐段，最多 12 层）
    static func resolveSymlinks(_ path: String, maxDepth: Int = 12) -> String {
        var current = (path as NSString).standardizingPath
        var depth = 0
        while depth < maxDepth {
            guard let st = lstat(current), st.isSymlink else { return current }
            guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else { return current }
            if dest.hasPrefix("/") {
                current = dest
            } else {
                current = ((current as NSString).deletingLastPathComponent as NSString).appendingPathComponent(dest)
            }
            current = (current as NSString).standardizingPath
            depth += 1
        }
        return current
    }
}
