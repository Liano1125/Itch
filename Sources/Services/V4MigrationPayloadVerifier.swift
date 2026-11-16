import Foundation
import SwiftData

/// Read-only, field-by-field comparison of the V3 source rows and their V4
/// legacy/unassigned copies. Diagnostics contain counts and stable codes only.
struct V4MigrationPayloadVerificationReport: Equatable {
    let library: V4MigrationPayloadVerificationSummary
    let appState: V4MigrationPayloadVerificationSummary
    let integrityDiagnostics: [String]

    var isVerified: Bool {
        integrityDiagnostics.isEmpty &&
        library.status == .verified &&
        appState.status == .verified &&
        library.unverifiedRows == 0 &&
        appState.unverifiedRows == 0
    }
}

@MainActor
enum V4MigrationPayloadVerifier {
    private struct LibraryEntryValue: Equatable {
        let status: String
        let isFavorite: Bool
        let notes: String
        let addedAt: Date
        let updatedAt: Date
    }

    private struct CollectionValue: Equatable {
        let title: String
        let createdAt: Date
        let updatedAt: Date
    }

    private struct CollectionItemValue: Equatable {
        let collectionID: String
        let gameID: String
        let sortOrder: Int
        let addedAt: Date
    }

    private struct StatusEventValue: Equatable {
        let gameID: String
        let fromStatus: String?
        let toStatus: String
        let changedAt: Date
    }

    private struct AppStateValue: Equatable {
        let scopeID: String
        let stringValue: String?
        let dateValue: Date?
        let dataValue: Data?
        let updatedAt: Date
    }

