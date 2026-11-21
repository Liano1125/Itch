import Foundation

/// Coordinates destructive account removal across persistent V4 data and
/// device notification projections. The repository commits first; notifications
/// are then removed from both account-owned namespaces.
@MainActor
final class V4AccountRemovalCoordinator {
    enum CoordinatorError: LocalizedError {
        case removalAlreadyInProgress(String)

        var errorDescription: String? {
            switch self {
            case .removalAlreadyInProgress(let accountID):
                return "Account removal is already in progress for \(accountID)."
            }
        }
    }

    private let session: ItchAccountSession
    private let repository: V4AccountRemovalRepository
    private let calendarNotifications: AccountCalendarNotificationCoordinator
    private let updateWatchNotifications: AccountUpdateWatchNotificationCoordinator

    init(
        session: ItchAccountSession,
        repository: V4AccountRemovalRepository,
        calendarNotifications: AccountCalendarNotificationCoordinator,
        updateWatchNotifications: AccountUpdateWatchNotificationCoordinator
    ) {
        self.session = session
        self.repository = repository
        self.calendarNotifications = calendarNotifications
        self.updateWatchNotifications = updateWatchNotifications
    }

    @discardableResult
    func removeAccountAndPersonalData(itchUserID: Int) async throws -> V4AccountRemovalRepository.RemovalReport {
        let accountID = DBAccount.stableID(itchUserID: itchUserID)
        guard session.beginAccountRemoval(accountID) else {
            throw CoordinatorError.removalAlreadyInProgress(accountID)
        }
        defer { session.endAccountRemoval(accountID) }

        // Hold the removal reservation across both async notification cleanups.
        // Authentication for this identity is rejected until all device-side
        // projections are gone, preventing a re-login/rebuild from racing clear.
        let report = try repository.removeAccountAndPersonalData(itchUserID: itchUserID)
        await calendarNotifications.clear(accountID: report.accountID)
        await updateWatchNotifications.clear(accountID: report.accountID)
        return report
    }
}
