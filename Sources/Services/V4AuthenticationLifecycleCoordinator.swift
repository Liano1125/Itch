import Combine
import Foundation

/// Keeps the V4 account registry synchronized with the authenticated itch session
/// while the production UI and its data stores remain on V3.
@MainActor
final class V4AuthenticationLifecycleCoordinator: ObservableObject {
    @Published private(set) var registeredAccountID: String?
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

    /// Register the currently authenticated identity. Signing out only clears
    /// the active projection; it deliberately does not remove the account row.
    func synchronizeAuthenticatedSession(using session: ItchAccountSession) {
        guard let request = session.captureRequestContext() else {
            registeredAccountID = nil
            errorMessage = nil
            return
        }

        do {
            let runtime: V4AppDependencies
            if let dependencies, dependencies.session === session {
                runtime = dependencies
            } else {
                runtime = try makeDependencies(session)
                guard runtime.session === session else {
                    throw LifecycleError.sessionMismatch
                }
            }

            _ = try runtime.recordAuthenticatedSession(request)
            dependencies = runtime
            registeredAccountID = request.accountID
            errorMessage = nil
        } catch {
            registeredAccountID = nil
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
