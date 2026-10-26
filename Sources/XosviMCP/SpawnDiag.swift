// SpawnDiag.swift — 内置二进制为什么起不来（进程内诊断，不依赖任何子进程）
//
// 真机现象：bin/python3、bin/r2、bin/bsdtar 全部
//   posix_spawn failed: Bad executable (or shared library)
// 这条错误只说"坏可执行文件"，不区分：
//   ① 文件不存在 / 没有执行位
//   ② 不是 Mach-O（被 ELF 覆盖、下载损坏）
//   ③ 缺 LC_CODE_SIGNATURE（重签时被 strip）
//   ④ 签名没被 AMFI 接受（entitlements 与签名身份不匹配）
//   ⑤ 依赖的 framework 不在 @rpath（Bad executable 也会这么报）
// 这个诊断把这五项分别查出来，全部在进程内完成——即使所有 spawn 都失败也能跑。

import Foundation

enum SpawnDiag {

    struct MachOInfo {
        var magic: String = "-"
        var isMachO = false
        var hasCodeSignature = false
        var cryptid: UInt32 = 0
        var rpaths: [String] = []
        var dylibs: [String] = []
        var codeSigOffset = 0
        var codeSigSize = 0
    }

    /// 嵌入签名概要——用来判断"是不是和调用者同一签名身份"
    struct SignInfo {
        var teamID: String = ""
        var hasCMS = false
        var adhoc = false
        var cdVersion: UInt32 = 0
        var identifier: String = ""
    }

