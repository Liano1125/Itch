import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let failureCacheDuration: TimeInterval = 6 * 60 * 60
    private let database = AppDatabase.shared

    private init() {}

    /// Resolves and caches one avatar per canonical creator profile, shared by all games.
    /// Avatar priority: Patreon → itch.io → F95Zone → Discord.
    /// Resolves a creator avatar once and stores it on the canonical Developer row.
    /// All games by the same creator then read the same avatar metadata.
    func avatarURL(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        if let authorURL, let cached = cachedAvatar(for: authorURL) { return cached }
        if let authorURL, isFailureCached(for: authorURL) { return nil }

        var pages: [(URL, String)] = []
        if let authorURL, let html = try? await fetchHTML(authorURL) {
            pages.append((authorURL, html))
        }
        if let gameURL, !pages.contains(where: { $0.0 == gameURL }),
           let html = try? await fetchHTML(gameURL) {
            pages.append((gameURL, html))
        }

        var resolvedAuthorURL = authorURL
        if resolvedAuthorURL == nil,
           let gamePage = pages.first(where: { $0.0 == gameURL }),
           let extracted = extractAuthorURL(from: gamePage.1, baseURL: gameURL) {
            resolvedAuthorURL = extracted
            if let cached = cachedAvatar(for: extracted) { return cached }
            if let html = try? await fetchHTML(extracted) {
                pages.insert((extracted, html), at: 0)
            }
        }

        var avatar: URL?
        var avatarSource: String?
        if let patreonURL = pages.lazy.compactMap({ self.extractPatreonURL(from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(patreonURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: patreonURL)
                ?? extractProfileAvatar(from: html, baseURL: patreonURL)
            if avatar != nil { avatarSource = "patreon" }
        }

        if avatar == nil {
            avatar = pages.lazy.compactMap { self.extractItchAvatar(from: $0.1, baseURL: $0.0) }.first
            if avatar != nil { avatarSource = "itch" }
        }

        if avatar == nil,
           let f95URL = pages.lazy.compactMap({ self.extractExternalURL(domains: ["f95zone.to"], from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(f95URL) {
            avatar = extractProfileAvatar(from: html, baseURL: f95URL)
                ?? extractOpenGraphImage(from: html, baseURL: f95URL)
            if avatar != nil { avatarSource = "f95zone" }
        }

        if avatar == nil,
           let discordURL = pages.lazy.compactMap({ self.extractExternalURL(domains: ["discord.gg", "discord.com"], from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(discordURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: discordURL)
                ?? extractProfileAvatar(from: html, baseURL: discordURL)
            if avatar != nil { avatarSource = "discord" }
        }

        guard let identity = resolvedAuthorURL ?? authorURL else { return avatar }
        let key = canonicalKey(for: identity)
        do {
            if try database.developer(id: key) == nil {
                try database.upsertDeveloper(id: key, name: "itch.io 开发者", profileURL: identity.absoluteString)
            }
            guard let avatar else {
                try database.setState(Date(), for: "avatarFailure.\(key)")
                return nil
            }
            try database.setDeveloperAvatar(id: key, url: avatar.absoluteString, source: avatarSource)
            try database.setState(nil as Date?, for: "avatarFailure.\(key)")
            return avatar
        } catch {
            print("itchPocket developer avatar persistence failed: \(error)")
            return avatar
        }
    }

    private func cachedAvatar(for url: URL) -> URL? {
        let key = canonicalKey(for: url)
        guard let value = try? database.developer(id: key)?.avatarURL else { return nil }
        return URL(string: value)
    }

    private func isFailureCached(for url: URL) -> Bool {
        let key = canonicalKey(for: url)
        guard let failedAt = try? database.state(for: "avatarFailure.\(key)")?.dateValue else { return false }
        return Date().timeIntervalSince(failedAt) < failureCacheDuration
    }

    private func canonicalKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        if components.path.count > 1 {
            components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return components.string ?? url.absoluteString
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func extractItchAvatar(from html: String, baseURL: URL) -> URL? {
        for tag in matches(#"<(?:img|div)\b[^>]*>"#, in: html) {
            let className = (attribute("class", from: tag) ?? "").lowercased()
            let alt = (attribute("alt", from: tag) ?? "").lowercased()
            guard className.contains("avatar") || alt.contains("avatar") else { continue }
            let style = attribute("style", from: tag) ?? ""
            let background = firstCapture(#"url\(['"]?([^)'"]+)['"]?\)"#, in: style, options: [.caseInsensitive])
            let raw = attribute("data-lazy_src", from: tag)
                ?? attribute("data-lazy-src", from: tag)
                ?? attribute("data-src", from: tag)
                ?? attribute("src", from: tag)
                ?? background
            if let raw, let url = imageURL(raw, relativeTo: baseURL) { return url }
        }
        return nil
    }

    private func extractProfileAvatar(from html: String, baseURL: URL) -> URL? {
        for tag in matches(#"<(?:img|div)\b[^>]*>"#, in: html) {
            let className = (attribute("class", from: tag) ?? "").lowercased()
            let id = (attribute("id", from: tag) ?? "").lowercased()
            guard className.contains("avatar") || id.contains("avatar") else { continue }
            let style = attribute("style", from: tag) ?? ""
            let background = firstCapture(#"url\(['"]?([^)'"]+)['"]?\)"#, in: style, options: [.caseInsensitive])
            let raw = attribute("data-src", from: tag) ?? attribute("src", from: tag) ?? background
            if let raw, let url = imageURL(raw, relativeTo: baseURL) { return url }
        }
        return nil
    }

    private func extractExternalURL(domains: [String], from html: String, baseURL: URL) -> URL? {
        for tag in matches(#"<a\b[^>]*>"#, in: html) {
            guard let raw = attribute("href", from: tag),
                  let url = URL(string: decodeEntities(raw), relativeTo: baseURL)?.absoluteURL,
                  let host = url.host?.lowercased() else { continue }
            if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return url
            }
        }
        return nil
    }

    private func extractAuthorURL(from html: String, baseURL: URL?) -> URL? {
        let pattern = #"(?:class=["'][^"']*game_author[^"']*["'][^>]*>.*?<a[^>]+href=["']([^"']+))"#
        return firstCapture(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
    }

    private func extractPatreonURL(from html: String, baseURL: URL?) -> URL? {
        let pattern = #"<a[^>]+href=["'](https?://(?:www\.)?patreon\.com/[^"'#? ]+|/[^"'#? ]*patreon[^"'#? ]*)["']"#
        return firstCapture(pattern, in: html, options: [.caseInsensitive])
            .flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
    }

    private func extractOpenGraphImage(from html: String, baseURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#
        ]
        for pattern in patterns {
            if let raw = firstCapture(pattern, in: html, options: [.caseInsensitive]),
               let url = imageURL(raw, relativeTo: baseURL) {
                return url
            }
        }
        return nil
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func attribute(_ name: String, from tag: String) -> String? {
        let pattern = #"(?:^|\s)\#(name)\s*=\s*["']([^"']+)["']"#
        return firstCapture(pattern, in: tag, options: [.caseInsensitive]).map(decodeEntities)
    }

    private func imageURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: decodeEntities(value), relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
