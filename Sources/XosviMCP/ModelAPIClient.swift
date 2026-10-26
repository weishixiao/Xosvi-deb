import SwiftUI
import Foundation

// MARK: - v7.6.3 上游模型列表 / 连接测试
//
// 原在 Models.swift 内（随模型层一起被剪掉），但 ChatView 与 OriginalViews 仍在使用：
//   - 拉取上游 /models 列出可用模型
//   - 测试某条配置是否连通
// 这里按 LiteLLM 的 provider 差异做了精简重写。

enum ModelListResult {
    case success([String])
    case failure(String)
}

final class ModelAPIClient {
    static let shared = ModelAPIClient()
    private init() {}

    private func session() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        return URLSession(configuration: cfg)
    }

    /// 拉取上游模型列表。不同 provider 端点不同：
    ///   openai / deepseek / ollama / custom_openai → GET {base}/models
    ///   anthropic → GET {base}/models（x-api-key）
    ///   gemini → GET {base}/models?key=...
    func fetchModelList(config: ModelConfig,
                        completion: @escaping (ModelListResult) -> Void) {
        let provider = config.provider.lowercased()
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, let url = URL(string: base + "/models") else {
            completion(.failure("Base URL 无效"))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        switch config.authMethod {
        case "x-api-key":
            req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case "api-key":
            req.setValue(config.apiKey, forHTTPHeaderField: "api-key")
        case "None":
            break
        default:
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        if provider == "gemini", !config.apiKey.isEmpty {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = comps?.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: config.apiKey))
            comps?.queryItems = items
            if let u = comps?.url { req.url = u }
        }

        session().dataTask(with: req) { data, resp, err in
            if let err = err {
                completion(.failure(err.localizedDescription))
                return
            }
            guard let data = data else {
                completion(.failure("无响应数据"))
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                completion(.failure("HTTP \(code)：\(String(body.prefix(200)))"))
                return
            }
            let ids = Self.parseModelIDs(data)
            if ids.isEmpty {
                completion(.failure("未解析到模型（返回体格式未知）"))
            } else {
                completion(.success(ids))
            }
        }.resume()
    }

    /// 兼容 {data:[{id}]}、{models:[{name}]}、[ {id} ] 三种常见形态
    static func parseModelIDs(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [String] = []

        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                if let d = dict["data"] { walk(d); return }
                if let m = dict["models"] { walk(m); return }
                if let id = dict["id"] as? String { out.append(id); return }
                if let n = dict["name"] as? String {
                    // gemini 返回 "models/gemini-2.5-pro"
                    out.append(n.hasPrefix("models/") ? String(n.dropFirst(7)) : n)
                    return
                }
            } else if let arr = any as? [Any] {
                for item in arr { walk(item) }
            }
        }
        walk(obj)
        return out.sorted()
    }

    /// 轻量连通性测试：拉一次 /models，200 即视为可用
    func testConnection(config: ModelConfig,
                        completion: @escaping (Result<String, Error>) -> Void) {
        fetchModelList(config: config) { result in
            switch result {
            case .success(let list):
                completion(.success("连通 · 可用模型 \(list.count) 个"))
            case .failure(let msg):
                completion(.failure(NSError(domain: "ModelAPIClient", code: -1,
                                            userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }
    }
}
