import Foundation
import SwiftData

/// Owns the isolated V4 persistence graph without changing the production V3
/// startup path. Views can receive this object later through explicit injection.
@MainActor
final class V4AppDependencies {
    enum DependencyError: LocalizedError {
        case noAuthenticatedAccount
        case accountNotRegistered(String)

        var errorDescription: String? {
            switch self {
            case .noAuthenticatedAccount:
                return "An authenticated itch account is required for personal data."
            case .accountNotRegistered(let accountID):
                return "The itch account is not registered in the V4 database: \(accountID)."
            }
        }
    }

    let container: ModelContainer
    let session: ItchAccountSession

    private let registry: V4AccountRegistryRepository
    private let authenticatedRegistryBridge: V4AuthenticatedAccountRegistryBridge

    var modelContext: ModelContext { container.mainContext }

    private init(container: ModelContainer, session: ItchAccountSession) {
        self.container = container
        self.session = session
        self.registry = V4AccountRegistryRepository(context: container.mainContext)
        self.authenticatedRegistryBridge = V4AuthenticatedAccountRegistryBridge(
            session: session,
            context: container.mainContext
        )
    }

    /// Opens only the clean V4 store. This factory never reads, copies, or
    /// modifies the existing V3 production database.
    static func open(
        in applicationSupportDirectory: URL? = nil,
        session: ItchAccountSession? = nil
    ) throws -> V4AppDependencies {
        let supportDirectory = try applicationSupportDirectory ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let storeURL = try V4FreshStoreBootstrap.prepareStore(
            in: supportDirectory
        )
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-runtime",
            schema: schema,
            url: storeURL
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return V4AppDependencies(container: container, session: session ?? ItchAccountSession())
    }

    /// Persist a verified login only when its captured session context is still
    /// current. OAuth tokens remain the responsibility of Keychain storage.
    @discardableResult
    func recordAuthenticatedSession(
        _ requestContext: ItchAccountRequestContext,
        at date: Date = .now
    ) throws -> DBAccount {
        try authenticatedRegistryBridge.recordAuthenticatedSession(
            requestContext,
            at: date
        )
    }

    func registeredAccounts() throws -> [DBAccount] {
        try registry.loadAccounts()
    }

    func libraryRepository(for accountID: String? = nil) throws -> AccountScopedLibraryRepository {
        try AccountScopedLibraryRepository(
            context: requireContext(for: accountID),
            accountID: resolvedAccountID(accountID)
        )
    }

    func calendarRepository(for accountID: String? = nil) throws -> AccountScopedCalendarRepository {
        try AccountScopedCalendarRepository(
            context: requireContext(for: accountID),
            accountID: resolvedAccountID(accountID)
        )
    }

    func updateWatchRepository(for accountID: String? = nil) throws -> AccountScopedUpdateWatchRepository {
        try AccountScopedUpdateWatchRepository(
            context: requireContext(for: accountID),
            accountID: resolvedAccountID(accountID)
        )
    }

    private func resolvedAccountID(_ requestedAccountID: String?) throws -> String {
        if let requestedAccountID { return requestedAccountID }
        guard let activeID = session.identity?.id else {
            throw DependencyError.noAuthenticatedAccount
        }
        return activeID
    }

    private func requireContext(for requestedAccountID: String?) throws -> ModelContext {
        let accountID = try resolvedAccountID(requestedAccountID)
        let descriptor = FetchDescriptor<DBAccount>(
            predicate: #Predicate { $0.id == accountID }
        )
        guard try !container.mainContext.fetch(descriptor).isEmpty else {
            throw DependencyError.accountNotRegistered(accountID)
        }
        return container.mainContext
    }
}
