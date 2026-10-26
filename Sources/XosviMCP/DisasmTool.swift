// DisasmTool.swift — 进程内 arm64 / x86 反汇编（capstone）
//
// 背景：本机越狱（rootHide / Relaxin）hook 了 posix_spawn，App 容器内的
// 第三方二进制一律 ENOSYS(85)，r2 / cstool / objdump 全部起不来。
// capstone 静态库随包分发，这里直接链接进主进程，反汇编不再依赖子进程。

import Foundation
import CCapstone

final class DisasmTool: MCPTool {
    let definition = ToolDefinition(
        name: "disasm",
        summary: "Disassemble machine code in-process (capstone). Params: path (Mach-O), address (hex VM addr) or symbol (name substring), count (default 40), arch (arm64/arm/x86_64/x86). Use for: read the instructions around a method/function when r2/cstool cannot run (jailbreak blocks posix_spawn). Don't use for: full decompilation (this is raw disassembly). Example: disasm path:/var/.../HelloBundleID symbol:-[HBIDManager performActivation]",
        parameters: [
            "path": "absolute path to a Mach-O file (thin arm64/arm64e)",
            "address": "VM address (hex like 0x100004000) — alternative to symbol",
            "symbol": "symbol name substring to locate (e.g. performActivation)",
            "count": "how many instructions to decode (default 40)",
            "arch": "arm64 (default) / arm / x86_64 / x86"
        ],
        verified: true, category: "macho", prerequisites: [
            "文件是瘦 Mach-O（fat 请先用 macho 工具确认架构）",
            "越狱拦截子进程时本工具仍可用——反汇编在主进程内完成"
        ])

    // MARK: - Mach-O 解析

    private struct Segment {
        let name: String
        let vmaddr: UInt64
        let vmsize: UInt64
        let fileoff: UInt64
        let filesize: UInt64
    }

    private struct Symbol {
        let name: String
        let value: UInt64
    }

    private struct MachO {
        var segments: [Segment] = []
        var symbols: [Symbol] = []
        var cputype: UInt32 = 0
    }

