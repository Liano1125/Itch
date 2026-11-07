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
        let lastAttempt = try? AppDatabase.shared.state(for: lastSyncKey)?.dateValue
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
        try? AppDatabase.shared.setState(Date(), for: lastSyncKey)
        scheduleNext()
    }

    /// Warm the calendar's Chinese translations before the user opens the calendar.
    /// Existing TranslationCache entries are reused, so this does not repeatedly spend translation quota.
    static func prefetchCalendarTranslations(events: [GameCalendarEvent], limit: Int = 80) async {
        guard TranslationService.isConfigured else { return }
        let updates = events
            .filter { $0.kind == .update }
            .sorted { $0.date > $1.date }
            .prefix(max(1, limit))

        for event in updates {
            if Task.isCancelled { return }
            let title = event.title
                .replacingOccurrences(of: "更新：", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                _ = try? await TranslationService.translateCached(
                    title,
                    scope: "calendar-event-title:\(event.id)"
                )
            }

            let note = event.notes.components(separatedBy: "\n")
                .filter { !$0.hasPrefix("https://") && !$0.hasPrefix("http://") && !$0.hasPrefix("来源：") }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                _ = try? await TranslationService.translateCached(
                    note,
                    scope: "calendar-event-note:\(event.id)"
                )
            }
        }
    }

    static func handle(_ task: BGAppRefreshTask) {
        scheduleNext()
        let operation = Task { @MainActor in
            await refreshIfNeeded(
                monitor: .shared,
                library: .shared,
                calendar: .shared
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
            Task { @MainActor in
                DevlogAutoSync.handle(refreshTask)
            }
        }
        DevlogAutoSync.scheduleNext()
        return true
    }
}
