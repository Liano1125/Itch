import Combine
import Foundation

/// V4-only observable update-watch preferences and validators for one active itch account.
@MainActor
final class V4UpdateWatchStore: ObservableObject {
    enum StoreError: LocalizedError {
        case noCurrentAccount
        case staleSession

        var errorDescription: String? {
            switch self {
            case .noCurrentAccount:
                return "Sign in to an itch account before accessing Update Watch."
            case .staleSession:
                return "The active itch account changed. Reload Update Watch before continuing."
            }
        }
    }

    @Published private(set) var watches: [StoredAccountUpdateWatch] = []
    private let dependencies: V4AppDependencies

    init(dependencies: V4AppDependencies) {
        self.dependencies = dependencies
    }

    func reload() throws {
        let (request, repository) = try currentRepository()
        let loaded = try repository.loadWatches()
        try validateCurrent(request)
        watches = loaded
    }

    func upsert(_ watch: StoredAccountUpdateWatch) throws {
        let (request, repository) = try currentRepository()
        try repository.upsert(watch)
        try validateCurrent(request)
        try reload()
    }

    func setEnabled(gameID: String, isEnabled: Bool) throws {
        let (request, repository) = try currentRepository()
        try repository.setEnabled(gameID: gameID, isEnabled: isEnabled)
        try validateCurrent(request)
        try reload()
    }

    func remove(gameID: String) throws {
        let (request, repository) = try currentRepository()
        try repository.delete(gameID: gameID)
        try validateCurrent(request)
        try reload()
    }

    private func currentRepository() throws -> (ItchAccountRequestContext, AccountScopedUpdateWatchRepository) {
        guard let request = dependencies.session.captureRequestContext() else {
            watches = []
            throw StoreError.noCurrentAccount
        }
        let repository = try dependencies.updateWatchRepository(for: request.accountID)
        guard dependencies.session.isCurrent(request) else {
            throw StoreError.staleSession
        }
        return (request, repository)
    }

    private func validateCurrent(_ request: ItchAccountRequestContext) throws {
        guard dependencies.session.isCurrent(request) else {
            throw StoreError.staleSession
        }
    }
}
