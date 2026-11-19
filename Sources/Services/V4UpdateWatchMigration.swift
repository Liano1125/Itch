import CryptoKit
import Foundation
import SwiftData

struct V4UpdateWatchMigrationReport: Equatable {
    let rowCount: Int
    let quarantinedRowCount: Int
    let missingGameRowCount: Int
    let inventoryDigest: String
}

struct V4UpdateWatchVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let quarantinedRowCount: Int
    let missingGameRowCount: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

/// V3 watches have no durable account owner. Every source row is copied into
/// the V4 unassigned legacy area; no current account is ever inferred.
@MainActor
enum V4UpdateWatchConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case duplicateSourceIdentity

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before update-watch migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before update-watch migration."
            case .destinationNotEmpty: return "The V4 legacy update-watch table must be empty before conversion."
            case .duplicateSourceIdentity: return "The V3 update-watch source contains duplicate identities."
            }
        }
    }

    static func convert(
        source: ModelContext,
        destination: ModelContext,
        quarantinedAt: Date = .now
    ) throws -> V4UpdateWatchMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let rows = try source.fetch(FetchDescriptor<DBUpdateWatch>())
        let games = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\.id))
        let existing = try destination.fetch(FetchDescriptor<DBLegacyUpdateWatch>())
        guard existing.isEmpty else { throw ConversionError.destinationNotEmpty }

        let sorted = rows.sorted { $0.gameID < $1.gameID }
        guard Set(sorted.map(\.gameID)).count == sorted.count else {
            throw ConversionError.duplicateSourceIdentity
        }
        let identityLines = sorted.map { "legacy-update-watch:\($0.gameID)" }
        let digest = SHA256.hash(data: Data(identityLines.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()

        do {
            for row in sorted {
                destination.insert(DBLegacyUpdateWatch(
                    originalGameID: row.gameID,
                    entityTag: row.entityTag,
                    lastModified: row.lastModified,
                    contentHash: row.contentHash,
                    lastCheckedAt: row.lastCheckedAt,
                    hasBaseline: row.hasBaseline,
                    isEnabled: row.isEnabled,
                    integrityIssue: games.contains(row.gameID) ? nil : "missing-game",
                    quarantinedAt: quarantinedAt
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }

        return V4UpdateWatchMigrationReport(
            rowCount: sorted.count,
            quarantinedRowCount: sorted.count,
            missingGameRowCount: sorted.filter { !games.contains($0.gameID) }.count,
            inventoryDigest: digest
        )
    }
}

@MainActor
enum V4UpdateWatchVerifier {
    private struct Value: Equatable {
        let originalGameID: String
        let entityTag: String?
        let lastModified: String?
        let contentHash: String?
        let lastCheckedAt: Date?
        let hasBaseline: Bool
        let isEnabled: Bool
        let integrityIssue: String?

        init(_ row: DBUpdateWatch, gameIDs: Set<String>) {
            originalGameID = row.gameID
            entityTag = row.entityTag
            lastModified = row.lastModified
            contentHash = row.contentHash
            lastCheckedAt = row.lastCheckedAt
            hasBaseline = row.hasBaseline
            isEnabled = row.isEnabled
            integrityIssue = gameIDs.contains(row.gameID) ? nil : "missing-game"
        }

        init(_ row: DBLegacyUpdateWatch) {
            originalGameID = row.originalGameID
            entityTag = row.entityTag
            lastModified = row.lastModified
            contentHash = row.contentHash
            lastCheckedAt = row.lastCheckedAt
            hasBaseline = row.hasBaseline
            isEnabled = row.isEnabled
            integrityIssue = row.integrityIssue
        }
    }

    static func verify(
        source: ModelContext,
        destination: ModelContext
    ) throws -> V4UpdateWatchVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4UpdateWatchVerificationReport(
                verifiedRows: 0, unverifiedRows: 1, quarantinedRowCount: 0,
                missingGameRowCount: 0,
                diagnostics: ["migration.updateWatches.pendingContextChanges"]
            )
        }

        let sourceRows = try source.fetch(FetchDescriptor<DBUpdateWatch>())
        let gameIDs = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\.id))
        let destinationRows = try destination.fetch(FetchDescriptor<DBLegacyUpdateWatch>())
        let lhs = Dictionary(grouping: sourceRows.map { Value($0, gameIDs: gameIDs) }, by: \.originalGameID)
        let rhs = Dictionary(grouping: destinationRows.map(Value.init), by: \.originalGameID)
        var verified = 0
        var unverified = 0
        var missingGameCount = 0
        var diagnostics = Set<String>()

        for key in Set(lhs.keys).union(rhs.keys) {
            let sourceValues = lhs[key] ?? []
            let destinationValues = rhs[key] ?? []
            if sourceValues.count == 1, destinationValues.count == 1,
               sourceValues[0] == destinationValues[0],
               destinationValues[0].originalGameID == key,
               destinationRows.first(where: { $0.originalGameID == key })?.id == DBLegacyUpdateWatch.stableID(gameID: key) {
                verified += 1
                if destinationValues[0].integrityIssue == "missing-game" { missingGameCount += 1 }
            } else {
                unverified += sourceValues.count + destinationValues.count
                diagnostics.insert("migration.updateWatches.rowMismatch")
            }
        }

        return V4UpdateWatchVerificationReport(
            verifiedRows: verified, unverifiedRows: unverified,
            quarantinedRowCount: destinationRows.count,
            missingGameRowCount: missingGameCount,
            diagnostics: diagnostics.sorted()
        )
    }
}
