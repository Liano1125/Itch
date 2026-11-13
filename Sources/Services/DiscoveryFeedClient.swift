import Foundation
import WebKit

enum DiscoveryFeedError: LocalizedError {
    case invalidResponse
    case ageGate
    case unsupportedMarkup
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "itch.io 返回了无法识别的响应。"
        case .ageGate:
            return "itch.io 要求先完成 18+ 年龄确认。请先打开对应分类页面确认年龄，再刷新发现页。"
        case .unsupportedMarkup:
            return "没有识别到游戏卡片，可能是 itch.io 页面结构发生变化。"
        case .decodingFailed:
            return "游戏列表数据转换失败。"
        }
    }
}

/// Fetches only lightweight listing cards. It never creates a WKWebView and
/// never requests full game detail pages, keeping discovery refresh off the UI.
final class DiscoveryFeedClient {
    static let shared = DiscoveryFeedClient()

    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchGames(from url: URL) async throws -> [PublicCollectionGame] {
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let cookies = await websiteCookies()
        if !cookies.isEmpty {
            let headers = HTTPCookie.requestHeaderFields(with: cookies)
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            throw DiscoveryFeedError.invalidResponse
        }

        if html.range(of: #"You must be 18\+ to view this content|Date of Birth:"#,
                      options: [.regularExpression, .caseInsensitive]) != nil {
            throw DiscoveryFeedError.ageGate
        }

        let cards = Self.extractGameCards(from: html, baseURL: url)
        guard !cards.isEmpty || html.localizedCaseInsensitiveContains("No games found") else {
            throw DiscoveryFeedError.unsupportedMarkup
        }

        do {
            let payload = try JSONSerialization.data(withJSONObject: cards, options: [.fragmentsAllowed])
            return try JSONDecoder().decode([PublicCollectionGame].self, from: payload)
        } catch {
            throw DiscoveryFeedError.decodingFailed
        }
    }

