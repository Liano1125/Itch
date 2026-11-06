
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
