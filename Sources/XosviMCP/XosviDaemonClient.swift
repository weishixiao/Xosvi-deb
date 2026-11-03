//
//  XosviDaemonClient.swift
//  Xosvi
//
//  deb 版的 root 通道：App → wiki.qaq.xosvi.service（xosvid）→ helper。
//
//  与 tipa 时代的 rootd（文件队列 + LaunchDaemon）并存，互不影响：
//    · xosvid 可用时优先走它（原生 XPC，无轮询、无 1777 目录）；
//    · 不可用时（没装 deb / 服务未注册）返回 available=false，
//      调用方继续用 RootdTool 的旧路径。
//
//  服务端每次连接都会用 audit token 校验 wiki.qaq.xosvi.client，
//  这个 entitlement 在 Support/Xosvi.entitlements 里声明。
//

import Foundation

#if canImport(Foundation)
import Darwin
#endif

enum XosviDaemonError: LocalizedError {
    case unavailable(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return "Xosvi 后台服务不可用：\(why)"
        case .failed(let why): return "Xosvi 后台服务返回错误：\(why)"
        }
    }
}

/// xosvid 的最小客户端。只依赖 libxpc，不引入第三方库。
final class XosviDaemonClient {
    static let shared = XosviDaemonClient()

    static let serviceName = "wiki.qaq.xosvi.service"
    static let clientEntitlement = "wiki.qaq.xosvi.client"

    private let queue = DispatchQueue(label: "wiki.qaq.xosvi.daemonclient")
    private var connection: xpc_connection_t?

    private init() {}

    // MARK: - 连接

    private func connectionIfNeeded() -> xpc_connection_t? {
        if let c = connection { return c }
        guard let c = xpc_connection_create_mach_service(
            Self.serviceName, queue, 0) else { return nil }
        xpc_connection_set_event_handler(c) { event in
            // 连接被取消 / 服务退出：下次调用时重建
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                self.connection = nil
            }
        }
        xpc_connection_resume(c)
        connection = c
        return c
    }

    // MARK: - 底层请求

    /// 同步请求（内部走信号量）。`timeout` 默认 10s——守护按需启动，
    /// 首帧要留出 launchd 拉起它的时间。
    private func request(_ command: String,
                         args: [String] = [],
                         timeout: TimeInterval = 10) throws -> [String: Any] {
        guard let conn = connectionIfNeeded() else {
            throw XosviDaemonError.unavailable("无法创建到 \(Self.serviceName) 的连接")
        }

        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "command", command)
        if !args.isEmpty {
            let array = xpc_array_create(nil, 0)
            for arg in args {
                xpc_array_set_string(array, XPC_ARRAY_APPEND, arg)
            }
            xpc_dictionary_set_value(message, "args", array)
            xpc_release(array)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        var failure: String?

        xpc_connection_send_message_with_reply(conn, message, queue) { reply in
            defer { semaphore.signal() }
            guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
                failure = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION)
                    .map { String(cString: $0) } ?? "XPC 错误"
                return
            }
            if let err = xpc_dictionary_get_string(reply, "error") {
                failure = String(cString: err)
                return
            }
            result["ok"] = xpc_dictionary_get_bool(reply, "ok")
            result["exit_code"] = xpc_dictionary_get_int64(reply, "exit_code")
            if let s = xpc_dictionary_get_string(reply, "stdout") {
                result["stdout"] = String(cString: s)
            }
            if let s = xpc_dictionary_get_string(reply, "status") {
                result["status"] = String(cString: s)
            }
            result["pid"] = xpc_dictionary_get_int64(reply, "pid")
            result["uid"] = xpc_dictionary_get_int64(reply, "uid")
        }
        xpc_release(message)

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            throw XosviDaemonError.unavailable("请求超时（\(Int(timeout))s）")
        }
        if let failure { throw XosviDaemonError.failed(failure) }
        return result
    }

    // MARK: - 公开 API

    /// 服务是否可用。不抛错，供 UI / 工具做能力探测。
    func status(timeout: TimeInterval = 2) -> [String: Any] {
        do {
            let r = try request("ping", timeout: timeout)
            return [
                "available": true,
                "transport": "xpc",
                "service": Self.serviceName,
                "pid": r["pid"] ?? 0,
                "uid": r["uid"] ?? 0
            ]
        } catch {
            return [
                "available": false,
                "transport": "xpc",
                "service": Self.serviceName,
                "error": error.localizedDescription
            ]
        }
    }

    /// 构建：在指定项目目录里跑项目自带的构建脚本（argv 形式，不经过 shell）。
    func build(projectDir: String, script: String,
               arguments: [String] = [], timeout: TimeInterval = 300) throws -> [String: Any] {
        try request("build", args: [projectDir, script] + arguments, timeout: timeout)
    }

    /// 装包：install / remove / purge / list，内部交给 dpkg。
    func package(_ subcommand: String, argument: String? = nil,
                 timeout: TimeInterval = 300) throws -> [String: Any] {
        var args = [subcommand]
        if let argument { args.append(argument) }
        return try request("install", args: args, timeout: timeout)
    }

    /// 符号化：info（打印 UUID）/ match（崩溃报告 ↔ 二进制或 dSYM）。
    func symbolicate(_ subcommand: String, paths: [String],
                     timeout: TimeInterval = 60) throws -> [String: Any] {
        try request("symbolicate", args: [subcommand] + paths, timeout: timeout)
    }
}
