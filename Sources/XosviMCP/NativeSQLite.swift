// NativeSQLite.swift — 进程内读 App 数据库（v6.6.22）
//
// 背景：`db` 工具原来三个子命令全部 `ISHEngine.exec("sqlite3 …")`，
// iSH 一坏这个能力就整体消失；而"穿透沙盒读库"恰恰是最常用的取证步骤。
// 这里改用系统自带的 libsqlite3（CISH 已链接 sqlite3）在进程内只读打开。
//
// 两个正确性要点：
//   1) WAL：只读主库会看到旧快照，新数据在 .db-wal 里 —— 小库整组拷出来再读。
//   2) 运行中的库可能被加锁 —— 只读打开 + query_only，失败再退回拷贝。

import Foundation
import SQLite3

private let SQLITE_TRANSIENT_SHIM = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum NativeSQLite {

    struct Table {
        var columns: [String] = []
        var rows: [[String]] = []
    }

    /// 拷贝 db + -wal + -shm 到临时目录，避免读到旧快照 / 被锁
    static func snapshotCopy(_ path: String, maxBytes: Int64 = 256 * 1024 * 1024) -> String? {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int64, size <= maxBytes else {
            return nil   // 太大就不拷，直接只读打开
        }
        let tmp = NSTemporaryDirectory() + "/dbcopy_\(UUID().uuidString).sqlite"
        do {
            try fm.copyItem(atPath: path, toPath: tmp)
            for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try? fm.copyItem(atPath: path + suffix, toPath: tmp + suffix)
            }
            return tmp
        } catch {
            return nil
        }
    }

    /// 执行一段 SQL（可多语句），返回每个语句的结果集
    static func run(path: String, sql: String) -> (results: [Table], error: String?) {
        var db: OpaquePointer?
        let openPath: String
        var cleanup: String?
        if let copy = snapshotCopy(path) {
            openPath = copy
            cleanup = copy
        } else {
            openPath = path
        }
        defer {
            if let c = cleanup {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: c + suffix)
                }
            }
        }

        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(openPath, &db, flags, nil) == SQLITE_OK, let handle = db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let d = db { sqlite3_close(d) }
            return ([], "open: \(msg)")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1500)
        sqlite3_exec(handle, "PRAGMA query_only=1;", nil, nil, nil)

        var results: [Table] = []
        var cursor = sql
        while !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var stmt: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            let rc = cursor.withCString { cs in
                sqlite3_prepare_v2(handle, cs, -1, &stmt, &tail)
            }
            if rc != SQLITE_OK {
                return (results, String(cString: sqlite3_errmsg(handle)))
            }
            // 推进游标到剩余部分
            if let t = tail {
                cursor = String(cString: t)
            } else {
                cursor = ""
            }
            guard let s = stmt else { continue }
            defer { sqlite3_finalize(s) }

            var table = Table()
            let n = sqlite3_column_count(s)
            for i in 0..<n {
                table.columns.append(String(cString: sqlite3_column_name(s, i)))
            }
            while true {
                let step = sqlite3_step(s)
                if step == SQLITE_DONE { break }
                if step != SQLITE_ROW {
                    return (results, String(cString: sqlite3_errmsg(handle)))
                }
                var row: [String] = []
                for i in 0..<n {
                    if let c = sqlite3_column_text(s, i) {
                        row.append(String(cString: c))
                    } else {
                        row.append("NULL")
                    }
                }
                table.rows.append(row)
            }
            if n > 0 { results.append(table) }
        }
        return (results, nil)
    }

    /// 渲染成文本表（沿用 sqlite3 -header 的观感）
    static func render(_ results: [Table], limit: Int = 500) -> String {
        guard !results.isEmpty else { return "(no rows)" }
        var out = ""
        for (i, t) in results.enumerated() {
            if i > 0 { out += "\n" }
            out += t.columns.joined(separator: " | ") + "\n"
            out += t.columns.map { _ in "---" }.joined(separator: "-+-") + "\n"
            for row in t.rows.prefix(limit) {
                out += row.joined(separator: " | ") + "\n"
            }
            if t.rows.count > limit {
                out += "…(共 \(t.rows.count) 行，已显示前 \(limit) 行)\n"
            }
        }
        return out
    }
}