    private func u32(_ d: Data, _ off: Int) -> UInt32? {
        guard off >= 0, off + 4 <= d.count else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt32.self) }
    }

    private func u64(_ d: Data, _ off: Int) -> UInt64? {
        guard off >= 0, off + 8 <= d.count else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: off, as: UInt64.self) }
    }

    private func cstr(_ d: Data, _ off: Int, limit: Int = 512) -> String {
        guard off >= 0, off < d.count else { return "" }
        var bytes: [UInt8] = []
        var i = off
        while i < d.count && d[i] != 0 && bytes.count < limit {
            bytes.append(d[i]); i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func parseMachO(_ d: Data) -> MachO? {
        guard let magic = u32(d, 0) else { return nil }
        guard magic == 0xfeedfacf else { return nil }   // 仅 64 位 thin
        var out = MachO()
        out.cputype = u32(d, 4) ?? 0
        guard let ncmds = u32(d, 16), let sizeofcmds = u32(d, 20) else { return nil }
        guard ncmds > 0, ncmds < 8192, sizeofcmds < (8 << 20) else { return nil }

        var off = 32
        var symoff = 0, nsyms = 0, stroff = 0
        for _ in 0..<Int(ncmds) {
            guard let cmd = u32(d, off), let size = u32(d, off + 4), size >= 8 else { break }
            let end = off + Int(size)
            guard end <= d.count, end <= 32 + Int(sizeofcmds) else { break }
            switch cmd {
            case 0x19:   // LC_SEGMENT_64
                let name = cstr(d, off + 8, limit: 16)
                if let va = u64(d, off + 24), let vs = u64(d, off + 32),
                   let fo = u64(d, off + 40), let fs = u64(d, off + 48) {
                    out.segments.append(Segment(name: name, vmaddr: va, vmsize: vs,
                                                fileoff: fo, filesize: fs))
                }
            case 0x2:    // LC_SYMTAB
                symoff = Int(u32(d, off + 8) ?? 0)
                nsyms = Int(u32(d, off + 12) ?? 0)
                stroff = Int(u32(d, off + 16) ?? 0)
            default: break
            }
            off = end
        }

        if symoff > 0, nsyms > 0, stroff > 0, nsyms < 500_000 {
            for i in 0..<nsyms {
                let base = symoff + i * 16
                guard let strx = u32(d, base), let value = u64(d, base + 8) else { break }
                guard value != 0 else { continue }
                let name = cstr(d, stroff + Int(strx), limit: 300)
                if !name.isEmpty { out.symbols.append(Symbol(name: name, value: value)) }
            }
        }
        return out
    }

    private func fileOffset(for vmaddr: UInt64, in macho: MachO) -> UInt64? {
        for s in macho.segments where s.vmsize > 0 {
            if vmaddr >= s.vmaddr && vmaddr < s.vmaddr + s.vmsize {
                return s.fileoff + (vmaddr - s.vmaddr)
            }
        }
        return nil
    }

    // MARK: - invoke

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        guard let path = params["path"] as? String, !path.isEmpty else {
            throw MCPError.invalidParams("disasm: missing path")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MCPError.classified("disasm: file not found: \(path)", code: "NOT_FOUND",
                                      reason: "path", nextStep: "先用 ls / package 确认路径")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MCPError.failed("disasm: cannot read \(path)")
        }
        guard let macho = parseMachO(data) else {
            throw MCPError.classified("disasm: 不是 64 位瘦 Mach-O（fat 请先 lipo/取 arm64 slice）",
                                      code: "BAD_FORMAT", reason: "format",
                                      nextStep: "用 macho 工具确认架构；fat 二进制请取出单个 slice")
        }

        // 目标地址：address 优先，其次 symbol 子串
        var targetAddr: UInt64?
        var matchedSymbol: String?
        if let sym = params["symbol"] as? String, !sym.isEmpty {
            let q = sym.lowercased()
            let hits = macho.symbols.filter { $0.name.lowercased().contains(q) }
            if hits.isEmpty {
                let sample = macho.symbols.prefix(8).map { $0.name }.joined(separator: ", ")
                throw MCPError.classified("disasm: 找不到符号包含 '\(sym)'（共 \(macho.symbols.count) 个符号）",
                                          code: "NOT_FOUND", reason: "parameter",
                                          nextStep: "换更短的关键词；或用 inject binary_symbols 先看有哪些符号。示例符号：\(sample)")
            }
            targetAddr = hits[0].value
            matchedSymbol = hits[0].name
        } else if let a = params["address"] {
            if let s = a as? String {
                let t = s.trimmingCharacters(in: .whitespaces)
                targetAddr = UInt64(t.hasPrefix("0x") ? String(t.dropFirst(2)) : t, radix: 16)
            } else if let n = a as? Int {
                targetAddr = UInt64(n)
            } else if let n = a as? UInt64 {
                targetAddr = n
            }
        }

        guard let addr = targetAddr else {
            throw MCPError.invalidParams("disasm: 需要 address(hex) 或 symbol")
        }
        guard let foff = fileOffset(for: addr, in: macho) else {
            throw MCPError.classified("disasm: 地址 0x\(String(addr, radix: 16)) 不在任何 segment 内",
                                      code: "BAD_PARAM", reason: "parameter",
                                      nextStep: "确认地址属于 __TEXT/__DATA；可先用 macho 工具看 segments")
        }

        let count = max(1, min((params["count"] as? Int) ?? 40, 4000))
        let archName = (params["arch"] as? String ?? "arm64").lowercased()
        // 直接用字面量映射，不依赖 C 宏导入后的具体整数类型
        let arch: Int32
        let bytesPerInsn: Int
        switch archName {
        case "arm":    arch = 1; bytesPerInsn = 4      // CSX_ARCH_ARM
        case "x86_64": arch = 2; bytesPerInsn = 16     // CSX_ARCH_X86_64
        case "x86":    arch = 3; bytesPerInsn = 16     // CSX_ARCH_X86
        default:       arch = 0; bytesPerInsn = 4      // CSX_ARCH_ARM64
        }

        let want = count * bytesPerInsn
        guard Int(foff) < data.count else {
            throw MCPError.classified("disasm: 文件偏移越界（0x\(String(foff, radix: 16)) > \(data.count)）",
                                      code: "BAD_PARAM", reason: "parameter",
                                      nextStep: "地址可能属于 __LINKEDIT 之外的映射区")
        }
        let len = min(want, data.count - Int(foff))
        guard len >= 4 else { throw MCPError.failed("disasm: 可用字节不足") }
        let slice = data.subdata(in: Int(foff)..<(Int(foff) + len))

        var outLen = 0
        var err: Int32 = 0
        let textPointer: UnsafeMutablePointer<CChar>? = slice.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return nil }
            return csx_disasm(base, buf.count, addr, arch, count, &outLen, &err)
        }
        guard let tp = textPointer else {
            throw MCPError.classified("disasm: capstone 解码失败 (err=\(err))",
                                      code: "DECODE_FAILED", reason: "tool",
                                      nextStep: "换 arch 参数（arm64/arm/x86_64/x86）或换地址")
        }
        let text = String(cString: tp)
        csx_free(tp)

        var result: [String: Any] = [
            "path": path,
            "address": "0x" + String(addr, radix: 16),
            "file_offset": "0x" + String(foff, radix: 16),
            "arch": archName,
            "count": count,
            "instructions": text,
            "runtime": "in-process capstone（不经过任何子进程）"
        ]
        if let s = matchedSymbol { result["symbol"] = s }
        return result
    }
}
