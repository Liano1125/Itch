import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let defaults = UserDefaults.standard
    private let cachePrefix = "itchPocket.creatorAvatarURL.v3."
    private let failurePrefix = "itchPocket.creatorAvatarFailure.v2."
    private let failureCacheDuration: TimeInterval = 6 * 60 * 60

    private init() {}

    func avatarURL(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        let cacheKeys = [authorURL, gameURL].compactMap { $0?.absoluteString }
        for value in cacheKeys {
            if let cached = defaults.string(forKey: cachePrefix + value),
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
        if resolvedAuthorURL == nil {
            if let gamePage = pages.first(where: { $0.0 == gameURL }),
               let extracted = extractAuthorURL(from: gamePage.1, baseURL: gameURL) {
                resolvedAuthorURL = extracted
                if let html = try? await fetchHTML(extracted) {
                    pages.insert((extracted, html), at: 0)
                }
            }
        }

        let patreonURL = pages.lazy.compactMap {
            self.extractPatreonURL(from: $0.1, baseURL: $0.0)
        }.first
        let avatar: URL?
        if let patreonURL,
           let patreonHTML = try? await fetchHTML(patreonURL) {
            avatar = extractOpenGraphImage(from: patreonHTML, baseURL: patreonURL)
        } else {
            avatar = nil
        }

        let allKeys = Array(Set(cacheKeys + [resolvedAuthorURL?.absoluteString].compactMap { $0 }))
        guard let avatar else {
            for value in allKeys {
                defaults.set(Date(), forKey: failurePrefix + value)
            }
            return nil
        }

        for value in allKeys {
            defaults.set(avatar.absoluteString, forKey: cachePrefix + value)
            defaults.removeObject(forKey: failurePrefix + value)
        }
        return avatar
    }

    /// Resolves creator avatars in priority order: itch.io, Patreon, F95Zone, then Discord.
    func avatarURL(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        let cacheKeys = Array(Set([authorURL, gameURL].compactMap { $0?.absoluteString }))
        for value in cacheKeys {
            if let cached = defaults.string(forKey: cachePrefix + value),
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

        // 1. itch.io creator profile avatar
        var avatar = pages.lazy.compactMap {
            extractItchAvatar(from: $0.1, baseURL: $0.0)
        }.first

        // 2. Patreon creator page avatar
        if avatar == nil,
           let patreonURL = pages.lazy.compactMap({ extractPatreonURL(from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(patreonURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: patreonURL)
        }

        // 3. F95Zone creator/thread profile avatar
        if avatar == nil,
           let f95URL = pages.lazy.compactMap({ extractExternalURL(domain: "f95zone.to", from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(f95URL) {
            avatar = extractProfileAvatar(from: html, baseURL: f95URL)
                ?? extractOpenGraphImage(from: html, baseURL: f95URL)
        }

        // 4. Discord public invite/profile metadata as the final fallback
        if avatar == nil,
           let discordURL = pages.lazy.compactMap({ extractExternalURL(domain: "discord.gg|discord.com", from: $0.1, baseURL: $0.0) }).first,
           let html = try? await fetchHTML(discordURL) {
            avatar = extractOpenGraphImage(from: html, baseURL: discordURL)
                ?? extractProfileAvatar(from: html, baseURL: discordURL)
        }

        let allKeys = Array(Set(cacheKeys + [resolvedAuthorURL?.absoluteString].compactMap { $0 }))
        guard let avatar else {
            for value in allKeys {
                defaults.set(Date(), forKey: failurePrefix + value)
            }
            return nil
        }

        for value in allKeys {
            defaults.set(avatar.absoluteString, forKey: cachePrefix + value)
            defaults.removeObject(forKey: failurePrefix + value)
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
        let imageTags = matches(#"<img\\b[^>]*>"#, in: html)
        for tag in imageTags {
            let className = attribute("class", from: tag)?.lowercased() ?? ""
            let alt = attribute("alt", from: tag)?.lowercased() ?? ""
            guard className.contains("avatar") || className.contains("user_avatar")
                    || alt.contains("avatar") else { continue }
            if let raw = attribute("data-lazy_src", from: tag)
                ?? attribute("data-lazy-src", from: tag)
                ?? attribute("data-src", from: tag)
                ?? attribute("src", from: tag),
               let url = imageURL(raw, relativeTo: baseURL) {
                return url
            }
        }
        return nil
    }

    private func extractProfileAvatar(from html: String, baseURL: URL) -> URL? {
        let imageTags = matches(#"<img\\b[^>]*>"#, in: html)
        for tag in imageTags {
            let className = attribute("class", from: tag)?.lowercased() ?? ""
            let id = attribute("id", from: tag)?.lowercased() ?? ""
            guard className.contains("avatar") || className.contains("user-avatar")
                    || id.contains("avatar") else { continue }
            if let raw = attribute("data-src", from: tag)
                ?? attribute("src", from: tag),
               let url = imageURL(raw, relativeTo: baseURL) {
                return url
            }
        }
        return nil
    }

    private func extractExternalURL(domain: String, from html: String, baseURL: URL) -> URL? {
        let pattern = #"<a[^>]+href=["'](https?://(?:www\\.)?(?:\\#DOMAIN#)[^"']*)["']"#
            .replacingOccurrences(of: "#DOMAIN#", with: domain)
        guard let raw = firstCapture(pattern, in: html, options: [.caseInsensitive]),
              let url = URL(string: decodeEntities(raw), relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func attribute(_ name: String, from tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:^|\\s)\\#NAME#\\s*=\\s*["']([^"']+)["']"#
            .replacingOccurrences(of: "#NAME#", with: escaped)
        return firstCapture(pattern, in: tag, options: [.caseInsensitive])
            .map(decodeEntities)
    }

    private func imageURL(_ value: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: decodeEntities(value), relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              !url.absoluteString.hasPrefix("data:") else { return nil }
        return url
    }

    private func extractAuthorURL(from html: String, baseURL: URL?) -> URL? {
        let pattern = #"(?:class=["'][^"']*game_author[^"']*["'][^>]*>.*?<a[^>]+href=["']([^"']+))"#
        return firstCapture(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators])
            .flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
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
            if let value = firstCapture(pattern, in: html, options: [.caseInsensitive]),
               let url = URL(string: decodeEntities(value), relativeTo: baseURL)?.absoluteURL {
                return url
            }
        }
        return nil
    }

    private func firstCapture(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options
    ) -> String? {
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
