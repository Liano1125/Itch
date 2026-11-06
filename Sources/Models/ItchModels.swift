import Foundation
struct ItchProfileResponse: Decodable {
    let user: ItchUser
}
struct ItchUser: Decodable, Identifiable {
    let id: Int
    let username: String
    let displayName: String?
    let coverUrl: URL?
    let url: URL?
}
struct ItchCredentialsInfo: Decodable {
    let type: String
    let scopes: [String]?
}
struct ItchTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
}
struct ItchAPIErrorResponse: Decodable {
    let errors: [String]?
    let error: String?
    let errorDescription: String?
}
// MARK: - Owned Games Response
struct ItchOwnedKeysResponse: Decodable {
    let page: Int?
    let perPage: Int?
    let ownedKeys: [ItchOwnedKey]
    enum CodingKeys: String, CodingKey {
        case page
        case perPage
        case ownedKeys
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        page = try container.decodeIfPresent(
            Int.self,
            forKey: .page
        )
        perPage = try container.decodeIfPresent(
            Int.self,
            forKey: .perPage
        )
        // 格式一：标准数组
        if let array = try? container.decode(
            [ItchOwnedKey].self,
            forKey: .ownedKeys
        ) {
            ownedKeys = array
            return
        }
        // 格式二：以 ID 为键的字典，值是领取记录
        if let dictionary = try? container.decode(
            [String: ItchOwnedKey].self,
            forKey: .ownedKeys
        ) {
            ownedKeys = dictionary
                .sorted { $0.key > $1.key }
                .map { $0.value }
            return
        }
        // 格式三：以 ID 为键的字典，值直接是游戏
        if let dictionary = try? container.decode(
            [String: ItchOwnedGame].self,
            forKey: .ownedKeys
        ) {
            ownedKeys = dictionary
                .sorted { $0.key > $1.key }
                .map { key, game in
                    ItchOwnedKey(
                        id: Int(key),
                        gameId: game.id,
                        game: game
                    )
                }
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .ownedKeys,
            in: container,
            debugDescription: "owned_keys 既不是数组，也不是支持的游戏字典格式"
        )
    }
}
// MARK: - Owned Key
struct ItchOwnedKey: Decodable {
    let id: Int?
    let gameId: Int?
    let game: ItchOwnedGame?
    init(
        id: Int?,
        gameId: Int?,
        game: ItchOwnedGame?
    ) {
        self.id = id
        self.gameId = gameId
        self.game = game
    }
    enum CodingKeys: String, CodingKey {
        case id
        case gameId
        case game
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        id = try container.decodeIfPresent(
            Int.self,
            forKey: .id
        )
        gameId = try container.decodeIfPresent(
            Int.self,
            forKey: .gameId
        )
        game = try container.decodeIfPresent(
            ItchOwnedGame.self,
            forKey: .game
        )
    }
}
// MARK: - Game
struct ItchOwnedGame: Decodable, Identifiable {
    let id: Int
    let title: String
    let url: URL?
    let coverUrl: URL?
    let type: String?
    let classification: String?
    let minPrice: Int?
    let traits: [String]?
    let user: ItchGameDeveloper?
}
// MARK: - Developer
struct ItchGameDeveloper: Decodable {
    let id: Int?
    let username: String?
    let displayName: String?
    let url: URL?
    let coverUrl: URL?
}
