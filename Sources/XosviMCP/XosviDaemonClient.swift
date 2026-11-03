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
//  重要：iOS 的 Swift overlay 把 xpc_connection_create_mach_service /
//  xpc_release 标成了 unavailable（只在 macOS 公开），所以这里全部走
//  libxpc 的 C 符号，用 dlsym 绑定 —— 不影响 entitlement 校验逻辑，
//  App 与守护之间的协议与 debsrc/src/xosvid.c 保持逐字节一致。
//

import Foundation
import Darwin.C

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

/// libxpc C 符号的 dlsym 绑定（iOS 的 Swift overlay 不公开这几个符号）。
private enum XPCShim {
    private static let handle = dlopen("/usr/lib/libxpc.dylib", RTLD_LAZY)

    private static func bind<T>(_ name: String, as type: T.Type) -> T? {
        guard let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    static let createMachService = bind("xpc_connection_create_mach_service",
        as: (@convention(c) (UnsafePointer<CChar>, DispatchQueue, UInt64) -> XPCObject?).self)
    static let release = bind("xpc_release",
        as: (@convention(c) (XPCObject) -> Void).self)
    static let setEventHandler = bind("xpc_connection_set_event_handler",
        as: (@convention(c) (XPCObject, @escaping () -> Void) -> Void).self)
    static let setTargetQueue = bind("xpc_connection_set_target_queue",
        as: (@convention(c) (XPCObject, DispatchQueue?) -> Void).self)
    static let resume = bind("xpc_connection_resume",
        as: (@convention(c) (XPCObject) -> Void).self)
    static let sendMessageWithReply = bind("xpc_connection_send_message_with_reply",
        as: (@convention(c) (XPCObject, XPCObject, DispatchQueue?,
                             @escaping (XPCObject) -> Void) -> Void).self)
    static let dictionaryCreate = bind("xpc_dictionary_create",
        as: (@convention(c) (UnsafePointer<UnsafePointer<CChar>?>?,
                             UnsafePointer<XPCObject?>?, Int) -> XPCObject).self)
    static let dictionarySetString = bind("xpc_dictionary_set_string",
        as: (@convention(c) (XPCObject, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void).self)
    static let dictionarySetValue = bind("xpc_dictionary_set_value",
        as: (@convention(c) (XPCObject, UnsafePointer<CChar>, XPCObject) -> Void).self)
    static let dictionaryGetString = bind("xpc_dictionary_get_string",
        as: (@convention(c) (XPCObject, UnsafePointer<CChar>) -> UnsafePointer<CChar>?).self)
    static let dictionaryGetInt64 = bind("xpc_dictionary_get_int64",
        as: (@convention(c) (XPCObject, UnsafePointer<CChar>) -> Int64).self)
    static let arrayCreate = bind("xpc_array_create",
        as: (@convention(c) (UnsafePointer<XPCObject>?, Int) -> XPCObject).self)
    static let arraySetString = bind("xpc_array_set_string",
        as: (@convention(c) (XPCObject, Int, UnsafePointer<CChar>) -> Void).self)

    /// 轻量句柄：只在 deinit 时调一次 xpc_release。
    final class XPCObject {
        let raw: UnsafeMutableRawPointer
        init(_ raw: UnsafeMutableRawPointer) { self.raw = raw }
        deinit { Self.release?(self) }
    }
}

/// xosvid 的最小客户端。只依赖 libxpc（dlsym 绑定），不引入第三方库。
final class XosviDaemonClient {
    static let shared = XosviDaemonClient()

    static let serviceName = "wiki.qaq.xosvi.service"
    static let clientEntitlement = "wiki.qaq.xosvi.client"

    private let queue = DispatchQueue(label: "wiki.qaq.xosvi.daemonclient")
    private var connection: XPCShim.XPCObject?

    private init() {
        guard XPCShim.createMachService != nil else {
            NSLog("[XosviDaemonClient] libxpc symbols unavailable — daemon channel disabled")
        }
    }

    // MARK: - 连接

    private func connectionIfNeeded() -> XPCShim.XPCObject? {
        if let c = connection { return c }
        guard let create = XPCShim.createMachService else { return nil }
        let raw = create(Self.serviceName, queue, 0)
        guard let raw else { return nil }
        let object = XPCShim.XPCObject(raw)
        let handler: () -> Void = { [weak self] in
            // 连接被取消 / 服务退出：下次调用时重建
            self?.connection = nil
        }
        XPCShim.setEventHandler?(object, handler)
        XPCShim.resume?(object)
        connection = object
        return object
    }

    // MARK: - 底层请求

    /// 同步请求（内部走信号量）。`timeout` 默认 10s——守护按需启动，
    /// 首帧要留出 launchd 拉起它的时间。
    private func request(_ command: String,
                         args: [String] = [],
                         timeout: TimeInterval = 10) throws -> [String: Any] {
        guard let createDict = XPCShim.dictionaryCreate,
              let setString = XPCShim.dictionarySetString,
              let sendReply = XPCShim.sendMessageWithReply else {
            throw XosviDaemonError.unavailable("libxpc 符号缺失")
        }
        guard let conn = connectionIfNeeded() else {
            throw XosviDaemonError.unavailable("无法创建到 \(Self.serviceName) 的连接")
        }

        let message = createDict(nil, nil, 0)
        setString(message, "command", command)
        if !args.isEmpty {
            guard let createArray = XPCShim.arrayCreate,
                  let setArrayString = XPCShim.arraySetString,
                  let setValue = XPCShim.dictionarySetValue else {
                throw XosviDaemonError.unavailable("libxpc 符号缺失（array）")
            }
            let array = createArray(nil, 0)
            for arg in args { arg.withCString { setArrayString(array, 0, $0) } }
            setValue(message, "args", array)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: [String: Any] = [:]
        var failure: String?

        let replyHandler: (XPCShim.XPCObject) -> Void = { reply in
            defer { semaphore.signal() }
            guard let getString = XPCShim.dictionaryGetString else {
                failure = "libxpc 符号缺失（get）"
                return
            }
            // 错误对象与普通字典的区分：错误对象上取 error 键为 nil，
            // 这里统一按字典读，读不到关键字段就按失败处理。
            if let err = getString(reply, "error") {
                failure = String(cString: err)
                return
            }
            result["ok"] = getString(reply, "status") != nil
            result["exit_code"] = XPCShim.dictionaryGetInt64?(reply, "exit_code") ?? 0
            if let s = getString(reply, "stdout") { result["stdout"] = String(cString: s) }
            if let s = getString(reply, "status") { result["status"] = String(cString: s) }
            result["pid"] = XPCShim.dictionaryGetInt64?(reply, "pid") ?? 0
            result["uid"] = XPCShim.dictionaryGetInt64?(reply, "uid") ?? 0
        }

        sendReply(conn, message, queue, replyHandler)

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
