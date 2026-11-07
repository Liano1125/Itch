import Foundation

enum ItchAPIError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回的数据无法识别"

        case let .httpError(code, message):
            return "请求失败（HTTP \(code)）：\(message)"

        case .missingToken:
            return "尚未登录 itch.io"
        }
    }
}

final class ItchAPI {
    private let baseURL = URL(
        string: "https://api.itch.io"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Profile

    func fetchProfile(token: String) async throws -> ItchUser {
        let url = baseURL.appendingPathComponent("profile")

        let data = try await request(
            url: url,
            token: token
        )

        let response = try JSONDecoder.itchDecoder.decode(
            ItchProfileResponse.self,
            from: data
        )

        var user = response.user
        user.accountCreatedAt = await fetchAccountCreatedAt(username: user.username)
        return user
    }

    private func fetchAccountCreatedAt(username: String) async -> Date? {
        guard let encodedUsername = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://itch.io/profile/\(encodedUsername)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }

        // itch.io 的注册时间文案可能使用英文月份缩写或全称；
        // 例如 “A member registered Jun 12, 2020 (12 Jun 2020 @ 08:30 UTC)”。
        let plainText = html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        let patterns = [
            #"A member registered [A-Za-z]{3,9} \d{1,2}, \d{4} \((\d{1,2} [A-Za-z]{3,9} \d{4} @ \d{2}:\d{2} UTC)\)"#,
            #"A member registered ([A-Za-z]{3,9} \d{1,2}, \d{4})"#,
            #"registered[^A-Za-z0-9]{0,24}(\d{1,2} [A-Za-z]{3,9} \d{4})"#
        ]

        var candidates: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(plainText.startIndex..., in: plainText)
            if let match = regex.firstMatch(in: plainText, range: range),
               let valueRange = Range(match.range(at: 1), in: plainText) {
                candidates.append(String(plainText[valueRange]))
            }
        }

        let formats = [
            "d MMMM yyyy ' @ ' HH:mm 'UTC'",
            "d MMM yyyy ' @ ' HH:mm 'UTC'",
            "MMMM d, yyyy",
            "MMM d, yyyy",
            "d MMMM yyyy",
            "d MMM yyyy"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        for candidate in candidates {
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: candidate) {
                    return date
                }
            }
        }
        return nil
    }

    // MARK: - Credentials

    func fetchCredentials(
        token: String
    ) async throws -> ItchCredentialsInfo {

        let url = baseURL
            .appendingPathComponent("credentials")
            .appendingPathComponent("info")

        let data = try await request(
            url: url,
            token: token
        )

        return try JSONDecoder.itchDecoder.decode(
            ItchCredentialsInfo.self,
            from: data
        )
    }

    // MARK: - Fetch Collections

    func fetchCollections(
        token: String
    ) async throws -> [ItchCollection] {

        let url = baseURL
            .appendingPathComponent("profile")
            .appendingPathComponent("collections")

        let data = try await request(
            url: url,
            token: token
        )

        let response = try JSONDecoder.itchDecoder.decode(
            ItchCollectionsResponse.self,
            from: data
        )

        return response.collections.values
    }

    // MARK: - Fetch Collection Games

    func fetchCollectionGames(
        collectionID: Int,
        token: String
    ) async throws -> [ItchGame] {

        var page = 1
        let perPage = 500

        var games: [ItchGame] = []
        var seenGameIDs = Set<Int>()

        while true {
            let endpoint = baseURL
                .appendingPathComponent("collections")
                .appendingPathComponent(String(collectionID))
                .appendingPathComponent("collection-games")

            var components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )!

            components.queryItems = [
                URLQueryItem(
                    name: "page",
                    value: String(page)
                ),
                URLQueryItem(
                    name: "per_page",
                    value: String(perPage)
                )
            ]

            guard let url = components.url else {
                throw ItchAPIError.invalidResponse
            }

            let data = try await request(
                url: url,
                token: token
            )

            let response = try JSONDecoder.itchDecoder.decode(
                ItchCollectionGamesResponse.self,
                from: data
            )

            let entries = response.collectionGames.values

            // 空页面代表已经读取完所有游戏
            guard !entries.isEmpty else {
                break
            }

            // 保留合集中的原始排列顺序，并按游戏 ID 去重
            for entry in entries {
                guard let game = entry.game else {
                    continue
                }

                if seenGameIDs.insert(game.id).inserted {
                    games.append(game)
                }
            }

            page += 1
        }

        return games
    }

    // MARK: - Network

    private func request(
        url: URL,
        token: String
    ) async throws -> Data {

        var request = URLRequest(url: url)

        request.httpMethod = "GET"

        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )

        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )

        let (data, response) = try await session.data(
            for: request
        )

        guard let http = response as? HTTPURLResponse else {
            throw ItchAPIError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = String(
                data: data,
                encoding: .utf8
            ) ?? "未知错误"

            throw ItchAPIError.httpError(
                http.statusCode,
                message
            )
        }

        return data
    }
}

// MARK: - JSON Decoder

extension JSONDecoder {
    static var itchDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
