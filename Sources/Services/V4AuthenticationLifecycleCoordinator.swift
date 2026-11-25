import Combine
import Foundation

/// Keeps the V4 account registry and its account-scoped library projection
/// synchronized with the authenticated itch session while production UI/data
/// stores remain on V3.
@MainActor
final class V4AuthenticationLifecycleCoordinator: ObservableObject {
    @Published private(set) var registeredAccountID: String?
    @Published private(set) var personalLibraryStore: V4PersonalLibraryStore?
    @Published private(set) var errorMessage: String?

    typealias DependenciesFactory = @MainActor (ItchAccountSession) throws -> V4AppDependencies

    private let makeDependencies: DependenciesFactory
    private var dependencies: V4AppDependencies?

    init(
        makeDependencies: @escaping DependenciesFactory = { session in
            try V4AppDependencies.open(session: session)
        }
    ) {
        self.makeDependencies = makeDependencies
    }

    /// Register the authenticated identity and publish a freshly validated
    /// account-scoped library projection. Signing out drops the projection but
    /// deliberately preserves the account registry row and its personal data.
    func synchronizeAuthenticatedSession(using session: ItchAccountSession) {
        guard let request = session.captureRequestContext() else {
            registeredAccountID = nil
            personalLibraryStore = nil
            errorMessage = nil
            return
        }

        // Never leave the previous account's projection visible during a switch
        // or after a failed synchronization.
        if registeredAccountID != request.accountID {
            personalLibraryStore = nil
        }

        do {
            let runtime: V4AppDependencies
            if let dependencies, dependencies.session === session {
                runtime = dependencies
            } else {
                // A replacement auth-session object must never reuse a store
                // backed by the previous session, even if the numeric itch ID
                // happens to be identical.
                registeredAccountID = nil
                personalLibraryStore = nil
                runtime = try makeDependencies(session)
                guard runtime.session === session else {
                    throw LifecycleError.sessionMismatch
                }
            }

            _ = try runtime.recordAuthenticatedSession(request)

            let libraryStore = personalLibraryStore ?? runtime.makePersonalLibraryStore()
            try libraryStore.reload()
            try libraryStore.reloadCollections()
            try libraryStore.reloadStatusEvents()

            dependencies = runtime
            registeredAccountID = request.accountID
            personalLibraryStore = libraryStore
            errorMessage = nil
        } catch {
            registeredAccountID = nil
            personalLibraryStore = nil
            errorMessage = error.localizedDescription
        }
    }

    private enum LifecycleError: LocalizedError {
        case sessionMismatch

        var errorDescription: String? {
            "The V4 runtime was created for a different itch authentication session."
        }
    }
}