    /// 解析 LC_CODE_SIGNATURE 指向的 SuperBlob，取 Team ID / CMS / ad-hoc 标志。
    ///
    /// 用途：验证"RootHide 只放行与调用者同签名身份的二进制"这一推断——
    /// App 主二进制由安装方式真实签名（有 Team ID、有 CMS），
    /// 而 CI 里 ad-hoc 签的 bin/* 没有 Team ID，两者 spawn 结果不同。
    static func signatureInfo(_ path: String) -> SignInfo {
        var out = SignInfo()
        let mo = readMachO(path)
        guard mo.hasCodeSignature, mo.codeSigSize > 12,
              let fh = FileHandle(forReadingAtPath: path) else { return out }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: UInt64(mo.codeSigOffset))) != nil,
              let blob = try? fh.read(upToCount: mo.codeSigSize),
              blob.count >= 12 else { return out }

        let magic: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0xfade0cc0 else { return out }   // SuperBlob
        let count: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }

        var cdOffset = -1
        for i in 0..<Int(min(count, 32)) {
            let base = 12 + i * 8
            guard base + 8 <= blob.count else { break }
            let type: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base, as: UInt32.self) }
            let off: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self) }
            if type == 0 { cdOffset = Int(off) }                       // CSSLOT_CODEDIRECTORY
            if type == 0x10000 { out.hasCMS = true }                   // CSSLOT_SIGNATURESLOT
        }
        guard cdOffset >= 0, cdOffset + 44 <= blob.count else { return out }

        let cdMagic: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cdOffset, as: UInt32.self) }
        guard cdMagic == 0xfade0c02 else { return out }
        let version: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cdOffset + 8, as: UInt32.self) }
        let flags: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cdOffset + 12, as: UInt32.self) }
        let identOff: UInt32 = blob.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cdOffset + 20, as: UInt32.self) }
        out.cdVersion = version
        out.adhoc = (flags & 0x2) != 0
        out.identifier = cString(blob, cdOffset + Int(identOff))

        // teamOffset 只有 CodeDirectory v0x20200 起才有
        if version >= 0x20200, cdOffset + 52 <= blob.count {
            let teamOff: UInt32 = blob.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: cdOffset + 48, as: UInt32.self)
            }
            if teamOff > 0 {
                out.teamID = cString(blob, cdOffset + Int(teamOff))
            }
        }
        return out
    }

    static func readMachO(_ path: String) -> MachOInfo {
        var info = MachOInfo()
        guard let fh = FileHandle(forReadingAtPath: path) else { return info }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: 32), head.count == 32 else { return info }
        let magicLE = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        info.magic = String(format: "%08x", magicLE)
        let is64 = (magicLE == 0xfeedfacf)
        let isFat = (magicLE == 0xcafebabe) || (magicLE == 0xbebafeca)
        info.isMachO = is64 || magicLE == 0xfeedface || isFat
        guard is64 else { return info }   // 只解析 thin arm64 头部

        let ncmds: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds: UInt32 = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        guard ncmds > 0, ncmds < 4096, sizeofcmds < 4 << 20 else { return info }
        guard let body = try? fh.read(upToCount: Int(sizeofcmds)), body.count == Int(sizeofcmds) else { return info }

        var off = 0
        for _ in 0..<ncmds {
            guard off + 8 <= body.count else { break }
            let cmd: UInt32 = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
            let size: UInt32 = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self) }
            guard size >= 8, off + Int(size) <= body.count else { break }
            switch cmd {
            case 0x1D:   // LC_CODE_SIGNATURE
                info.hasCodeSignature = true
                info.codeSigOffset = Int(body.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: off + 8, as: UInt32.self)
                })
                info.codeSigSize = Int(body.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: off + 12, as: UInt32.self)
                })
            case 0x21:   // LC_ENCRYPTION_INFO
                info.cryptid = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 16, as: UInt32.self) }
            case 0x2C:   // LC_ENCRYPTION_INFO_64
                info.cryptid = body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off + 16, as: UInt32.self) }
            case 0x8000001C:  // LC_RPATH
                let s = cString(body, off + 12)
                if !s.isEmpty { info.rpaths.append(s) }
            case 0xC:    // LC_LOAD_DYLIB
                let s = cString(body, off + 24)
                if !s.isEmpty { info.dylibs.append(s) }
            default:
                break
            }
            off += Int(size)
        }
        return info
    }

    /// lc_str：从命令内的相对偏移读到 NUL
    private static func cString(_ data: Data, _ start: Int) -> String {
        guard start < data.count else { return "" }
        var bytes: [UInt8] = []
        var i = start
        while i < data.count && data[i] != 0 && bytes.count < 256 {
            bytes.append(data[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func run() -> [String: Any] {
        // 诊断要真实探测，先清掉上一次的"被拦截"记忆
        BuildRunner.resetSpawnBlock()
        let fm = FileManager.default
        let binDir = Bundle.main.bundlePath + "/bin"
        let names = ["python3", "node", "r2", "cstool", "lua", "jq", "bsdtar", "ldid"]

        var rows: [[String: Any]] = []
        for n in names {
            let p = binDir + "/" + n
            guard fm.fileExists(atPath: p) else {
                rows.append(["name": n, "present": false])
                continue
            }
            let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let size = (attrs[.size] as? Int) ?? 0
            let perm = (attrs[.posixPermissions] as? Int) ?? 0
            let mo = readMachO(p)
            let sig = signatureInfo(p)
            // 真正试一次 spawn：errno 由 BuildRunner 带回来
            let r = BuildRunner.shared.run(executable: p, args: ["--version"], env: [:], timeout: 5)
            var row: [String: Any] = [
                "name": n,
                "present": true,
                "size": size,
                "executable": (perm & 0o111) != 0,
                "magic": mo.magic,
                "mach_o": mo.isMachO,
                "code_signature": mo.hasCodeSignature,
                "cryptid": Int(mo.cryptid),
                "team_id": sig.teamID.isEmpty ? "(none)" : sig.teamID,
                "adhoc": sig.adhoc,
                "has_cms": sig.hasCMS,
                "cd_version": String(format: "0x%x", sig.cdVersion),
                "identifier": sig.identifier,
                "rpaths": mo.rpaths,
                "dylibs": Array(mo.dylibs.prefix(6)),
                "spawn_ok": r.spawnError == nil,
                "spawn_error": r.spawnError ?? "",
                "exit_code": Int(r.exitCode)
            ]
            if let lib = mo.dylibs.first(where: { $0.hasPrefix("@rpath/") }) {
                let rel = String(lib.dropFirst("@rpath/".count))
                let fwPath = Bundle.main.bundlePath + "/Frameworks/" + rel
                row["first_rpath_dylib"] = lib
                row["first_rpath_dylib_exists"] = fm.fileExists(atPath: fwPath)
            }
            rows.append(row)
        }

        // 对照 1：App 主二进制（由安装方式真实签名）——它与调用者同一签名身份
        var mainInfo: [String: Any] = ["path": Bundle.main.bundlePath]
        if let exe = Bundle.main.executablePath {
            let mSig = signatureInfo(exe)
            let mMachO = readMachO(exe)
            mainInfo = [
                "path": exe,
                "team_id": mSig.teamID.isEmpty ? "(none)" : mSig.teamID,
                "adhoc": mSig.adhoc,
                "has_cms": mSig.hasCMS,
                "identifier": mSig.identifier,
                "mach_o": mMachO.isMachO
            ]
        }
        // 对照 2：Apple 系统二进制（不受越狱白名单限制）
        let controlPath = "/usr/bin/plutil"
        let ctrl = BuildRunner.shared.run(executable: controlPath, args: ["-help"], env: [:], timeout: 5)
        let systemControl: [String: Any] = [
            "path": controlPath,
            "exists": FileManager.default.fileExists(atPath: controlPath),
            "spawn_ok": ctrl.spawnError == nil,
            "spawn_error": ctrl.spawnError ?? ""
        ]

        // 签名身份对照结论：RootHide 很可能只放行与调用者同身份的二进制
        let helpers = rows.filter { ($0["present"] as? Bool) == true }
        let allAdhoc = !helpers.isEmpty && helpers.allSatisfy { ($0["adhoc"] as? Bool) == true }
        let mainTeam = (mainInfo["team_id"] as? String) ?? "(none)"
        var identityHint = "无法判定（主二进制没有 Team ID 信息）"
        if mainTeam != "(none)" && allAdhoc {
            identityHint = "主二进制有 Team ID（\(mainTeam)），bin/* 全部是 ad-hoc（无 Team ID）"
                + " → 与「只放行同签名身份」的推断一致：换 TrollStore 安装（会重签整个 bundle）应能恢复 spawn"
        } else if mainTeam == "(none)" && allAdhoc {
            identityHint = "主二进制与 bin/* 都是 ad-hoc —— 安装方式没有为 App 重新签名；"
                + "RootHide 在隐藏上下文里对 ad-hoc 二进制一律拒绝"
        } else if !allAdhoc {
            identityHint = "部分内置二进制带 Team ID —— 若它们能 spawn 而 ad-hoc 的不能，即可确认是签名身份问题"
        }

        let broken = rows.filter { ($0["present"] as? Bool) == true && ($0["spawn_ok"] as? Bool) == false }
        // errno 85 = ENOSYS：不是文件坏了，是越狱 hook 了 posix_spawn 拒绝执行
        let enosys = broken.contains { (($0["spawn_error"] as? String) ?? "").contains("errno 85") }
        var advice = "内置二进制均可执行"
        if enosys {
            advice = "errno 85 = ENOSYS：本机越狱（rootHide / Relaxin）hook 了 posix_spawn，"
                + "拒绝执行 App 容器内的第三方二进制。这不是签名或文件损坏，重装/重签都无效；"
                + "Apple 系统二进制（/usr/bin/plutil 等）仍可执行。"
                + "请改用进程内工具：inject binary_symbols / package / macho / plutil / grep。"
        } else if !broken.isEmpty {
            advice = "有 \(broken.count) 个内置二进制无法 spawn。看每行的 code_signature / mach_o / first_rpath_dylib_exists："
                + "mach_o=false → 文件损坏（不是 Mach-O）；code_signature=false → 重签时被 strip；"
                + "first_rpath_dylib_exists=false → 依赖 framework 缺失（同样报 Bad executable）"
        }

        return [
            "bundle": Bundle.main.bundlePath,
            "app_version": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?",
            "sandboxed_container": Bundle.main.bundlePath.contains("/Containers/Bundle/Application/"),
            "binaries": rows,
            "broken_count": broken.count,
            "jailbreak_spawn_blocked": enosys,
            "main_binary": mainInfo,
            "system_control": systemControl,
            "signature_identity": identityHint,
            "advice": advice
        ]
    }
}
