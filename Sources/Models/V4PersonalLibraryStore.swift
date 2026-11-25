import Combine
import Foundation

/// First V4-only observable library store.
///
/// Personal fields, collections, and status history are scoped to the live
/// itch account. Shared game metadata remains in the V4 catalog.
@MainActor
final class V4PersonalLibraryStore: ObservableObject {
    enum StoreError: LocalizedError {
        case noCurrentAccount
        case staleSession

        var errorDescription: String? {
            switch self {
            case .noCurrentAccount:
                return "Sign in to an itch account before accessing its library."
            case .staleSession:
                return "The active itch account changed. Reload the library before continuing."
            }
        }
    }

    @Published private(set) var entries: [StoredAccountLibraryEntry] = []
    @Published private(set) var collections: [StoredAccountLibraryCollection] = []
    @Published private(set) var collectionItems: [StoredAccountLibraryCollectionItem] = []
    @Published private(set) var statusEvents: [StoredAccountLibraryStatusEvent] = []
    @Published private(set) var libraryGames: [StoredAccountLibraryGame] = []

    let dependencies: V4AppDependencies

    init(dependencies: V4AppDependencies) {
        self.dependencies = dependencies
    }

    /// Reloads only the currently authenticated account's personal entries.
    func reload() throws {
        let (request, repository) = try currentRepository()
        let loaded = try repository.loadEntries()
        try validateCurrent(request)
        entries = loaded
    }

    /// Adds a game and its initial status-history event in one persistence transaction.
    /// Use this for first-time membership; `upsert` remains for editing an existing entry.
    func addToLibrary(_ entry: StoredAccountLibraryEntry, initialEventKey: String) throws {
        let (request, repository) = try currentRepository()
        try repository.addEntryWithInitialStatus(entry, eventKey: initialEventKey)
        try validateCurrent(request)
        try reload()
        try reloadStatusEvents()
    }

    func upsert(_ entry: StoredAccountLibraryEntry) throws {
        let (request, repository) = try currentRepository()
        try repository.upsertEntry(entry)
        try validateCurrent(request)
        try reload()
    }

    func remove(gameID: String) throws {
        let (request, repository) = try currentRepository()
        try repository.removeEntry(gameID: gameID)
        try validateCurrent(request)
        try reload()
        // The repository removes these account-owned rows in the same save
        // boundary. Keep the already-published projections in sync as well.
        collectionItems.removeAll { $0.gameID == gameID }
        statusEvents.removeAll { $0.gameID == gameID }
    }


    /// Changes the current status and records its history as one transaction.
    func changeStatus(gameID: String, toStatus: String, eventKey: String, at date: Date = .now) throws {
        let (request, repository) = try currentRepository()
        try repository.changeStatus(
            gameID: gameID,
            toStatus: toStatus,
            eventKey: eventKey,
            at: date
        )
        try validateCurrent(request)
        try reload()
        try reloadStatusEvents()
    }

    // MARK: - Account-owned collections

    func reloadCollections() throws {
        let (request, repository) = try currentRepository()
        let loaded = try repository.loadCollections()
        try validateCurrent(request)
        collections = loaded
    }

    func reloadCollectionItems(collectionKey: String) throws {
        let (request, repository) = try currentRepository()
        let loaded = try repository.loadCollectionItems(collectionKey: collectionKey)
        try validateCurrent(request)
        collectionItems = loaded
    }

    func upsertCollection(collectionKey: String, title: String) throws {
        let (request, repository) = try currentRepository()
        try repository.upsertCollection(collectionKey: collectionKey, title: title)
        try validateCurrent(request)
        try reloadCollections()
    }

    func removeCollection(collectionKey: String) throws {
        let (request, repository) = try currentRepository()
        try repository.removeCollection(collectionKey: collectionKey)
        try validateCurrent(request)
        try reloadCollections()
        try reloadCollectionItems(collectionKey: collectionKey)
    }

    func addGameToCollection(collectionKey: String, gameID: String, sortOrder: Int = 0) throws {
        let (request, repository) = try currentRepository()
        try repository.addGameToCollection(
            collectionKey: collectionKey,
            gameID: gameID,
            sortOrder: sortOrder
        )
        try validateCurrent(request)
        try reloadCollectionItems(collectionKey: collectionKey)
    }

    func removeGameFromCollection(collectionKey: String, gameID: String) throws {
        let (request, repository) = try currentRepository()
        try repository.removeGameFromCollection(collectionKey: collectionKey, gameID: gameID)
        try validateCurrent(request)
        try reloadCollectionItems(collectionKey: collectionKey)
    }

    // MARK: - Account-owned status history

    func reloadStatusEvents() throws {
        let (request, repository) = try currentRepository()
        let loaded = try repository.loadStatusEvents()
        try validateCurrent(request)
        statusEvents = loaded
    }

    func recordStatusEvent(
        eventKey: String,
        gameID: String,
        fromStatus: String?,
        toStatus: String
    ) throws {
        let (request, repository) = try currentRepository()
        try repository.recordStatusEvent(
            eventKey: eventKey,
            gameID: gameID,
            fromStatus: fromStatus,
            toStatus: toStatus
        )
        try validateCurrent(request)
        try reloadStatusEvents()
    }

    private func currentRepository() throws -> (ItchAccountRequestContext, AccountScopedLibraryRepository) {
        guard let request = dependencies.session.captureRequestContext() else {
            entries = []
            collections = []
            collectionItems = []
            statusEvents = []
            libraryGames = []
            throw StoreError.noCurrentAccount
        }
        let repository = try dependencies.libraryRepository(for: request.accountID)
        try validateCurrent(request)
        return (request, repository)
    }

    func validateCurrent(_ request: ItchAccountRequestContext) throws {
        guard dependencies.session.isCurrent(request) else {
            throw StoreError.staleSession
        }
    }
}
