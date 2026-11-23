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

    /// Opens V4 and completes the one-time Patreon reauthentication gate before
    /// returning a runtime that can be attached to the production UI. This
    /// method is deliberately not called by the current V3 app entry point.
    /// The injectable preparation closure keeps the ordering testable without
    /// touching a developer's real Keychain in unit tests.
    static func openForProductionActivation(
        in applicationSupportDirectory: URL? = nil,
        session: ItchAccountSession? = nil,
        prepareForActivation: (V4AppDependencies) throws -> Void = {
            try $0.prepareForProductionActivation()
        }
    ) throws -> V4AppDependencies {
        let dependencies = try open(
            in: applicationSupportDirectory,
            session: session
        )
        try prepareForActivation(dependencies)
        return dependencies
    }

    /// Run only at the actual V4 production cutover, never while constructing
    /// a store for tests or previews. This forces a fresh Patreon login without
    /// coupling ordinary database initialization to Keychain availability.
    func prepareForProductionActivation() throws {
        try V4PatreonReauthenticationGate.resetLegacySessionIfNeeded()
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

    /// Creates the V4 observable stores from this single dependency graph.
    /// Each store resolves the active account at operation time, so creating
    /// the graph while signed out does not capture a stale account identity.
    func makePersonalLibraryStore() -> V4PersonalLibraryStore {
        V4PersonalLibraryStore(dependencies: self)
    }

    func makeCalendarStore() -> V4CalendarStore {
        V4CalendarStore(dependencies: self)
    }

    func makeUpdateWatchStore() -> V4UpdateWatchStore {
        V4UpdateWatchStore(dependencies: self)
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
