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
    private let baseURL = URL(string: "https://api.itch.io")!
    private let session: URLSession
    init(session: URLSession = .shared) {
        self.session = session
    }
    // MARK: - Profile
    func fetchProfile(token: String) async throws -> ItchUser {
        let url = baseURL.appendingPathComponent("profile")
        let data = try await request(url: url, token: token)
        return try JSONDecoder.itchDecoder.decode(
            ItchProfileResponse.self,
            from: data
        ).user
    }
    // MARK: - Credentials
    func fetchCredentials(token: String) async throws -> ItchCredentialsInfo {
        let url = baseURL
            .appendingPathComponent("credentials")
            .appendingPathComponent("info")
        let data = try await request(url: url, token: token)
        return try JSONDecoder.itchDecoder.decode(
            ItchCredentialsInfo.self,
            from: data
        )
    }
    // MARK: - Owned Games
    func fetchOwnedGames(token: String) async throws -> [ItchOwnedGame] {
        var page = 1
        let perPage = 100
        var games: [ItchOwnedGame] = []
        var seenGameIDs = Set<Int>()
        while true {
            let endpoint = baseURL
                .appendingPathComponent("profile")
                .appendingPathComponent("owned-keys")
            var components = URLComponents(
                url: endpoint,
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "per_page", value: String(perPage))
            ]
            guard let url = components.url else {
                throw ItchAPIError.invalidResponse
            }
            let data = try await request(url: url, token: token)
            let response: ItchOwnedKeysResponse
            do {
                response = try JSONDecoder.itchDecoder.decode(
                    ItchOwnedKeysResponse.self,
                    from: data
                )
            } catch let error as DecodingError {
                let details: String
                switch error {
                case .typeMismatch(let type, let context):
                    details = """
                    类型不匹配：\(type)
                    位置：\(context.codingPath.map(\.stringValue).joined(separator: "."))
                    原因：\(context.debugDescription)
                    """
                case .valueNotFound(let type, let context):
                    details = """
                    缺少值：\(type)
                    位置：\(context.codingPath.map(\.stringValue).joined(separator: "."))
                    原因：\(context.debugDescription)
                    """
                case .keyNotFound(let key, let context):
                    details = """
                    缺少字段：\(key.stringValue)
                    位置：\(context.codingPath.map(\.stringValue).joined(separator: "."))
                    原因：\(context.debugDescription)
                    """
                case .dataCorrupted(let context):
                    details = """
                    数据损坏
                    位置：\(context.codingPath.map(\.stringValue).joined(separator: "."))
                    原因：\(context.debugDescription)
                    """
                @unknown default:
                    details = error.localizedDescription
                }
                print("itchPocket JSON 解码错误：\(details)")
                throw NSError(
                    domain: "itchPocket.JSON",
                    code: 1001,
                    userInfo: [
                        NSLocalizedDescriptionKey: details
                    ]
                )
            }
            // 空页面代表已经读取完所有记录
            guard !response.ownedKeys.isEmpty else {
                break
            }
            // 同一个游戏可能有多个领取记录，只显示一次
            for ownedKey in response.ownedKeys {
                guard let game = ownedKey.game else {
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
