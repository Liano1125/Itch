import Foundation
import SwiftData

/// Read-only validation of V4 account ownership and cross-record references.
/// Diagnostics expose stable codes only; row values and account identifiers are never emitted.
struct V4StoreReferenceVerificationReport: Codable, Equatable {
    let checksPerformed: Int
    let diagnostics: [String]
    var isValid: Bool { diagnostics.isEmpty }
}

@MainActor
enum V4StoreReferenceVerifier {
    static func verify(context: ModelContext) throws -> V4StoreReferenceVerificationReport {
        guard !context.hasChanges else {
            return V4StoreReferenceVerificationReport(
                checksPerformed: 0,
                diagnostics: ["v4.references.pendingContextChanges"]
            )
        }

        let accounts = try context.fetch(FetchDescriptor<DBAccount>())
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let entries = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>())
        let collections = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>())
        let items = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>())
        let statusEvents = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>())
        let appStates = try context.fetch(FetchDescriptor<DBScopedAppState>())
        let updates = try context.fetch(FetchDescriptor<DBGameUpdate>())
        let sparkMetadata = try context.fetch(FetchDescriptor<DBSparkMetadata>())
        let sourceEvents = try context.fetch(FetchDescriptor<DBCalendarSourceEvent>())
        let accountEvents = try context.fetch(FetchDescriptor<DBAccountCalendarEvent>())
        let overlays = try context.fetch(FetchDescriptor<DBAccountCalendarOverlay>())
        let legacyCalendarEvents = try context.fetch(FetchDescriptor<DBLegacyCalendarEvent>())
        let accountWatches = try context.fetch(FetchDescriptor<DBAccountUpdateWatch>())
        let legacyWatches = try context.fetch(FetchDescriptor<DBLegacyUpdateWatch>())

        var diagnostics = Set<String>()
        let accountIDs = Set(accounts.map(\.id))
        let gameIDs = Set(games.map(\.id))
        let updateIDs = Set(updates.map(\.id))
        let sourceEventIDs = Set(sourceEvents.map(\.id))
        var checksPerformed = 0

        func check(_ condition: Bool, _ code: String) {
            checksPerformed += 1
            if !condition { diagnostics.insert(code) }
        }

        for account in accounts {
            check(account.itchUserID > 0 &&
                  account.id == DBAccount.stableID(itchUserID: account.itchUserID),
                  "v4.account.identityMismatch")
        }

        for entry in entries {
            check(entry.id == ItchPocketSchemaV4.DBLibraryEntry.stableID(
                accountID: entry.accountID, gameID: entry.gameID
            ), "v4.libraryEntry.stableIdentityMismatch")
            check(entry.accountID == nil || accountIDs.contains(entry.accountID!),
                  "v4.libraryEntry.unknownAccount")
            check(gameIDs.contains(entry.gameID), "v4.libraryEntry.missingGame")
        }

        for collection in collections {
            check(collection.id == ItchPocketSchemaV4.DBLibraryCollection.stableID(
                accountID: collection.accountID, collectionKey: collection.collectionKey
            ), "v4.collection.stableIdentityMismatch")
            check(collection.accountID == nil || accountIDs.contains(collection.accountID!),
                  "v4.collection.unknownAccount")
        }

        for item in items {
            check(item.id == ItchPocketSchemaV4.DBLibraryCollectionItem.stableID(
                accountID: item.accountID,
                collectionKey: item.collectionKey,
                gameID: item.gameID
            ), "v4.collectionItem.stableIdentityMismatch")
            check(item.accountID == nil || accountIDs.contains(item.accountID!),
                  "v4.collectionItem.unknownAccount")
            let expectedCollectionID = ItchPocketSchemaV4.DBLibraryCollection.stableID(
                accountID: item.accountID, collectionKey: item.collectionKey
            )
            check(collections.contains { $0.id == expectedCollectionID },
                  "v4.collectionItem.missingCollection")
            check(gameIDs.contains(item.gameID), "v4.collectionItem.missingGame")
        }

        for event in statusEvents {
            check(event.id == ItchPocketSchemaV4.DBLibraryStatusEvent.stableID(
                accountID: event.accountID, eventKey: event.eventKey
            ), "v4.statusEvent.stableIdentityMismatch")
            check(event.accountID == nil || accountIDs.contains(event.accountID!),
                  "v4.statusEvent.unknownAccount")
            check(gameIDs.contains(event.gameID), "v4.statusEvent.missingGame")
        }

        for state in appStates {
            check(!state.scopeID.isEmpty && !state.logicalKey.isEmpty &&
                  state.id == DBScopedAppState.stableID(
                    scopeID: state.scopeID, logicalKey: state.logicalKey
                  ), "v4.appState.stableIdentityMismatch")
        }

        for metadata in sparkMetadata {
            check(gameIDs.contains(metadata.gameID), "v4.sparkMetadata.missingGame")
        }

        for event in sourceEvents {
            check(event.id == DBCalendarSourceEvent.stableID(
                sourceFingerprint: event.sourceFingerprint
            ), "v4.calendarSource.stableIdentityMismatch")
            check(gameIDs.contains(event.gameID), "v4.calendarSource.missingGame")
            check(event.sourceUpdateID == nil || updateIDs.contains(event.sourceUpdateID!),
                  "v4.calendarSource.missingSourceUpdate")
        }

        for event in accountEvents {
            check(!event.accountID.isEmpty &&
                  event.id == DBAccountCalendarEvent.stableID(
                    accountID: event.accountID, eventKey: event.eventKey
                  ), "v4.accountCalendarEvent.stableIdentityMismatch")
            check(accountIDs.contains(event.accountID), "v4.accountCalendarEvent.unknownAccount")
            check(gameIDs.contains(event.gameID), "v4.accountCalendarEvent.missingGame")
        }

        for overlay in overlays {
            check(overlay.id == DBAccountCalendarOverlay.stableID(
                accountID: overlay.accountID, sourceEventID: overlay.sourceEventID
            ), "v4.calendarOverlay.stableIdentityMismatch")
            check(accountIDs.contains(overlay.accountID), "v4.calendarOverlay.unknownAccount")
            check(sourceEventIDs.contains(overlay.sourceEventID),
                  "v4.calendarOverlay.missingSourceEvent")
        }

        for event in legacyCalendarEvents {
            check(event.id == DBLegacyCalendarEvent.stableID(
                originalEventID: event.originalEventID
            ), "v4.legacyCalendar.stableIdentityMismatch")
        }

        for watch in accountWatches {
            check(watch.id == DBAccountUpdateWatch.stableID(
                accountID: watch.accountID, gameID: watch.gameID
            ), "v4.accountUpdateWatch.stableIdentityMismatch")
            check(accountIDs.contains(watch.accountID), "v4.accountUpdateWatch.unknownAccount")
            check(gameIDs.contains(watch.gameID), "v4.accountUpdateWatch.missingGame")
        }

        for watch in legacyWatches {
            check(watch.id == DBLegacyUpdateWatch.stableID(gameID: watch.originalGameID),
                  "v4.legacyUpdateWatch.stableIdentityMismatch")
            if watch.integrityIssue == nil {
                check(gameIDs.contains(watch.originalGameID), "v4.legacyUpdateWatch.missingGame")
            } else if watch.integrityIssue == "missing-game" {
                check(!gameIDs.contains(watch.originalGameID),
                      "v4.legacyUpdateWatch.quarantineMismatch")
            } else {
                check(false, "v4.legacyUpdateWatch.unknownIntegrityIssue")
            }
        }

        return V4StoreReferenceVerificationReport(
            checksPerformed: checksPerformed,
            diagnostics: diagnostics.sorted()
        )
    }
}
