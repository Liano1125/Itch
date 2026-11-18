import CryptoKit
import Foundation
import SwiftData

struct V4GameUpdateMigrationReport: Equatable {
    let rowCount: Int
    let inventoryDigest: String
}

struct V4GameUpdateVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

@MainActor
enum V4GameUpdateConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case missingGame(String)

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before game-update migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before game-update migration."
            case .destinationNotEmpty: return "The V4 game-update table must be empty before conversion."
            case .missingGame: return "A V3 game update references a missing game."
            }
        }
    }

    static func convert(source: ModelContext, destination: ModelContext) throws -> V4GameUpdateMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }
        let updates = try source.fetch(FetchDescriptor<DBGameUpdate>())
        let gameIDs = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\\.id))
        for update in updates where !gameIDs.contains(update.gameID) {
            throw ConversionError.missingGame(update.id)
        }
        guard try destination.fetchCount(FetchDescriptor<DBGameUpdate>()) == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sorted = updates.sorted { $0.id < $1.id }
        let identityLines = sorted.map { "game-update:\\($0.id)" }
        let digest = SHA256.hash(data: Data(identityLines.joined(separator: "\\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            for row in sorted {
                destination.insert(DBGameUpdate(
                    id: row.id, gameID: row.gameID, title: row.title,
                    summary: row.summary, detectedAt: row.detectedAt,
                    publishedAt: row.publishedAt, url: row.url,
                    sourceID: row.sourceID, isHistorical: row.isHistorical
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }
        return V4GameUpdateMigrationReport(rowCount: sorted.count, inventoryDigest: digest)
    }
}

@MainActor
enum V4GameUpdateVerifier {
    private struct Value: Equatable {
        let id: String
        let gameID: String
        let title: String?
        let summary: String
        let detectedAt: Date
        let publishedAt: Date?
        let url: String?
        let sourceID: String?
        let isHistorical: Bool
        init(_ row: DBGameUpdate) {
            id = row.id; gameID = row.gameID; title = row.title
            summary = row.summary; detectedAt = row.detectedAt
            publishedAt = row.publishedAt; url = row.url
            sourceID = row.sourceID; isHistorical = row.isHistorical
        }
    }

    static func verify(source: ModelContext, destination: ModelContext) throws -> V4GameUpdateVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4GameUpdateVerificationReport(
                verifiedRows: 0, unverifiedRows: 1,
                diagnostics: ["migration.gameUpdates.pendingContextChanges"]
            )
        }
        let sourceRows = try source.fetch(FetchDescriptor<DBGameUpdate>())
        let destinationRows = try destination.fetch(FetchDescriptor<DBGameUpdate>())
        let lhs = Dictionary(grouping: sourceRows.map(Value.init), by: \\.id)
        let rhs = Dictionary(grouping: destinationRows.map(Value.init), by: \\.id)
        var verified = 0
        var unverified = 0
        var diagnostics = Set<String>()
        for key in Set(lhs.keys).union(rhs.keys) {
            let a = lhs[key] ?? []
            let b = rhs[key] ?? []
            if a.count == 1, b.count == 1, a[0] == b[0] {
                verified += 1
            } else {
                unverified += a.count + b.count
                diagnostics.insert("migration.gameUpdates.rowMismatch")
            }
        }
        return V4GameUpdateVerificationReport(
            verifiedRows: verified, unverifiedRows: unverified,
            diagnostics: diagnostics.sorted()
        )
    }
}
