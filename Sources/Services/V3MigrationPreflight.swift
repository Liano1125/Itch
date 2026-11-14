import CryptoKit
import Foundation
import SwiftData

/// A value-only, privacy-safe inventory of the active V3 store.
///
/// This is deliberately a read-only preflight: it never inserts, updates,
/// deletes, saves, or assigns ownership to any source row. The digest covers
/// counts and structural diagnostics only; it never includes notes, tokens,
/// calendar text, or other user-authored payloads.
struct V3MigrationPreflightReport: Codable, Equatable {
    let sourceSchemaVersion: String
    let rowCounts: [String: Int]
    let ownershipReviewCounts: [String: Int]
    let integrityIssues: [String]
    let inventoryDigest: String

    var isStructurallyValid: Bool { integrityIssues.isEmpty }

    var hasUnresolvedOwnership: Bool {
        ownershipReviewCounts.values.contains { $0 > 0 }
    }

    fileprivate init(
        sourceSchemaVersion: String,
        rowCounts: [String: Int],
        ownershipReviewCounts: [String: Int],
        integrityIssues: [String]
    ) throws {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.rowCounts = rowCounts
        self.ownershipReviewCounts = ownershipReviewCounts
        let normalizedIssues = integrityIssues.sorted()
        self.integrityIssues = normalizedIssues

        struct DigestPayload: Codable {
            let sourceSchemaVersion: String
            let rowCounts: [String: Int]
            let ownershipReviewCounts: [String: Int]
            let integrityIssues: [String]
        }

        let payload = DigestPayload(
            sourceSchemaVersion: sourceSchemaVersion,
            rowCounts: rowCounts,
            ownershipReviewCounts: ownershipReviewCounts,
            integrityIssues: normalizedIssues
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        self.inventoryDigest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Performs a no-write structural inventory of a V3 SwiftData context.
///
/// The caller is responsible for opening the authoritative V3 source and
/// ensuring no other process is mutating it while this snapshot is collected.
/// This type does not open stores, copy SQLite files, or promote V4.
@MainActor
enum V3MigrationPreflight {
    static func inspect(context: ModelContext) throws -> V3MigrationPreflightReport {
        let developers = try context.fetch(FetchDescriptor<DBDeveloper>())
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let libraryEntries = try context.fetch(FetchDescriptor<DBLibraryEntry>())
        let updates = try context.fetch(FetchDescriptor<DBGameUpdate>())
        let calendarEvents = try context.fetch(FetchDescriptor<DBCalendarEvent>())
        let sparkMetadata = try context.fetch(FetchDescriptor<DBSparkMetadata>())
        let translations = try context.fetch(FetchDescriptor<DBTranslation>())
        let discoverySnapshots = try context.fetch(FetchDescriptor<DBDiscoverySnapshot>())
        let updateWatches = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let statusEvents = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        let appStates = try context.fetch(FetchDescriptor<DBAppState>())
        let gameDetails = try context.fetch(FetchDescriptor<DBGameDetail>())
        let collectionItems = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())

        let rowCounts = [
            "accounts": 0, // V3 has no persisted account registry.
            "developers": developers.count,
            "games": games.count,
            "libraryEntries": libraryEntries.count,
            "gameUpdates": updates.count,
            "calendarEvents": calendarEvents.count,
            "sparkMetadata": sparkMetadata.count,
            "translations": translations.count,
            "discoverySnapshots": discoverySnapshots.count,
            "updateWatches": updateWatches.count,
            "collections": collections.count,
            "libraryStatusEvents": statusEvents.count,
            "appStates": appStates.count,
            "gameDetails": gameDetails.count,
            "collectionItems": collectionItems.count
        ]

        // V3 has no durable account owner on these rows. Keep all of them
        // unassigned until an independent ownership proof or claim flow exists.
        let ownershipReviewCounts = [
            "libraryEntries": libraryEntries.count,
            "collections": collections.count,
            "collectionItems": collectionItems.count,
            "libraryStatusEvents": statusEvents.count,
            "updateWatches": updateWatches.count,
            "calendarEvents": calendarEvents.count,
            "appStates": appStates.count
        ]

        let developerIDs = Set(developers.map(\.id))
        let gameIDs = Set(games.map(\.id))
        let updateByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        let collectionIDs = Set(collections.map(\.id))
        var issues: [String] = []

        for game in games {
            if let developerID = game.developerID, !developerIDs.contains(developerID) {
                issues.append("game.missingDeveloper:\(game.id)")
            }
        }

        for entry in libraryEntries where !gameIDs.contains(entry.gameID) {
            issues.append("libraryEntry.missingGame:\(entry.gameID)")
        }

        for update in updates where !gameIDs.contains(update.gameID) {
            issues.append("gameUpdate.missingGame:\(update.id)")
        }

        for detail in gameDetails where !gameIDs.contains(detail.gameID) {
            issues.append("gameDetail.missingGame:\(detail.gameID)")
        }

        for event in calendarEvents {
            if !gameIDs.contains(event.gameID) {
                issues.append("calendarEvent.missingGame:\(event.id)")
            }
            if let updateID = event.sourceUpdateID,
               let update = updateByID[updateID],
               update.gameID != event.gameID {
                issues.append("calendarEvent.updateGameMismatch:\(event.id)")
            }
        }

        for watch in updateWatches where !gameIDs.contains(watch.gameID) {
            issues.append("updateWatch.missingGame:\(watch.gameID)")
        }

        for event in statusEvents where !gameIDs.contains(event.gameID) {
            issues.append("libraryStatusEvent.missingGame:\(event.id)")
        }

        var seenMemberships = Set<String>()
        for item in collectionItems {
            if !collectionIDs.contains(item.collectionID) {
                issues.append("collectionItem.missingCollection:\(item.id)")
            }
            if !gameIDs.contains(item.gameID) {
                issues.append("collectionItem.missingGame:\(item.id)")
            }
            let membershipKey = Self.membershipKey(
                collectionID: item.collectionID,
                gameID: item.gameID
            )
            if !seenMemberships.insert(membershipKey).inserted {
                issues.append("collectionItem.duplicateMembership:\(item.collectionID)")
            }
            if item.id != DBLibraryCollectionItem.stableID(
                collectionID: item.collectionID,
                gameID: item.gameID
            ) {
                issues.append("collectionItem.nonCanonicalID:\(item.id)")
            }
        }

        return try V3MigrationPreflightReport(
            sourceSchemaVersion: "3.0.0",
            rowCounts: rowCounts,
            ownershipReviewCounts: ownershipReviewCounts,
            integrityIssues: issues
        )
    }

    private static func membershipKey(collectionID: String, gameID: String) -> String {
        "\(collectionID.utf8.count):\(collectionID)\(gameID.utf8.count):\(gameID)"
    }
}
