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

// MARK: - Owned Games

struct ItchOwnedKeysResponse: Decodable {
    let page: Int?
    let perPage: Int?
    let ownedKeys: [ItchOwnedKey]
}

struct ItchOwnedKey: Decodable {
    let id: Int
    let gameId: Int
    let game: ItchOwnedGame?
}

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

struct ItchGameDeveloper: Decodable {
    let id: Int?
    let username: String?
    let displayName: String?
    let url: URL?
    let coverUrl: URL?
}
