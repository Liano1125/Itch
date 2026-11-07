import Foundation

struct CachedTranslationResult {
    let text: String
    let wasCached: Bool
}

private actor TranslationRequestCoalescer {
    static let shared = TranslationRequestCoalescer()
    private var tasks: [String: Task<String, Error>] = [:]

    func value(for key: String, operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks.removeValue(forKey: key) }
        return try await task.value
    }
}

enum TranslationService {
    static let providerKey = "itchPocket.translation.provider"
    static let baseURLKey = "itchPocket.translation.baseURL"
    static let modelKey = "itchPocket.translation.model"
    static let targetKey = "itchPocket.translation.target"

    static var provider: String {
        AppPreferences.string(forKey: providerKey) ?? "google"
    }

    static var isConfigured: Bool {
        switch provider {
        case "google": return true
        case "deepseek", "custom":
            return !(KeychainStore.read("translation.apiKey") ?? "").isEmpty
        default: return false
        }
    }

    static func translateCached(
        _ text: String,
        scope: String,
        forceRefresh: Bool = false
    ) async throws -> CachedTranslationResult {
        let target = AppPreferences.string(forKey: targetKey) ?? "zh-CN"
        let key = TranslationCacheKey.make(scope: scope, source: text, target: target)
        if !forceRefresh, let cached = await TranslationCache.shared.translation(for: key) {
            return CachedTranslationResult(text: cached.translation, wasCached: true)
        }
        let translated = try await TranslationRequestCoalescer.shared.value(for: key) {
            try await translate(text)
        }
        await TranslationCache.shared.store(
            translated,
            source: text,
            scope: scope,
            target: target,
            for: key
        )
        return CachedTranslationResult(text: translated, wasCached: false)
    }

    static func translate(_ text: String) async throws -> String {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return text }
        switch provider {
        case "google":
            return try await translateWithGoogle(input)
        case "deepseek", "custom":
            return try await translateWithChatAPI(input)
        default:
            throw TranslationError.unsupportedProvider
        }
    }

    private static func translateWithGoogle(_ text: String) async throws -> String {
        let target = AppPreferences.string(forKey: targetKey) ?? "zh-CN"
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = components.url else { throw TranslationError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 35
        request.setValue("Mozilla/5.0 itchPocket iOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]] else {
            throw TranslationError.invalidResponse
        }
        let result = segments.compactMap { $0.first as? String }.joined()
        guard !result.isEmpty else { throw TranslationError.emptyResult }
        return result
    }

    private static func translateWithChatAPI(_ text: String) async throws -> String {
        guard let key = KeychainStore.read("translation.apiKey"), !key.isEmpty else {
            throw TranslationError.missingAPIKey
        }
        let configuredBase = AppPreferences.string(forKey: baseURLKey) ?? "https://api.deepseek.com"
        let base = configuredBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint) else { throw TranslationError.invalidURL }
        let model = AppPreferences.string(forKey: modelKey) ?? "deepseek-flash"
        let target = AppPreferences.string(forKey: targetKey) ?? "zh-CN"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": "You are a professional game localization translator. Translate the user's text into \(target). Preserve game titles, proper nouns, URLs, Markdown structure, formatting and terminology where appropriate. Return only the translation, without explanations."],
                ["role": "user", "content": text]
            ],
            "temperature": 0.2,
            "max_tokens": 4096,
            "stream": false
        ]
        if provider == "deepseek" {
            body["thinking"] = ["type": "disabled"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let result = message["content"] as? String,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.invalidResponse
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TranslationError.httpError(http.statusCode) }
    }

    enum TranslationError: LocalizedError {
        case unsupportedProvider, invalidURL, invalidResponse, emptyResult, missingAPIKey
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedProvider: return "不支持的翻译服务。"
            case .invalidURL: return "翻译 API 地址无效。"
            case .invalidResponse: return "翻译服务返回的数据无法解析。"
            case .emptyResult: return "翻译结果为空。"
            case .missingAPIKey: return "请先在「我的 - 翻译设置」中填写 API Key。"
            case .httpError(let code): return "翻译服务请求失败（HTTP \(code)）。请检查 API 地址、密钥和额度。"
            }
        }
    }
}
