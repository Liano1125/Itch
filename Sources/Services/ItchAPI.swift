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

        return response.user
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
