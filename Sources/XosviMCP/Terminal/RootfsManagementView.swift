import SwiftUI
import UIKit

// v6.9.13：Rootfs 管理页已按用户要求删除，文件只保留共享的镜像源 / DNS 写入逻辑
// （Hax 电脑页的「镜像源」「容器网络」两段还在用 RootfsConfig）。
// 恢复整页：从 git 历史取回本文件（提交 08c4b2a 及之前的版本）。

// MARK: - 共享的 rootfs 配置逻辑（Hax 电脑页也会用）

/// v6.6.14：镜像源 / DNS 写入逻辑，供 Hax 电脑页使用（v6.9.13 起 Rootfs 管理页已移除）。
enum RootfsConfig {
    static var dataPath: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alpine-rootfs/data").path
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: dataPath) }

    static func apkMirrorCommand(_ name: String) -> String {
        let base: String
        switch name {
        case "USTC":     base = "https://mirrors.ustc.edu.cn/alpine/latest-stable"
        case "Aliyun":   base = "https://mirrors.aliyun.com/alpine/latest-stable"
        case "Tsinghua": base = "https://mirrors.tuna.tsinghua.edu.cn/alpine/latest-stable"
        default:         base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable"
        }
        return "mkdir -p /etc/apk && printf '%s\\n' '\(base)/main' '\(base)/community' > /etc/apk/repositories && cat /etc/apk/repositories"
    }

    static func pipMirrorCommand(_ name: String) -> String {
        let url: String
        switch name {
        case "Alibaba":  url = "https://mirrors.aliyun.com/pypi/simple/"
        case "Tsinghua": url = "https://pypi.tuna.tsinghua.edu.cn/simple"
        case "USTC":     url = "https://mirrors.ustc.edu.cn/pypi/simple"
        default:         url = "https://pypi.org/simple"
        }
        // 提取 host 作为 trusted-host
        let host = url
            .replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: "/").first ?? ""
        return "mkdir -p /etc /root/.config/pip && printf '[global]\\nindex-url = \(url)\\ntrusted-host = \(host)\\n' > /etc/pip.conf && cp /etc/pip.conf /root/.config/pip/pip.conf && cat /etc/pip.conf"
    }

    static func npmMirrorCommand(_ name: String) -> String {
        let url = name == "npmmirror" ? "https://registry.npmmirror.com" : "https://registry.npmjs.org"
        return "mkdir -p /root && printf 'registry=\(url)\\n' > /root/.npmrc && cat /root/.npmrc"
    }

    static func dnsCommand(_ mode: String) -> String {
        let servers: String
        switch mode {
        case "国内":   servers = "223.5.5.5 119.29.29.29"
        case "Google": servers = "8.8.8.8 8.8.4.4"
        default:       servers = "223.5.5.5 119.29.29.29 8.8.8.8"
        }
        let lines = servers.components(separatedBy: " ").map { "echo 'nameserver \($0)' >> /etc/resolv.conf" }
        return "echo '# hax-dns \(mode)' > /etc/resolv.conf; " + lines.joined(separator: "; ") + "; cat /etc/resolv.conf"
    }

    static func currentDNSSummary() -> String {
        let r = ISHEngine.exec("cat /etc/resolv.conf 2>/dev/null | grep nameserver | head -3", timeout: 8)
        let dns = r.output.components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("nameserver") else { return nil }
                return t.replacingOccurrences(of: "nameserver", with: "").trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: " / ")
        return dns.isEmpty ? "（未配置）" : dns
    }
}
