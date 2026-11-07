import Foundation

// MARK: - Profile

struct ItchProfileResponse: Decodable {
    let user: ItchUser
}

struct ItchUser: Decodable, Identifiable {
    let id: Int
    let username: String
    let displayName: String?
    let coverUrl: URL?
    let url: URL?
    var accountCreatedAt: Date? = nil
}

// MARK: - Credentials

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

// MARK: - Flexible Array

struct ItchFlexibleArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        // 标准数组格式
        if var container = try? decoder.unkeyedContainer() {
            var result: [Element] = []

            while !container.isAtEnd {
                result.append(try container.decode(Element.self))
            }

            values = result
            return
        }

        // 字典格式，包括 itch.io 返回的空对象 {}
        let container = try decoder.container(
            keyedBy: DynamicCodingKey.self
        )

        let keys = container.allKeys.sorted {
            let left = Int($0.stringValue) ?? Int.max
            let right = Int($1.stringValue) ?? Int.max

            if left == right {
                return $0.stringValue < $1.stringValue
            }

            return left < right
        }

        values = try keys.map {
            try container.decode(Element.self, forKey: $0)
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = Int(stringValue)
    }

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

// MARK: - Collections

struct ItchCollectionsResponse: Decodable {
    let collections: ItchFlexibleArray<ItchCollection>
}

struct ItchCollection: Decodable, Identifiable {
    let id: Int
    let title: String
    let url: URL?
    let userId: Int?
    let gamesCount: Int?
    let isPrivate: Bool?
    let description: String?
    let layout: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case url
        case userId
        case gamesCount
        case description
        case layout
        case isPrivate = "private"
    }
}

// MARK: - Collection Games

struct ItchCollectionGamesResponse: Decodable {
    let page: Int?
    let perPage: Int?
    let collectionGames: ItchFlexibleArray<ItchCollectionGame>
}

struct ItchCollectionGame: Decodable {
    let collectionId: Int?
    let gameId: Int?
    let position: Int?
    let blurb: String?
    let game: ItchGame?
}

// MARK: - Game

struct ItchGame: Decodable, Identifiable {
    let id: Int
    let title: String
    let url: URL?
    let coverUrl: URL?
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
