import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let defaults = UserDefaults.standard
    private let cachePrefix = "itchPocket.creatorAvatarURL.v4."
    private let failurePrefix = "itchPocket.creatorAvatarFailure.v2."
    private let failureCacheDuration: TimeInterval = 6 * 60 * 60

    private init() {}

    /// Avatar priority: Patreon → itch.io → F95Zone → Discord.
    func avatarURL(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        let cacheKeys = Array(Set([authorURL, gameURL].compactMap { $0?.absoluteString }))
        for key in cacheKeys {
            if let cached = defaults.string(forKey: cachePrefix + key),
               let url = URL(string: cached) {
                return url
            }
        }

        if cacheKeys.contains(where: { key in
            guard let failedAt = defaults.object(forKey: failurePrefix + key) as? Date else { return false }
            return Date().timeIntervalSince(failedAt) < failureCacheDuration
        }) {
            return nil
        }

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
            if let html = try? await fetchHTML(extracted) {
                pages.insert((extracted, html), at: 0)
            }
        }

        // 1. Patreon creator avatar
        var avatar: URL?
        if let patreonURL = pages.lazy.compactMap({ self.extractPatreonURL(from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(patreonURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: patreonURL)
                ?? extractProfileAvatar(from: html, baseURL: patreonURL)
        }

        // 2. itch.io creator avatar
        if avatar == nil {
            avatar = pages.lazy.compactMap { self.extractItchAvatar(from: $0.1, baseURL: $0.0) }.first
        }

        // 3. F95Zone avatar
        if avatar == nil,
           let f95URL = pages.lazy.compactMap({ self.extractExternalURL(domains: ["f95zone.to"], from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(f95URL) {
            avatar = extractProfileAvatar(from: html, baseURL: f95URL)
                ?? extractOpenGraphImage(from: html, baseURL: f95URL)
        }

        // 4. Discord metadata as the final fallback
        if avatar == nil,
           let discordURL = pages.lazy.compactMap({ self.extractExternalURL(domains: ["discord.gg", "discord.com"], from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(discordURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: discordURL)
                ?? extractProfileAvatar(from: html, baseURL: discordURL)
        }

        let allKeys = Array(Set(cacheKeys + [resolvedAuthorURL?.absoluteString].compactMap { $0 }))
        guard let avatar else {
            for key in allKeys { defaults.set(Date(), forKey: failurePrefix + key) }
            return nil
        }

        for key in allKeys {
            defaults.set(avatar.absoluteString, forKey: cachePrefix + key)
            defaults.removeObject(forKey: failurePrefix + key)
        }
        return avatar
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
