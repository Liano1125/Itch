import Foundation
import SwiftData

/// Joined, read-only view of one account's membership and the shared game catalog.
struct StoredAccountLibraryGame: Equatable {
    let gameID: String
    let status: String
    let isFavorite: Bool
    let notes: String
    let addedAt: Date
    let updatedAt: Date
    let title: String
    let gameURL: String?
    let coverURL: String?
    let engine: String?
    let developerID: String?
    let developerName: String?
    let developerProfileURL: String?
    let patreonURL: String?
    let discordURL: String?
    let descriptionText: String?
    let galleryURLs: [String]
}

/// Reads account-owned membership together with shared game/developer/detail
/// metadata. The account predicate is applied before any catalog join.
@MainActor
final class AccountScopedLibraryCatalogRepository {
    enum RepositoryError: LocalizedError {
        case accountNotRegistered(String)

        var errorDescription: String? {
            switch self {
            case .accountNotRegistered(let id):
                return "The V4 itch account is no longer registered: \(id)."
            }
        }
    }

    private let context: ModelContext
    private let accountID: String

    init(context: ModelContext, accountID: String) {
        self.context = context
        self.accountID = accountID
    }

    func loadLibraryGames() throws -> [StoredAccountLibraryGame] {
        try V4AccountRegistryGuard.requireRegisteredAccount(accountID, in: context)

        let scope = accountID
        let entries = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>(
            predicate: #Predicate { $0.accountID == scope }
        ))
        guard !entries.isEmpty else { return [] }

        let gameIDs = entries.map(\.gameID)
        let games = try context.fetch(FetchDescriptor<DBGame>(
            predicate: #Predicate { gameIDs.contains($0.id) }
        ))
        let gameByID = Dictionary(games.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let developerIDs = Array(Set(games.compactMap(\.developerID)))
        let developers: [DBDeveloper]
        if developerIDs.isEmpty {
            developers = []
        } else {
            developers = try context.fetch(FetchDescriptor<DBDeveloper>(
                predicate: #Predicate { developerIDs.contains($0.id) }
            ))
        }
        let developerByID = Dictionary(developers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let details = try context.fetch(FetchDescriptor<DBGameDetail>(
            predicate: #Predicate { gameIDs.contains($0.gameID) }
        ))
        let detailByGameID = Dictionary(details.map { ($0.gameID, $0) }, uniquingKeysWith: { first, _ in first })

        return entries.compactMap { entry in
            guard let game = gameByID[entry.gameID] else { return nil }
            let developer = game.developerID.flatMap { developerByID[$0] }
            let detail = detailByGameID[game.id]
            return StoredAccountLibraryGame(
                gameID: entry.gameID,
                status: entry.status,
                isFavorite: entry.isFavorite,
                notes: entry.notes,
                addedAt: entry.addedAt,
                updatedAt: entry.updatedAt,
                title: game.title,
                gameURL: game.gameURL,
                coverURL: game.coverURL,
                engine: game.engine,
                developerID: game.developerID,
                developerName: developer?.name,
                developerProfileURL: developer?.profileURL,
                patreonURL: developer?.patreonURL,
                discordURL: developer?.discordURL,
                descriptionText: detail?.descriptionText,
                galleryURLs: detail?.galleryURLs ?? []
            )
        }.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt > $1.addedAt }
            return $0.gameID < $1.gameID
        }
    }
}
