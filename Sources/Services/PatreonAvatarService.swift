import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let defaults = UserDefaults.standard
    private let cachePrefix = "itchPocket.patreonAvatarURL.v2."
    private let failurePrefix = "itchPocket.patreonAvatarFailure.v1."
    private let failureCacheDuration: TimeInterval = 6 * 60 * 60

    private init() {}

    /// Returns only a verified Patreon profile image URL.
    /// The caller is responsible for displaying the itch.io avatar as a fallback.
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
        guard let patreonURL,
              let patreonHTML = try? await fetchHTML(patreonURL),
              let avatar = extractOpenGraphImage(from: patreonHTML, baseURL: patreonURL) else {
            return nil
        }

        for value in cacheKeys + [resolvedAuthorURL?.absoluteString].compactMap({ $0 }) {
            defaults.set(avatar.absoluteString, forKey: cachePrefix + value)
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
