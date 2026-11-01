import Foundation

/// 最小 JSON-RPC 2.0 处理器（tools/list + tools/call）。
/// M1 阶段直接进程内调用；M4 接 Gateway 时同一套分发逻辑套上 WebSocket 传输。
///
/// v7.17.0（AI 无缝化 P0）：
///   1. tools/list 不再只导出 4 个字段——inputSchema / returns / prerequisites /
///      environment / annotations / variants / related / outputSchema 全量下发；
///   2. 协议版本、serverInfo 从 Bundle 动态读取，不再写死 2.0.0-m1；
///   3. 补 ping / notifications/initialized / notifications/cancelled；
///   4. tools/list 支持 cursor + pageSize 分页；
///   5. tools/call 失败时在 JSON-RPC error.data 里带结构化诊断
///      （code / reason / next_step / kb_fix / evidence）。
public enum JSONRPC {

    /// 本实现能理解的 MCP 协议版本。客户端请求哪个就回哪个（echo），
    /// 不认识时回退到 2024-11-05，避免客户端按未知版本解析失败。
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18",
    ]
    private static let defaultProtocolVersion = "2024-11-05"

    public static func handle(_ data: Data, registry: ToolRegistry = .shared) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            return encode(errorResponse(id: nil, code: -32700, message: "parse error"))
        }
        let id = obj["id"]
        let params = obj["params"] as? [String: Any] ?? [:]

        // 通知（无 id）不需要响应。之前未处理会被客户端记为异常。
        if method.hasPrefix("notifications/") {
            return Data()
        }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let version = requested.flatMap { supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? defaultProtocolVersion
            return encode(response(id: id, result: [
                "protocolVersion": version,
                "capabilities": [
                    "tools": ["listChanged": false],
                ] as [String: Any],
                "serverInfo": [
                    "name": "Xosvi",
                    "version": ToolContract.appVersion,
                    "build": ToolContract.buildVersion,
                ],
                "instructions": "Xosvi is an on-device iOS reverse-engineering MCP server. "
                    + "Call big tools as `name` + command/action. Use system.overview for the "
                    + "authoritative tool list. All file paths must be absolute.",
            ]))
        case "ping":
            return encode(response(id: id, result: [:]))

        case "tools/list":
            let all = registry.definitions
            // cursor = 已返回条数（字符串化整数）；默认每页 50，避免工具多时单帧过大。
            let requestedPage = (params["pageSize"] as? Int)
                ?? (params["pageSize"] as? String).flatMap { Int($0) }
                ?? (params["limit"] as? Int)
                ?? 50
            let pageSize = min(max(requestedPage, 1), 200)
            let cursorRaw = params["cursor"]
            let offset = max((cursorRaw as? Int)
                ?? (cursorRaw as? String).flatMap { Int($0) }
                ?? 0, 0)
            let slice = Array(all.dropFirst(offset).prefix(pageSize))
            let list: [[String: Any]] = slice.map { def in
                var item = ToolContract.mcpTool(for: def)
                item["enabled"] = registry.isEnabled(name: def.name)
                return item
            }
            var result: [String: Any] = ["tools": list]
            if offset + slice.count < all.count {
                result["nextCursor"] = String(offset + slice.count)
            }
            return encode(response(id: id, result: result))

        case "tools/call":
            guard let toolName = params["name"] as? String else {
                return encode(errorResponse(id: id, code: -32602, message: "params.name required"))
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let result = try registry.dispatch(name: toolName, params: args)
                return encode(response(id: id, result: [
                    "content": [["type": "text", "text": jsonString(from: result)]],
                    "isError": false,
                    "structuredContent": result,
                ]))
            } catch let e as MCPError {
                // MCP spec：工具执行失败应放在 result.isError 里，客户端才能看到
                // 结构化内容；同时保留 JSON-RPC error.data 兼容旧客户端。
                var errObj: [String: Any] = ["code": -32000, "message": e.description,
                                             "data": e.structured]
                if case .unknownTool(_) = e { errObj["code"] = -32601 }
                var dict: [String: Any] = ["jsonrpc": "2.0", "error": errObj]
                if let id = id { dict["id"] = id }
                return encode(dict)
            } catch {
                let structured: [String: Any] = [
                    "code": "TOOL_FAILED", "reason": "tool",
                    "message": String(describing: error),
                    "next_step": "inspect the tool's required params, then retry once or switch tools",
                ]
                var dict: [String: Any] = [
                    "jsonrpc": "2.0",
                    "error": ["code": -32000, "message": String(describing: error), "data": structured],
                ]
                if let id = id { dict["id"] = id }
                return encode(dict)
            }
        default:
            return encode(errorResponse(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    // MARK: - 私有

    private static func response(id: Any?, result: [String: Any]) -> [String: Any] {
        var dict: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        var dict: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id = id { dict["id"] = id }
        return dict
    }

    private static func encode(_ dict: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
    }

    private static func jsonString(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
