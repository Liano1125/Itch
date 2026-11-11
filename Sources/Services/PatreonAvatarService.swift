import Foundation

@MainActor
final class PatreonAvatarService {
    static let shared = PatreonAvatarService()

    private let failureCacheDuration: TimeInterval = 6 * 60 * 60
    private let avatarCacheDuration: TimeInterval = 7 * 24 * 60 * 60
    private let database = AppDatabase.shared
    private lazy var appStateRepository = AppStateRepository(database: database)
    private lazy var developerRepository = DeveloperRepository(database: database)
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var didInvalidateLegacyCache = false

    private init() {}

    /// Resolves and caches one avatar per canonical creator profile, shared by all games.
    /// Avatar priority: Patreon → itch.io → F95Zone → Discord.
    /// Resolves a creator avatar once and stores it on the canonical Developer row.
    /// All games by the same creator then read the same avatar metadata.
    func avatarURL(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        await invalidateLegacyAvatarCacheIfNeeded()
        guard let identity = authorURL ?? gameURL else { return nil }
        let key = canonicalKey(for: identity)
        if let task = inFlight[key] { return await task.value }

        if let authorURL, let cached = cachedAvatar(for: authorURL) {
            if isAvatarFresh(for: authorURL) { return cached }
            let refreshTask = Task { await self.resolveAvatarURL(authorURL: authorURL, gameURL: gameURL, forceRefresh: true) }
            inFlight[key] = refreshTask
            Task {
                _ = await refreshTask.value
                self.inFlight.removeValue(forKey: key)
            }
            return cached
        }

        let task = Task { await self.resolveAvatarURL(authorURL: authorURL, gameURL: gameURL) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    func refreshAvatar(authorURL: URL?, gameURL: URL? = nil) async -> URL? {
        guard let identity = authorURL ?? gameURL else { return nil }
        let key = canonicalKey(for: identity)
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.resolveAvatarURL(authorURL: authorURL, gameURL: gameURL, forceRefresh: true) }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        return result
    }

    private func resolveAvatarURL(authorURL: URL?, gameURL: URL?, forceRefresh: Bool = false) async -> URL? {
        if !forceRefresh, let authorURL, let cached = cachedAvatar(for: authorURL) { return cached }
        if !forceRefresh, let authorURL, isFailureCached(for: authorURL) { return cachedAvatar(for: authorURL) }

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
        // A game's page may contain Patreon links for collaborators, publishers,
        // or unrelated promotions. Resolve Patreon only from the canonical
        // primary author's own itch.io profile page.
        let authorProfilePage = PatreonCreatorLinkResolver.authorProfilePage(
            in: pages,
            matching: resolvedAuthorURL
        )
        if let authorProfilePage,
           let patreonURL = PatreonCreatorLinkResolver.patreonURL(
                in: authorProfilePage.1,
                baseURL: authorProfilePage.0
           ),
           let html = try? await fetchHTML(patreonURL) {
            let expectedName = resolvedAuthorURL.flatMap { try? developerRepository.developer(id: canonicalKey(for: $0))?.name }
            avatar = extractPatreonProfileAvatar(from: html, baseURL: patreonURL, expectedName: expectedName)
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
            if try developerRepository.developer(id: key) == nil {
                try developerRepository.upsertIdentity(id: key, name: "itch.io 开发者", profileURL: identity.absoluteString)
            }
            guard let avatar else {
                try appStateRepository.setDate(Date(), for: "avatarFailure.\(key)")
                return cachedAvatar(for: identity)
            }
            try developerRepository.setAvatar(id: key, url: avatar.absoluteString, source: avatarSource, resolvedAt: .now)
            try appStateRepository.setDate(nil, for: "avatarFailure.\(key)")
            return avatar
        } catch {
            print("itchPocket developer avatar persistence failed: \(error)")
            return avatar
        }
    }

    private func cachedAvatar(for url: URL) -> URL? {
        let key = canonicalKey(for: url)
        guard let value = try? developerRepository.developer(id: key)?.avatarURL else { return nil }
        return URL(string: value)
    }

    private func isAvatarFresh(for url: URL) -> Bool {
        let key = canonicalKey(for: url)
        guard let resolvedAt = try? developerRepository.developer(id: key)?.avatarResolvedAt else { return false }
        return Date().timeIntervalSince(resolvedAt) < avatarCacheDuration
    }

    private func extractPatreonProfileAvatar(from html: String, baseURL: URL, expectedName: String?) -> URL? {
        let normalizedName = expectedName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        var ranked: [(url: URL, score: Int)] = []
        func add(_ raw: String?, score: Int) {
            guard let raw, let url = imageURL(raw, relativeTo: baseURL),
                  let host = url.host?.lowercased(),
                  host.contains("patreonusercontent.com") else { return }
            if let index = ranked.firstIndex(where: { $0.url.absoluteString == url.absoluteString }) {
                if score > ranked[index].score { ranked[index].score = score }
            } else {
                ranked.append((url, score))
            }
        }

        // Patreon markup changes frequently. Prefer semantic avatar/profile evidence,
        // then use the creator's serialized profile fields as a fallback.
        for tag in matches(#"<img\b[^>]*>"#, in: html) {
            let alt = (attribute("alt", from: tag) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let className = (attribute("class", from: tag) ?? "").lowercased()
            let id = (attribute("id", from: tag) ?? "").lowercased()
            let testID = (attribute("data-testid", from: tag) ?? "").lowercased()
            let context: String = {
                guard let range = html.range(of: tag) else { return "" }
                let lower = html.index(range.lowerBound, offsetBy: -min(240, html.distance(from: html.startIndex, to: range.lowerBound)))
                let upper = html.index(range.upperBound, offsetBy: min(240, html.distance(from: range.upperBound, to: html.endIndex)))
                return String(html[lower..<upper]).lowercased()
            }()

            var raw = attribute("data-src", from: tag)
            if raw == nil { raw = attribute("data-lazy-src", from: tag) }
            if raw == nil { raw = attribute("data-original", from: tag) }
            if raw == nil { raw = attribute("src", from: tag) }
            if raw == nil, let srcset = attribute("srcset", from: tag),
               let largest = srcset.split(separator: ",").last {
                raw = String(largest).split(separator: " ").first.map(String.init)
            }
            var score = 0
            if normalizedName.map({ !$0.isEmpty && alt == $0 }) == true { score += 120 }
            if className.contains("avatar") || id.contains("avatar") || testID.contains("avatar") { score += 90 }
            if className.contains("profile") || id.contains("profile") || testID.contains("profile") { score += 55 }
            if context.contains("avatar") || context.contains("profilepicture") || context.contains("profile_picture") { score += 35 }
            if !alt.isEmpty { score += 5 }
            add(raw, score: score)
        }

        // Hydrated Patreon page state often exposes avatar/image_url independently
        // of the rendered img element, including animated GIF source URLs.
        let jsonPatterns = [
            #""(?:avatar|avatar_url|profile_image_url|profilePicture|profile_picture)"\s*:\s*"([^"]+)""#,
            #""image_url"\s*:\s*"([^"]+)""#
        ]
        for (index, pattern) in jsonPatterns.enumerated() {
            for raw in captures(pattern, in: html) {
                add(raw, score: index == 0 ? 110 : 65)
            }
        }

        // Open Graph is a lower-confidence fallback only when Patreon serves its
        // own CDN image; never accept unrelated post or third-party artwork.
        for pattern in [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#
        ] {
            add(firstCapture(pattern, in: html, options: [.caseInsensitive]), score: 20)
        }

        return ranked.max(by: { $0.score < $1.score })?.url
    }

    private func invalidateLegacyAvatarCacheIfNeeded() async {
        guard !didInvalidateLegacyCache else { return }
        didInvalidateLegacyCache = true
        let key = "itchPocket.avatarResolver.version"
        let current = try? appStateRepository.state(for: key)?.stringValue
        guard current != "2" else { return }
        do {
            try developerRepository.invalidateAvatarCaches()
            try appStateRepository.setString("2", for: key)
        } catch {
            print("itchPocket legacy avatar cache invalidation failed: \(error)")
        }
    }

    private func isFailureCached(for url: URL) -> Bool {
        let key = canonicalKey(for: url)
        guard let failedAt = try? appStateRepository.state(for: "avatarFailure.\(key)")?.dateValue else { return false }
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

    private func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let capture = Range(match.range(at: 1), in: text) else { return nil }
            return decodeEntities(String(text[capture]))
        }
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
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
    }
}
