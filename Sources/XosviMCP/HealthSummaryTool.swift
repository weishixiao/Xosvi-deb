import Foundation

// MARK: - v8（PR-F-40）：健康度自检工具
//
// 把 AuditLog 已有的聚合（healthSummary / codeDistribution / recentFailures）暴露成工具，
// 让 AI 自查「我最近哪些工具老失败」。只读。

final class HealthSummaryTool: MCPTool {
    let definition = ToolDefinition(
        name: "health.summary",
        summary: "Summarize tool health from the audit log: success rate, slowest tools, most frequent error codes, recent failures. Use for: 自查哪些工具最近老失败、定位环境性问题. Don't use for: 逐条读审计记录（用 tools.audit）或单次调用排障（用 diagnose）. Example: '我最近哪些工具老失败' → health.summary.",
        parameters: [
            "hours": "Int，默认 24：回看小时数（只影响 recent_failures 的时间窗）",
            "top": "Int，默认 5：每个榜单返回条数",
        ],
        returns: [
            "total_calls": "总调用数",
            "success_rate": "成功率 0-1",
            "by_tool": "每个工具 {tool, success, failure, avg_ms, top_code}",
            "error_codes": "错误码分布",
            "recent_failures": "最近失败条目",
        ],
        verified: false, category: "diagnose",
        annotations: .readOnlyLocal,
        cache: ToolCachePolicy.short,
        paramSpecs: [
            .i("hours", "回看小时数", required: false, example: "24"),
            .i("top", "返回条数", required: false, example: "5"),
        ],
        related: [
            RelatedTool(tool: "tools.audit", when: "需要逐条审计记录时"),
            RelatedTool(tool: "diagnose", when: "需要单次失败的系统级诊断时"),
        ]
    )

    func invoke(_ params: [String: Any]) throws -> [String: Any] {
        let hours = max(1, (params["hours"] as? Int) ?? 24)
        let top = max(1, min((params["top"] as? Int) ?? 5, 20))
        let since = Date().addingTimeInterval(-Double(hours) * 3600)

        let log = AuditLog.shared
        let toolEntries = log.entries.filter { $0.status != nil }
        guard !toolEntries.isEmpty else {
            return ["total_calls": 0, "hours": hours,
                    "message": "还没有工具调用审计记录",
                    "hint": "先调用几个工具再查；审计在每次 dispatch 后写入"]
        }

        let total = toolEntries.count
        let failed = toolEntries.filter { $0.status == .failure }.count
        let windowFailures = log.entries.filter {
            $0.status == .failure && $0.timestamp >= since
        }

        let byTool = log.healthSummary(limit: top).map { h -> [String: Any] in
            [
                "tool": h.tool,
                "success": h.success,
                "failure": h.failure,
                "avg_ms": h.avgMs,
                "top_code": h.topCode,
                "last_failure": h.lastFailureDetail,
            ]
        }
        let codes = log.codeDistribution().prefix(top).map { ["code": $0.code, "count": $0.count] }
        let recent = windowFailures.suffix(top).map { e -> [String: Any] in
            [
                "time": ISO8601DateFormatter().string(from: e.timestamp),
                "tool": e.category,
                "code": e.errorCode ?? "UNKNOWN",
                "reason": e.errorReason ?? "",
                "next_step": e.nextStep ?? "",
                "detail": String(e.detail.prefix(160)),
            ]
        }

        return [
            "hours": hours,
            "total_calls": total,
            "failures": failed,
            "success_rate": total > 0 ? Double(total - failed) / Double(total) : 0,
            "by_tool": byTool,
            "error_codes": Array(codes),
            "recent_failures": Array(recent),
            "next_step": failed == 0
                ? "近期无失败"
                : "优先看 by_tool 里 failure 最高的工具；若 top_code 是 ENV_PERMISSION，先修环境（TrollStore Entitlements），不要重复重试",
        ]
    }
}
