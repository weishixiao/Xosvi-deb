import Foundation

// MARK: - v8.2：模型 API 余额查询（分级策略，命中哪层算哪层）
//
// 没有统一余额接口，各服务商协议不同：
//   策略 1  DeepSeek 官方   GET /user/balance → balance_infos[0].total_balance
//   策略 2  new-api/one-api 中转站（botcf/破甲站等都属这类）
//           GET /dashboard/billing/subscription → hard_limit_usd（总额度）
//           GET /dashboard/billing/usage        → total_usage（已用，单位美分）
//   兜底    统一失败文案"该服务商不支持余额查询"——比假装查出个数字诚实。
// OpenAI / Anthropic 官方没有可用余额端点，会落到兜底。

struct BalanceResult {
    var remaining: String     // 展示文本，如 "¥86.20" / "$12.00"
    var via: String           // 命中的策略名
}

final class BalanceChecker {
    /// 按策略依次尝试，任一成功即返回
    static func check(config: ModelConfig, completion: @escaping (Result<BalanceResult, String>) -> Void) {
        // 策略 1：DeepSeek 官方余额接口
        if config.provider.lowercased().contains("deepseek")
            || config.baseURL.lowercased().contains("deepseek") {
            getJSON(config, path: "/user/balance") { r in
                switch r {
                case .success(let json):
                    if let infos = json["balance_infos"] as? [[String: Any]],
                       let first = infos.first,
                       let total = first["total_balance"] as? String,
                       let cur = first["currency"] as? String {
                        let symbol = (cur == "CNY") ? "¥" : cur
                        completion(.success(BalanceResult(remaining: "\(symbol)\(total)", via: "deepseek")))
                        return
                    }
                    completion(.failure("响应解析失败"))
                case .failure(let e):
                    completion(.failure(e))
                }
            }
            return
        }

        // 策略 2：new-api / one-api 中转站通用协议
        getJSON(config, path: "/dashboard/billing/subscription") { r in
            switch r {
            case .success(let json):
                guard let limit = json["hard_limit_usd"] as? Double else {
                    completion(.failure("该服务商不支持余额查询，请到控制台查看"))
                    return
                }
                BalanceChecker.getJSON(config, path: "/dashboard/billing/usage") { r2 in
                    switch r2 {
                    case .success(let usage):
                        let used = (usage["total_usage"] as? Double ?? 0) / 100.0
                        let remain = max(0, limit - used)
                        completion(.success(BalanceResult(
                            remaining: String(format: "$%.2f / %.2f", remain, limit),
                            via: "new-api")))
                    case .failure:
                        // 有总额度没用量接口 → 至少显示总额
                        completion(.success(BalanceResult(
                            remaining: String(format: "总额 $%.2f", limit),
                            via: "new-api")))
                    }
                }
            case .failure(let e):
                completion(.failure(e))
            }
        }
    }

    /// 统一 GET：base + path，鉴权按 config.authMethod（与 ModelRow.speedTest 同一模式）
    private static func getJSON(_ config: ModelConfig, path: String,
                                completion: @escaping (Result<[String: Any], String>) -> Void) {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + path) else {
            completion(.failure("Base URL 无效"))
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        setHTTPMethod("GET", on: &req)
        let key = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        switch config.authMethod {
        case "API Key": req.setValue(key, forHTTPHeaderField: "x-api-key")
        case "None": break
        default:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        }
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                if let error = error { completion(.failure(error.localizedDescription)); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, status == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                    completion(.failure("HTTP \(status): \(raw.prefix(120))"))
                    return
                }
                completion(.success(json))
            }
        }.resume()
    }
}
