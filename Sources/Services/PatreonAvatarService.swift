import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let defaults = UserDefaults.standard
    private let cachePrefix = "itchPocket.patreonAvatarURL.v1."

    private init() {}

    func avatarURL(authorURL: URL?, gameURL: URL? = nil, fallbackURL: URL? = nil) async -> URL? {
        let keyURL = authorURL ?? gameURL
        guard let keyURL else { return fallbackURL }
        let key = cachePrefix + keyURL.absoluteString
        if let cached = defaults.string(forKey: key), let url = URL(string: cached) {
            return url
        }

        do {
            var profileURL = authorURL
            var html = try await fetchHTML(profileURL ?? gameURL)
            if profileURL == nil {
                profileURL = extractAuthorURL(from: html, baseURL: gameURL)
                if let profileURL {
                    html = try await fetchHTML(profileURL)
                }
            }

            guard let patreonURL = extractPatreonURL(from: html, baseURL: profileURL),
                  let patreonHTML = try? await fetchHTML(patreonURL),
                  let avatar = extractOpenGraphImage(from: patreonHTML, baseURL: patreonURL) else {
                return fallbackURL
            }

            defaults.set(avatar.absoluteString, forKey: key)
            if let profileURL {
                defaults.set(avatar.absoluteString, forKey: cachePrefix + profileURL.absoluteString)
            }
            return avatar
        } catch {
            return fallbackURL
        }
    }

    private func fetchHTML(_ url: URL?) async throws -> String {
        guard let url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    private func extractAuthorURL(from html: String, baseURL: URL?) -> URL? {
        let pattern = #"(?:class=["'][^"']*game_author[^"']*["'][^>]*>.*?<a[^>]+href=["']([^"']+))"#
        return firstCapture(pattern, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]).flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
    }

    private func extractPatreonURL(from html: String, baseURL: URL?) -> URL? {
        let pattern = #"<a[^>]+href=["'](https?://(?:www\.)?patreon\.com/[^"'#? ]+|/[^"'#? ]*patreon[^"'#? ]*)["']"#
        return firstCapture(pattern, in: html, options: [.caseInsensitive]).flatMap { URL(string: decodeEntities($0), relativeTo: baseURL)?.absoluteURL }
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