    static func verify(source: ModelContext, destination: ModelContext) throws
        -> V4MigrationPayloadVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return failedReport("migration.verification.pendingContextChanges")
        }

        let sourceEntries = try source.fetch(FetchDescriptor<DBLibraryEntry>())
        let sourceCollections = try source.fetch(FetchDescriptor<DBLibraryCollection>())
        let sourceItems = try source.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let sourceEvents = try source.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        let sourceStates = try source.fetch(FetchDescriptor<DBAppState>())

        let destinationEntries = try destination.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        )
        let destinationCollections = try destination.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        )
        let destinationItems = try destination.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()
        )
        let destinationEvents = try destination.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()
        )
        let destinationStates = try destination.fetch(FetchDescriptor<DBScopedAppState>())

        var diagnostics: [String] = []
        var libraryVerified = 0
        var libraryUnverified = 0

        func compare<K: Hashable, V: Equatable>(
            source: [(K, V)],
            destination: [(K, V)],
            duplicateCode: String,
            mismatchCode: String
        ) -> (Int, Int) {
            let sourceGroups = Dictionary(grouping: source, by: \.0)
            let destinationGroups = Dictionary(grouping: destination, by: \.0)
            let keys = Set(sourceGroups.keys).union(destinationGroups.keys)
            var verified = 0
            var unverified = 0
            for key in keys {
                let left = sourceGroups[key] ?? []
                let right = destinationGroups[key] ?? []
                if left.count > 1 || right.count > 1 {
                    diagnostics.append(duplicateCode)
                    unverified += left.count + right.count
                } else if left.count == 1, right.count == 1, left[0].1 == right[0].1 {
                    verified += 1
                } else {
                    diagnostics.append(mismatchCode)
                    unverified += left.count + right.count
                }
            }
            return (verified, unverified)
        }

        let entries = compare(
            source: sourceEntries.map { ($0.gameID, LibraryEntryValue(
                status: $0.status, isFavorite: $0.isFavorite, notes: $0.notes,
                addedAt: $0.addedAt, updatedAt: $0.updatedAt
            )) },
            destination: destinationEntries.map { row in
                if row.accountID != nil ||
                    row.id != ItchPocketSchemaV4.DBLibraryEntry.stableID(
                        accountID: nil, gameID: row.gameID
                    ) {
                    diagnostics.append("migration.library.entry.identityOrScopeMismatch")
                }
                return (row.gameID, LibraryEntryValue(
                    status: row.status, isFavorite: row.isFavorite, notes: row.notes,
                    addedAt: row.addedAt, updatedAt: row.updatedAt
                ))
            },
            duplicateCode: "migration.library.entry.duplicateIdentity",
            mismatchCode: "migration.library.entry.payloadMismatch"
        )
        libraryVerified += entries.0
        libraryUnverified += entries.1

        let collections = compare(
            source: sourceCollections.map { ($0.id, CollectionValue(
                title: $0.title, createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )) },
            destination: destinationCollections.map { row in
                if row.accountID != nil ||
                    row.id != ItchPocketSchemaV4.DBLibraryCollection.stableID(
                        accountID: nil, collectionKey: row.collectionKey
                    ) {
                    diagnostics.append("migration.library.collection.identityOrScopeMismatch")
                }
                return (row.collectionKey, CollectionValue(
                    title: row.title, createdAt: row.createdAt, updatedAt: row.updatedAt
                ))
            },
            duplicateCode: "migration.library.collection.duplicateIdentity",
            mismatchCode: "migration.library.collection.payloadMismatch"
        )
        libraryVerified += collections.0
        libraryUnverified += collections.1

        let items = compare(
            source: sourceItems.map { row in
                (DBLibraryCollectionItem.stableID(
                    collectionID: row.collectionID, gameID: row.gameID
                ), CollectionItemValue(
                    collectionID: row.collectionID, gameID: row.gameID,
                    sortOrder: row.sortOrder, addedAt: row.addedAt
                ))
            },
            destination: destinationItems.map { row in
                if row.accountID != nil ||
                    row.id != ItchPocketSchemaV4.DBLibraryCollectionItem.stableID(
                        accountID: nil, collectionKey: row.collectionKey, gameID: row.gameID
                    ) {
                    diagnostics.append("migration.library.collectionItem.identityOrScopeMismatch")
                }
                return (DBLibraryCollectionItem.stableID(
                    collectionID: row.collectionKey, gameID: row.gameID
                ), CollectionItemValue(
                    collectionID: row.collectionKey, gameID: row.gameID,
                    sortOrder: row.sortOrder, addedAt: row.addedAt
                ))
            },
            duplicateCode: "migration.library.collectionItem.duplicateIdentity",
            mismatchCode: "migration.library.collectionItem.payloadMismatch"
        )
        libraryVerified += items.0
        libraryUnverified += items.1

        let events = compare(
            source: sourceEvents.map { ($0.id, StatusEventValue(
                gameID: $0.gameID, fromStatus: $0.fromStatus,
                toStatus: $0.toStatus, changedAt: $0.changedAt
            )) },
            destination: destinationEvents.map { row in
                if row.accountID != nil ||
                    row.id != ItchPocketSchemaV4.DBLibraryStatusEvent.stableID(
                        accountID: nil, eventKey: row.eventKey
                    ) {
                    diagnostics.append("migration.library.statusEvent.identityOrScopeMismatch")
                }
                return (row.eventKey, StatusEventValue(
                    gameID: row.gameID, fromStatus: row.fromStatus,
                    toStatus: row.toStatus, changedAt: row.changedAt
                ))
            },
            duplicateCode: "migration.library.statusEvent.duplicateIdentity",
            mismatchCode: "migration.library.statusEvent.payloadMismatch"
        )
        libraryVerified += events.0
        libraryUnverified += events.1

        let expectedDevice = AppStateScope.device.scopeID
        let expectedGlobal = AppStateScope.appGlobal.scopeID
        let expectedLegacy = AppStateScope.legacyUnclassified.scopeID
        let appState = compare(
            source: sourceStates.map { row -> (String, AppStateValue) in
                let classification = AppStateScopeRegistry.classify(row.key)
                let expectedScope: String
                switch classification.scope {
                case .device where classification.confidence == .established:
                    expectedScope = expectedDevice
                case .appGlobal where classification.confidence == .established:
                    expectedScope = expectedGlobal
                default:
                    expectedScope = expectedLegacy
                }
                return (row.key, AppStateValue(
                    scopeID: expectedScope, stringValue: row.stringValue,
                    dateValue: row.dateValue, dataValue: row.dataValue,
                    updatedAt: row.updatedAt
                ))
            },
            destination: destinationStates.map { row in
                if row.id != DBScopedAppState.stableID(
                    scopeID: row.scopeID, logicalKey: row.logicalKey
                ) {
                    diagnostics.append("migration.appState.identityMismatch")
                }
                return (row.logicalKey, AppStateValue(
                    scopeID: row.scopeID, stringValue: row.stringValue,
                    dateValue: row.dateValue, dataValue: row.dataValue,
                    updatedAt: row.updatedAt
                ))
            },
            duplicateCode: "migration.appState.duplicateIdentity",
            mismatchCode: "migration.appState.payloadOrScopeMismatch"
        )

        let librarySummary = summary(
            verified: libraryVerified, unverified: libraryUnverified
        )
        let appStateSummary = summary(verified: appState.0, unverified: appState.1)
        return V4MigrationPayloadVerificationReport(
            library: librarySummary,
            appState: appStateSummary,
            integrityDiagnostics: Array(Set(diagnostics)).sorted()
        )
    }

    private static func summary(
        verified: Int, unverified: Int
    ) -> V4MigrationPayloadVerificationSummary {
        V4MigrationPayloadVerificationSummary(
            status: unverified == 0 ? .verified : .failed,
            method: .fieldByFieldCanonicalValues,
            verifiedRows: verified,
            unverifiedRows: unverified
        )
    }

    private static func failedReport(
        _ diagnostic: String
    ) -> V4MigrationPayloadVerificationReport {
        let failed = V4MigrationPayloadVerificationSummary(
            status: .failed, method: .fieldByFieldCanonicalValues,
            verifiedRows: 0, unverifiedRows: 1
        )
        return V4MigrationPayloadVerificationReport(
            library: failed, appState: failed,
            integrityDiagnostics: [diagnostic]
        )
    }
}