    @MainActor
    private func websiteCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies.filter {
                    $0.domain.contains("itch.io")
                })
            }
        }
    }

    static func extractGameCards(from html: String, baseURL: URL) -> [[String: Any]] {
        let divPattern = #"(?is)<(/?)div\b([^>]*)>"#
        guard let divRegex = try? NSRegularExpression(pattern: divPattern) else { return [] }
        let nsHTML = html as NSString
        let matches = divRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var cards: [String] = []
        var cardStart: Int?
        var depth = 0

        for match in matches {
            let closing = nsHTML.substring(with: match.range(at: 1)) == "/"
            let attributes = nsHTML.substring(with: match.range(at: 2))
            if !closing {
                if cardStart == nil,
                   let classes = attribute("class", in: attributes),
                   classes.split(whereSeparator: { $0.isWhitespace }).contains("game_cell") {
                    cardStart = match.range.location
                    depth = 1
                } else if cardStart != nil {
                    depth += 1
                }
            } else if cardStart != nil {
                depth -= 1
                if depth == 0, let start = cardStart {
                    let end = NSMaxRange(match.range)
                    cards.append(nsHTML.substring(with: NSRange(location: start, length: end - start)))
                    cardStart = nil
                }
            }
        }

        var seen = Set<String>()
        return cards.compactMap { card in
            guard let attributes = firstTagAttributes("div", in: card) else { return nil }
            let allAnchors = anchors(in: card)
            let titleContainer = innerHTML(className: "game_title", in: card)
            let titleAnchor = allAnchors.first(where: {
                $0.classes.contains("game_link") || $0.classes.contains("title")
            }) ?? titleContainer.flatMap { anchors(in: $0).first } ?? allAnchors.first(where: { $0.href != nil })
            let title = titleAnchor.flatMap { cleanText($0.html) }
                ?? titleContainer.flatMap(cleanText)
            guard let title, !title.isEmpty else { return nil }

            let link = titleAnchor?.href.flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL.absoluteString }
            let id = attribute("data-game_id", in: attributes) ?? link ?? title
            guard seen.insert(id).inserted else { return nil }

            let imageTag = tags(named: "img", in: card).first
            var imageValue: String?
            if let imageTag {
                imageValue = attribute("data-lazy_src", in: imageTag)
                if imageValue == nil {
                    imageValue = attribute("data-lazy-src", in: imageTag)
                }
                if imageValue == nil {
                    imageValue = attribute("data-src", in: imageTag)
                }
                if imageValue == nil {
                    imageValue = attribute("src", in: imageTag)
                }
                if imageValue == nil, let srcset = attribute("srcset", in: imageTag) {
                    let firstCandidate = srcset.split(separator: ",", maxSplits: 1).first
                    if let firstCandidate {
                        let firstURL = firstCandidate
                            .trimmingCharacters(in: .whitespaces)
                            .split(whereSeparator: { $0.isWhitespace })
                            .first
                        imageValue = firstURL.map(String.init)
                    }
                }
            }

            var cover: String?
            if let imageValue, !imageValue.isEmpty {
                cover = URL(string: imageValue, relativeTo: baseURL)?.absoluteURL.absoluteString
            }

            let developerContainer = innerHTML(className: "game_author", in: card)
                ?? innerHTML(className: "author", in: card)
            let developerAnchor = developerContainer.flatMap { anchors(in: $0).first }
                ?? allAnchors.first(where: {
                    $0.classes.contains("game_author") || $0.classes.contains("author")
                })
            let developer = developerAnchor.flatMap { cleanText($0.html) }
                ?? developerContainer.flatMap(cleanText)
            let developerURL = developerAnchor?.href.flatMap {
                URL(string: $0, relativeTo: baseURL)?.absoluteURL.absoluteString
            }

            let description = ["game_text", "game_description", "game_blurb"]
                .compactMap { className in innerHTML(className: className, in: card) }
                .first
                .flatMap(cleanText)

            let platformValues = ["game_platform", "game_platforms", "web_flag"].flatMap { className in
                elementsWithClass(className, in: card).compactMap(cleanText)
            }

            var result: [String: Any] = ["id": id, "title": title, "platforms": platformValues]
            if let link { result["url"] = link }
            if let cover { result["coverURL"] = cover }
            if let description, !description.isEmpty { result["description"] = description }
            if let developer, !developer.isEmpty { result["developer"] = developer }
            if let developerURL { result["developerProfileURL"] = developerURL }
            return result
        }
    }

    private struct Anchor {
        let classes: String
        let href: String?
        let html: String
    }

    private static func anchors(in html: String) -> [Anchor] {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<a\b([^>]*)>(.*?)</a>"#) else { return [] }
        let nsHTML = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).map { match in
            let attributes = nsHTML.substring(with: match.range(at: 1))
            return Anchor(
                classes: attribute("class", in: attributes) ?? "",
                href: attribute("href", in: attributes),
                html: nsHTML.substring(with: match.range(at: 2))
            )
        }
    }

    private static func tags(named name: String, in html: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<" + NSRegularExpression.escapedPattern(for: name) + #"\b([^>]*)>"#) else { return [] }
        let nsHTML = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length)).map {
            nsHTML.substring(with: $0.range(at: 1))
        }
    }

    private static func firstTagAttributes(_ name: String, in html: String) -> String? {
        tags(named: name, in: html).first
    }

    private static func attribute(_ name: String, in source: String) -> String? {
        let pattern = "(?is)(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(location: 0, length: (source as NSString).length)) else {
            return nil
        }
        let nsSource = source as NSString
        for index in 1...3 where match.range(at: index).location != NSNotFound {
            return decodeEntities(nsSource.substring(with: match.range(at: index)))
        }
        return nil
    }

    private static func innerHTML(className: String, in html: String) -> String? {
        let pattern = #"(?is)<([a-z0-9]+)\b([^>]*)>(.*?)</\1>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        for match in matches {
            let attributes = nsHTML.substring(with: match.range(at: 2))
            let classes = attribute("class", in: attributes) ?? ""
            guard classes.split(whereSeparator: { $0.isWhitespace }).contains(where: { String($0) == className }),
                  match.range(at: 3).location != NSNotFound else {
                continue
            }
            return nsHTML.substring(with: match.range(at: 3))
        }
        return nil
    }

    private static func elementsWithClass(_ className: String, in html: String) -> [String] {
        guard let value = innerHTML(className: className, in: html) else { return [] }
        return [value]
    }

    private static func cleanText(_ html: String) -> String? {
        let withoutScripts = html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        let decoded = decodeEntities(withoutScripts)
        let whitespaceNormalized = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let punctuationNormalized = whitespaceNormalized.replacingOccurrences(
            of: #"\s+([.,!?;:，。！？；：、])"#,
            with: "$1",
            options: .regularExpression
        )
        let compact = punctuationNormalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? nil : compact
    }

    private static func decodeEntities(_ source: String) -> String {
        var result = source
        let replacements = [
            "&nbsp;": " ", "&#160;": " ", "&amp;": "&",
            "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&#x2F;": "/"
        ]
        for (entity, value) in replacements {
            result = result.replacingOccurrences(of: entity, with: value, options: .caseInsensitive)
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) else { return result }
        let nsResult = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsResult.length)).reversed()
        for match in matches {
            let token = nsResult.substring(with: match.range(at: 1))
            let value: UInt32?
            if token.lowercased().hasPrefix("x") {
                value = UInt32(String(token.dropFirst()), radix: 16)
            } else {
                value = UInt32(token)
            }
            if let value, let scalar = UnicodeScalar(value) {
                result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
            }
        }
        return result
    }
}
