import Foundation
import BackgroundTasks
import UIKit

@MainActor
enum DevlogAutoSync {
    static let taskIdentifier = "com.liano.itchPocket.devlog-refresh"
    private static let interval: TimeInterval = 6 * 60 * 60
    private static let lastSyncKey = "itchPocket.devlogAutoSync.lastAttempt"

    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // iOS may reject duplicate or unavailable background requests.
        }
    }

    static func refreshIfNeeded(
        monitor: GameUpdateMonitorStore,
        library: PersonalLibraryStore,
        calendar: GameCalendarStore,
        force: Bool = false
    ) async {
        let lastAttempt = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < interval {
            scheduleNext()
            return
        }
        guard !library.records.isEmpty else {
            scheduleNext()
            return
        }

        _ = await monitor.syncHistoricalDevlogs(
            records: library.records,
            calendarStore: calendar,
            libraryStore: library
        )
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        scheduleNext()
    }

    static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let operation = Task { @MainActor in
            await refreshIfNeeded(
                monitor: .shared,
                library: .shared,
                calendar: .shared,
                force: true
            )
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = {
            operation.cancel()
        }
    }
}

final class ItchPocketAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: DevlogAutoSync.taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            DevlogAutoSync.handle(refreshTask)
        }
        DevlogAutoSync.scheduleNext()
        return true
    }
}
