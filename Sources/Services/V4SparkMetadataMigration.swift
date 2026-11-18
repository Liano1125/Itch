import CryptoKit
import Foundation
import SwiftData

struct V4SparkMetadataMigrationReport: Equatable {
    let rowCount: Int
    let inventoryDigest: String
}

struct V4SparkMetadataVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

/// Spark metadata describes local save files on this device. It is device-scoped,
/// never assigned to an itch account, and copied without changing ownership.
@MainActor
enum V4SparkMetadataConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case missingGame

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before Spark migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before Spark migration."
            case .destinationNotEmpty: return "The V4 Spark metadata table must be empty before conversion."
            case .missingGame: return "A V3 Spark metadata row references a missing game."
            }
        }
    }

    static func convert(source: ModelContext, destination: ModelContext) throws -> V4SparkMetadataMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let rows = try source.fetch(FetchDescriptor<DBSparkMetadata>())
        let gameIDs = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\\.id))
        guard rows.allSatisfy({ gameIDs.contains($0.gameID) }) else {
            throw ConversionError.missingGame
        }
        guard try destination.fetchCount(FetchDescriptor<DBSparkMetadata>()) == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sorted = rows.sorted { $0.gameID < $1.gameID }
        let identityLines = sorted.map { "spark-device:\\($0.gameID)" }
        let digest = SHA256.hash(data: Data(identityLines.joined(separator: "\\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            for row in sorted {
                destination.insert(DBSparkMetadata(
                    gameID: row.gameID,
                    runtimeSeconds: row.runtimeSeconds,
                    lastSaveAt: row.lastSaveAt,
                    renpyVersion: row.renpyVersion,
                    saveCount: row.saveCount,
                    scannedAt: row.scannedAt
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }
        return V4SparkMetadataMigrationReport(rowCount: sorted.count, inventoryDigest: digest)
    }
}

@MainActor
enum V4SparkMetadataVerifier {
    private struct Value: Equatable {
        let gameID: String
        let runtimeSeconds: Double
        let lastSaveAt: Date?
        let renpyVersion: String?
        let saveCount: Int?
        let scannedAt: Date

        init(_ row: DBSparkMetadata) {
            gameID = row.gameID
            runtimeSeconds = row.runtimeSeconds
            lastSaveAt = row.lastSaveAt
            renpyVersion = row.renpyVersion
            saveCount = row.saveCount
            scannedAt = row.scannedAt
        }
    }

    static func verify(source: ModelContext, destination: ModelContext) throws -> V4SparkMetadataVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4SparkMetadataVerificationReport(
                verifiedRows: 0, unverifiedRows: 1,
                diagnostics: ["migration.sparkMetadata.pendingContextChanges"]
            )
        }
        let sourceRows = try source.fetch(FetchDescriptor<DBSparkMetadata>())
        let destinationRows = try destination.fetch(FetchDescriptor<DBSparkMetadata>())
        let lhs = Dictionary(grouping: sourceRows.map(Value.init), by: \\.gameID)
        let rhs = Dictionary(grouping: destinationRows.map(Value.init), by: \\.gameID)
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
                diagnostics.insert("migration.sparkMetadata.rowMismatch")
            }
        }
        return V4SparkMetadataVerificationReport(
            verifiedRows: verified, unverifiedRows: unverified,
            diagnostics: diagnostics.sorted()
        )
    }
}
