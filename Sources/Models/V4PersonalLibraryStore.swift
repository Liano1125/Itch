import Combine
import Foundation

/// First V4-only observable library store.
///
/// This is intentionally a narrow persistence adapter: it owns account-scoped
/// personal library rows only. Shared game metadata remains in the V4 catalog
/// and is not copied into this store. The legacy PersonalLibraryStore remains
/// untouched until the complete V4 dependency graph is ready for app startup.
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

    private let dependencies: V4AppDependencies

    init(dependencies: V4AppDependencies) {
        self.dependencies = dependencies
    }

    /// Reloads only the currently authenticated account's personal entries.
    /// The captured generation is checked again before publishing the result.
    func reload() throws {
        guard let requestContext = dependencies.session.captureRequestContext() else {
            entries = []
            throw StoreError.noCurrentAccount
        }

        let repository = try dependencies.libraryRepository(for: requestContext.accountID)
        let loadedEntries = try repository.loadEntries()
        guard dependencies.session.isCurrent(requestContext) else {
            throw StoreError.staleSession
        }
        entries = loadedEntries
    }

    /// Saves a single account-owned row. The repository additionally enforces
    /// that the account still exists in the V4 registry.
    func upsert(_ entry: StoredAccountLibraryEntry) throws {
        guard let requestContext = dependencies.session.captureRequestContext() else {
            throw StoreError.noCurrentAccount
        }
        let repository = try dependencies.libraryRepository(for: requestContext.accountID)
        guard dependencies.session.isCurrent(requestContext) else {
            throw StoreError.staleSession
        }
        try repository.upsertEntry(entry)
        guard dependencies.session.isCurrent(requestContext) else {
            throw StoreError.staleSession
        }
        try reload()
    }

    func remove(gameID: String) throws {
        guard let requestContext = dependencies.session.captureRequestContext() else {
            throw StoreError.noCurrentAccount
        }
        let repository = try dependencies.libraryRepository(for: requestContext.accountID)
        guard dependencies.session.isCurrent(requestContext) else {
            throw StoreError.staleSession
        }
        try repository.removeEntry(gameID: gameID)
        guard dependencies.session.isCurrent(requestContext) else {
            throw StoreError.staleSession
        }
        try reload()
    }
}
