import CryptoKit
import Foundation
import SwiftData

struct V4LegacyAppStateMigrationReport: Equatable {
    let totalRows: Int
    let deviceScopedRows: Int
    let appGlobalRows: Int
    let quarantinedRows: Int
    let inventoryDigest: String
}

/// Copies V3's globally keyed AppState rows into V4 scopes without guessing
/// account ownership. Account-scoped, Patreon-scoped, and unknown keys are
/// retained in the explicit legacy-unclassified scope for later review.
@MainActor
enum V4LegacyAppStateConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case duplicateSourceKey(String)

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges:
                return "The V3 AppState source context must be clean before migration."
            case .destinationHasPendingChanges:
                return "The V4 AppState staging context must be clean before migration."
            case .destinationNotEmpty:
                return "The V4 scoped AppState staging table must be empty before conversion."
            case .duplicateSourceKey(let key):
                return "The V3 AppState source contains a duplicate key: \(key)."
            }
        }
    }

    static func convert(
        source: ModelContext,
        destination: ModelContext
    ) throws -> V4LegacyAppStateMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let rows = try source.fetch(FetchDescriptor<DBAppState>())
        var seen = Set<String>()
        for row in rows where !seen.insert(row.key).inserted {
            throw ConversionError.duplicateSourceKey(row.key)
        }

        guard try destination.fetchCount(
            FetchDescriptor<DBScopedAppState>()
        ) == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sortedRows = rows.sorted { $0.key < $1.key }
        let deviceScope = AppStateScope.device.scopeID
        let appGlobalScope = AppStateScope.appGlobal.scopeID
        let legacyScope = AppStateScope.legacyUnclassified.scopeID

        var deviceCount = 0
        var appGlobalCount = 0
        var quarantinedCount = 0

        let digestInput = sortedRows.map { "app-state:\($0.key)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }.joined()

        do {
            for row in sortedRows {
                let classification = AppStateScopeRegistry.classify(row.key)
                let scopeID: String

                switch classification.scope {
                case .device:
                    scopeID = deviceScope
                    deviceCount += 1
                case .appGlobal:
                    scopeID = appGlobalScope
                    appGlobalCount += 1
                case .itchAccount, .patreonAccount, .legacyUnclassified:
                    // The historical row has no durable account owner.
                    // Never infer one from the currently signed-in identity.
                    scopeID = legacyScope
                    quarantinedCount += 1
                }

                destination.insert(DBScopedAppState(
                    scopeID: scopeID,
                    logicalKey: row.key,
                    stringValue: row.stringValue,
                    dateValue: row.dateValue,
                    dataValue: row.dataValue,
                    updatedAt: row.updatedAt
                ))
            }

            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }

        return V4LegacyAppStateMigrationReport(
            totalRows: sortedRows.count,
            deviceScopedRows: deviceCount,
            appGlobalRows: appGlobalCount,
            quarantinedRows: quarantinedCount,
            inventoryDigest: digest
        )
    }
}
