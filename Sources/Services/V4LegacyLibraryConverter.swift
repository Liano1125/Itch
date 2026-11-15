import CryptoKit
import Foundation
import SwiftData

/// Counts and a privacy-safe digest for the V3 personal-library rows copied
/// into V4's explicit legacy/unassigned scope.
struct V4LegacyLibraryMigrationReport: Equatable {
    let libraryEntryCount: Int
    let collectionCount: Int
    let collectionItemCount: Int
    let statusEventCount: Int
    let inventoryDigest: String

    var totalRows: Int {
        libraryEntryCount + collectionCount + collectionItemCount + statusEventCount
    }
}

/// Copies the V3 personal-library domain into a fresh V4 staging context.
///
/// This converter deliberately has no account/session parameter: V3 rows do
/// not carry durable ownership, so every converted row receives accountID=nil.
/// The V3 source context is only fetched from and is never mutated.
@MainActor
enum V4LegacyLibraryConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case duplicateSourceIdentity(String)
        case missingGame(String)
        case missingCollection(String)

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges:
                return "The V3 source context must be clean before migration."
            case .destinationHasPendingChanges:
                return "The V4 staging context must be clean before migration."
            case .destinationNotEmpty:
                return "The V4 staging library tables must be empty before conversion."
            case .duplicateSourceIdentity(let identity):
                return "The V3 source contains a duplicate migration identity: \(identity)."
            case .missingGame(let gameID):
                return "A V3 personal-library row references a missing game: \(gameID)."
            case .missingCollection(let collectionID):
                return "A V3 collection membership references a missing collection: \(collectionID)."
            }
        }
    }

    static func convert(
        source: ModelContext,
        destination: ModelContext
    ) throws -> V4LegacyLibraryMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let entries = try source.fetch(FetchDescriptor<DBLibraryEntry>())
        let collections = try source.fetch(FetchDescriptor<DBLibraryCollection>())
        let items = try source.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let statusEvents = try source.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        let games = try source.fetch(FetchDescriptor<DBGame>())

        let gameIDs = Set(games.map(\.id))
        let collectionIDs = Set(collections.map(\.id))

        try requireUnique(entries.map(\.gameID), prefix: "library-entry")
        try requireUnique(collections.map(\.id), prefix: "collection")
        try requireUnique(items.map(\.id), prefix: "collection-item")
        try requireUnique(statusEvents.map(\.id), prefix: "status-event")

        for entry in entries where !gameIDs.contains(entry.gameID) {
            throw ConversionError.missingGame(entry.gameID)
        }
        for item in items {
            guard collectionIDs.contains(item.collectionID) else {
                throw ConversionError.missingCollection(item.collectionID)
            }
            guard gameIDs.contains(item.gameID) else {
                throw ConversionError.missingGame(item.gameID)
            }
        }
        for event in statusEvents where !gameIDs.contains(event.gameID) {
            throw ConversionError.missingGame(event.gameID)
        }

        let existingEntries = try destination.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        )
        let existingCollections = try destination.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        )
        let existingItems = try destination.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()
        )
        let existingEvents = try destination.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()
        )
        guard existingEntries == 0, existingCollections == 0,
              existingItems == 0, existingEvents == 0 else {
            throw ConversionError.destinationNotEmpty
        }

        let sortedEntries = entries.sorted { $0.gameID < $1.gameID }
        let sortedCollections = collections.sorted { $0.id < $1.id }
        let sortedItems = items.sorted {
            if $0.collectionID != $1.collectionID { return $0.collectionID < $1.collectionID }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.gameID < $1.gameID
        }
        let sortedEvents = statusEvents.sorted { $0.id < $1.id }

        // Digest only stable identities and counts. User-authored notes and
        // other private payloads are intentionally excluded.
        let digestInput = (
            sortedEntries.map { "entry:\($0.gameID)" } +
            sortedCollections.map { "collection:\($0.id)" } +
            sortedItems.map { "item:\($0.collectionID):\($0.gameID):\($0.sortOrder)" } +
            sortedEvents.map { "status:\($0.id)" }
        ).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestInput.utf8))
            .map { String(format: "%02x", $0) }.joined()

        do {
            for entry in sortedEntries {
                destination.insert(ItchPocketSchemaV4.DBLibraryEntry(
                    accountID: nil,
                    gameID: entry.gameID,
                    status: entry.status,
                    isFavorite: entry.isFavorite,
                    notes: entry.notes,
                    addedAt: entry.addedAt,
                    updatedAt: entry.updatedAt
                ))
            }

            for collection in sortedCollections {
                destination.insert(ItchPocketSchemaV4.DBLibraryCollection(
                    accountID: nil,
                    collectionKey: collection.id,
                    title: collection.title,
                    createdAt: collection.createdAt,
                    updatedAt: collection.updatedAt
                ))
            }

            for item in sortedItems {
                destination.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(
                    accountID: nil,
                    collectionKey: item.collectionID,
                    gameID: item.gameID,
                    sortOrder: item.sortOrder,
                    addedAt: item.addedAt
                ))
            }

            for event in sortedEvents {
                destination.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(
                    accountID: nil,
                    eventKey: event.id,
                    gameID: event.gameID,
                    fromStatus: event.fromStatus,
                    toStatus: event.toStatus,
                    changedAt: event.changedAt
                ))
            }

            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }

        return V4LegacyLibraryMigrationReport(
            libraryEntryCount: sortedEntries.count,
            collectionCount: sortedCollections.count,
            collectionItemCount: sortedItems.count,
            statusEventCount: sortedEvents.count,
            inventoryDigest: digest
        )
    }

    private static func requireUnique(_ values: [String], prefix: String) throws {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            throw ConversionError.duplicateSourceIdentity("\(prefix):\(value)")
        }
    }
}
