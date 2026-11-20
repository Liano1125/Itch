import Foundation

/// Coordinates destructive account removal across persistent V4 data and
/// device notification projections. The repository commits first; notifications
/// are then removed from both account-owned namespaces.
@MainActor
final class V4AccountRemovalCoordinator {
    private let repository: V4AccountRemovalRepository
    private let calendarNotifications: AccountCalendarNotificationCoordinator
    private let updateWatchNotifications: AccountUpdateWatchNotificationCoordinator

    init(
        repository: V4AccountRemovalRepository,
        calendarNotifications: AccountCalendarNotificationCoordinator,
        updateWatchNotifications: AccountUpdateWatchNotificationCoordinator
    ) {
        self.repository = repository
        self.calendarNotifications = calendarNotifications
        self.updateWatchNotifications = updateWatchNotifications
    }

    @discardableResult
    func removeAccountAndPersonalData(itchUserID: Int) async throws -> V4AccountRemovalRepository.RemovalReport {
        // The repository rejects active accounts and commits only the selected
        // account's personal V4 rows. Do not clear device notifications unless
        // the persistent removal succeeds.
        let report = try repository.removeAccountAndPersonalData(itchUserID: itchUserID)
        await calendarNotifications.clear(accountID: report.accountID)
        await updateWatchNotifications.clear(accountID: report.accountID)
        return report
    }
}
