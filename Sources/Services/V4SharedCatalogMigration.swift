import CryptoKit
import Foundation
import SwiftData

/// Counts and identity digest for shared catalog rows copied from V3.
struct V4SharedCatalogMigrationReport: Equatable {
    let developerCount: Int
    let gameCount: Int
    let gameDetailCount: Int
    let inventoryDigest: String

    var totalRows: Int { developerCount + gameCount + gameDetailCount }
}

/// Copies developer, game, and game-detail records into the isolated V4 store.
/// These are shared catalog records, not account-owned data.
@MainActor
enum V4SharedCatalogConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case missingDeveloper(String)
        case missingGame(String)

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before catalog migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before catalog migration."
            case .destinationNotEmpty: return "The V4 shared catalog tables must be empty before conversion."
            case .missingDeveloper: return "A V3 game references a missing developer."
            case .missingGame: return "A V3 game-detail record references a missing game."
            }
        }
    }

    static func convert(source: ModelContext, destination: ModelContext) throws -> V4SharedCatalogMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let developers = try source.fetch(FetchDescriptor<DBDeveloper>())
        let games = try source.fetch(FetchDescriptor<DBGame>())
        let details = try source.fetch(FetchDescriptor<DBGameDetail>())
        let developerIDs = Set(developers.map(\.id))
        let gameIDs = Set(games.map(\.id))

        for game in games {
            if let developerID = game.developerID, !developerIDs.contains(developerID) {
                throw ConversionError.missingDeveloper(developerID)
            }
        }
        for detail in details where !gameIDs.contains(detail.gameID) {
            throw ConversionError.missingGame(detail.gameID)
        }

        guard try destination.fetchCount(FetchDescriptor<DBDeveloper>()) == 0,
              try destination.fetchCount(FetchDescriptor<DBGame>()) == 0,
              try destination.fetchCount(FetchDescriptor<DBGameDetail>()) == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sortedDevelopers = developers.sorted { $0.id < $1.id }
        let sortedGames = games.sorted { $0.id < $1.id }
        let sortedDetails = details.sorted { $0.gameID < $1.gameID }
        let identityLines =
            sortedDevelopers.map { "developer:\($0.id)" } +
            sortedGames.map { "game:\($0.id)" } +
            sortedDetails.map { "game-detail:\($0.gameID)" }
        let digest = SHA256.hash(data: Data(identityLines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()

        do {
            for row in sortedDevelopers {
                destination.insert(DBDeveloper(
                    id: row.id, name: row.name, profileURL: row.profileURL,
                    patreonURL: row.patreonURL, discordURL: row.discordURL,
                    avatarURL: row.avatarURL, avatarSource: row.avatarSource,
                    avatarResolvedAt: row.avatarResolvedAt, updatedAt: row.updatedAt
                ))
            }
            for row in sortedGames {
                destination.insert(DBGame(
                    id: row.id, title: row.title, gameURL: row.gameURL,
                    coverURL: row.coverURL, engine: row.engine,
                    developerID: row.developerID, updatedAt: row.updatedAt
                ))
            }
            for row in sortedDetails {
                destination.insert(DBGameDetail(
                    gameID: row.gameID, descriptionText: row.descriptionText,
                    galleryURLs: row.galleryURLs, discoveryTagsData: row.discoveryTagsData,
                    fetchedAt: row.fetchedAt, isComplete: row.isComplete
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }

        return V4SharedCatalogMigrationReport(
            developerCount: sortedDevelopers.count,
            gameCount: sortedGames.count,
            gameDetailCount: sortedDetails.count,
            inventoryDigest: digest
        )
    }
}

/// Field-by-field comparison of shared catalog records after conversion.
struct V4SharedCatalogVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

@MainActor
enum V4SharedCatalogVerifier {
    private struct DeveloperValue: Equatable {
        let id: String; let name: String; let profileURL: String?; let patreonURL: String?
        let discordURL: String?; let avatarURL: String?; let avatarSource: String?
        let avatarResolvedAt: Date?; let updatedAt: Date
        init(_ row: DBDeveloper) {
            id = row.id; name = row.name; profileURL = row.profileURL; patreonURL = row.patreonURL
            discordURL = row.discordURL; avatarURL = row.avatarURL; avatarSource = row.avatarSource
            avatarResolvedAt = row.avatarResolvedAt; updatedAt = row.updatedAt
        }
    }
    private struct GameValue: Equatable {
        let id: String; let title: String; let gameURL: String?; let coverURL: String?
        let engine: String?; let developerID: String?; let updatedAt: Date
        init(_ row: DBGame) {
            id = row.id; title = row.title; gameURL = row.gameURL; coverURL = row.coverURL
            engine = row.engine; developerID = row.developerID; updatedAt = row.updatedAt
        }
    }
    private struct DetailValue: Equatable {
        let gameID: String; let descriptionText: String?; let galleryURLs: [String]
        let discoveryTagsData: Data?; let fetchedAt: Date?; let isComplete: Bool
        init(_ row: DBGameDetail) {
            gameID = row.gameID; descriptionText = row.descriptionText; galleryURLs = row.galleryURLs
            discoveryTagsData = row.discoveryTagsData; fetchedAt = row.fetchedAt; isComplete = row.isComplete
        }
    }

    static func verify(source: ModelContext, destination: ModelContext) throws -> V4SharedCatalogVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4SharedCatalogVerificationReport(
                verifiedRows: 0, unverifiedRows: 1,
                diagnostics: ["migration.sharedCatalog.pendingContextChanges"]
            )
        }
        let sourceDevelopers = try source.fetch(FetchDescriptor<DBDeveloper>())
        let sourceGames = try source.fetch(FetchDescriptor<DBGame>())
        let sourceDetails = try source.fetch(FetchDescriptor<DBGameDetail>())
        let destinationDevelopers = try destination.fetch(FetchDescriptor<DBDeveloper>())
        let destinationGames = try destination.fetch(FetchDescriptor<DBGame>())
        let destinationDetails = try destination.fetch(FetchDescriptor<DBGameDetail>())

        var verified = 0
        var unverified = 0
        var diagnostics: [String] = []
        func compare<T: Equatable>(
            _ left: [T], _ right: [T], code: String
        ) where T: Identifiable, T.ID: Hashable {
            let lhs = Dictionary(grouping: left, by: \.id)
            let rhs = Dictionary(grouping: right, by: \.id)
            for key in Set(lhs.keys).union(rhs.keys) {
                let a = lhs[key] ?? []
                let b = rhs[key] ?? []
                if a.count == 1, b.count == 1, a[0] == b[0] { verified += 1 }
                else { unverified += a.count + b.count; diagnostics.append(code) }
            }
        }
        // Local wrappers use stable IDs and Equatable payload values.
        struct Identified<Value: Equatable>: Identifiable, Equatable {
            let id: String; let value: Value
        }
        compare(
            sourceDevelopers.map { Identified(id: $0.id, value: DeveloperValue($0)) },
            destinationDevelopers.map { Identified(id: $0.id, value: DeveloperValue($0)) },
            code: "migration.sharedCatalog.developerMismatch"
        )
        compare(
            sourceGames.map { Identified(id: $0.id, value: GameValue($0)) },
            destinationGames.map { Identified(id: $0.id, value: GameValue($0)) },
            code: "migration.sharedCatalog.gameMismatch"
        )
        compare(
            sourceDetails.map { Identified(id: $0.gameID, value: DetailValue($0)) },
            destinationDetails.map { Identified(id: $0.gameID, value: DetailValue($0)) },
            code: "migration.sharedCatalog.gameDetailMismatch"
        )
        return V4SharedCatalogVerificationReport(
            verifiedRows: verified, unverifiedRows: unverified,
            diagnostics: Array(Set(diagnostics)).sorted()
        )
    }
}
