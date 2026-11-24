import Combine
import Foundation

/// V4-only observable calendar projection for the currently authenticated itch account.
/// Shared source events are visible to every account; personal events and overlays are scoped.
@MainActor
final class V4CalendarStore: ObservableObject {
    enum StoreError: LocalizedError {
        case noCurrentAccount
        case staleSession

        var errorDescription: String? {
            switch self {
            case .noCurrentAccount:
                return "Sign in to an itch account before accessing its calendar."
            case .staleSession:
                return "The active itch account changed. Reload the calendar before continuing."
            }
        }
    }

    @Published private(set) var events: [ResolvedCalendarV4Event] = []
    private let dependencies: V4AppDependencies

    init(dependencies: V4AppDependencies) {
        self.dependencies = dependencies
    }

    func reload() throws {
        let (context, repository) = try currentRepository()
        let loaded = try repository.resolvedEvents()
        try validateCurrent(context)
        _ = context
        events = loaded
    }

    func upsertSourceEvent(_ event: StoredCalendarSourceEvent) throws {
        let (request, repository) = try currentRepository()
        try repository.upsertSourceEvent(event)
        try validateCurrent(request)
        try reload()
    }

    func upsertPersonalEvent(_ event: StoredAccountCalendarEvent) throws {
        let (request, repository) = try currentRepository()
        try repository.upsertPersonalEvent(event)
        try validateCurrent(request)
        try reload()
    }

    func deletePersonalEvent(eventKey: String) throws {
        let (request, repository) = try currentRepository()
        try repository.deletePersonalEvent(eventKey: eventKey)
        try validateCurrent(request)
        try reload()
    }

    func upsertOverlay(_ overlay: StoredAccountCalendarOverlay) throws {
        let (request, repository) = try currentRepository()
        try repository.upsertOverlay(overlay)
        try validateCurrent(request)
        try reload()
    }

    func deleteOverlay(sourceEventID: String) throws {
        let (request, repository) = try currentRepository()
        try repository.deleteOverlay(sourceEventID: sourceEventID)
        try validateCurrent(request)
        try reload()
    }

    private func currentRepository() throws -> (ItchAccountRequestContext, AccountScopedCalendarRepository) {
        guard let request = dependencies.session.captureRequestContext() else {
            events = []
            throw StoreError.noCurrentAccount
        }
        let repository = try dependencies.calendarRepository(for: request.accountID)
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
