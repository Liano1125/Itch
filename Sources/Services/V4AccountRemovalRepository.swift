import Foundation
import SwiftData

/// Explicit "remove account from this device" operation for the V4 store.
/// Ordinary sign-out must never call this: it only removes the local credential
/// and leaves the account registry and personal data available for re-login.
@MainActor
final class V4AccountRemovalRepository {
    struct RemovalReport: Equatable {
        let accountID: String
        let libraryEntries: Int
        let collections: Int
        let collectionItems: Int
        let libraryStatusEvents: Int
        let calendarEvents: Int
        let calendarOverlays: Int
        let updateWatches: Int
        let scopedAppStates: Int
    }

    enum RepositoryError: LocalizedError, Equatable {
        case invalidItchUserID
        case accountNotFound(String)
        case duplicateAccount(String)
        case accountIsActive(String)

        var errorDescription: String? {
            switch self {
            case .invalidItchUserID:
                return "A positive numeric itch user ID is required."
            case .accountNotFound(let id):
                return "The V4 account does not exist: \(id)."
            case .duplicateAccount(let id):
                return "Multiple V4 account records match: \(id)."
            }
        }
    }

    private let context: ModelContext
    private let session: ItchAccountSession

    init(context: ModelContext, session: ItchAccountSession) {
        self.context = context
        self.session = session
    }

    /// Deletes one account registry row and every V4 row owned by that account.
    /// Shared catalog/cache/source records and all unassigned legacy/quarantine
    /// rows are deliberately retained. All model mutations are saved together.
    @discardableResult
    func removeAccountAndPersonalData(itchUserID: Int) throws -> RemovalReport {
        guard itchUserID > 0 else { throw RepositoryError.invalidItchUserID }
        let accountID = DBAccount.stableID(itchUserID: itchUserID)
        guard session.identity?.id != accountID else {
            throw RepositoryError.accountIsActive(accountID)
        }
        let accountDescriptor = FetchDescriptor<DBAccount>(
            predicate: #Predicate { $0.id == accountID }
        )
        let accounts = try context.fetch(accountDescriptor)
        guard !accounts.isEmpty else { throw RepositoryError.accountNotFound(accountID) }
        guard accounts.count == 1 else { throw RepositoryError.duplicateAccount(accountID) }

        let libraryDescriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let collectionDescriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let itemDescriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let statusDescriptor = FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let calendarDescriptor = FetchDescriptor<DBAccountCalendarEvent>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let overlayDescriptor = FetchDescriptor<DBAccountCalendarOverlay>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        let watchDescriptor = FetchDescriptor<DBAccountUpdateWatch>(
            predicate: #Predicate { $0.accountID == accountID }
        )

        let library = try context.fetch(libraryDescriptor)
        let collections = try context.fetch(collectionDescriptor)
        let items = try context.fetch(itemDescriptor)
        let statusEvents = try context.fetch(statusDescriptor)
        let calendarEvents = try context.fetch(calendarDescriptor)
        let overlays = try context.fetch(overlayDescriptor)
        let watches = try context.fetch(watchDescriptor)

        let scope = try AppStateScope.itchAccount(userID: itchUserID)
        let appState = ScopedAppStateRepository(context: context)
        let scopedStates = try appState.states(in: scope)

        library.forEach(context.delete)
        collections.forEach(context.delete)
        items.forEach(context.delete)
        statusEvents.forEach(context.delete)
        calendarEvents.forEach(context.delete)
        overlays.forEach(context.delete)
        watches.forEach(context.delete)
        try appState.removeAll(in: scope, save: false)
        context.delete(accounts[0])

        // A single save boundary prevents a successfully removed account row
        // from being committed while its personal rows remain behind.
        try context.save()

        return RemovalReport(
            accountID: accountID,
            libraryEntries: library.count,
            collections: collections.count,
            collectionItems: items.count,
            libraryStatusEvents: statusEvents.count,
            calendarEvents: calendarEvents.count,
            calendarOverlays: overlays.count,
            updateWatches: watches.count,
            scopedAppStates: scopedStates.count
        )
    }
}
