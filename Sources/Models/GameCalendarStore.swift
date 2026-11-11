import Foundation
import Combine
import UserNotifications

enum GameCalendarEventKind: String, CaseIterable, Codable, Identifiable {
    case plannedPlay = "计划游玩"
    case release = "预计发售"
    case update = "游戏更新"
    case custom = "其他"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .plannedPlay: return "gamecontroller"
        case .release: return "sparkles"
        case .update: return "arrow.down.circle"
        case .custom: return "calendar"
        }
    }
}

struct GameCalendarEvent: Codable, Identifiable {
    var id: String
    var gameID: String
    var gameTitle: String
    var gameURL: String?
    var title: String
    var date: Date
    var kind: GameCalendarEventKind
    var reminderEnabled: Bool
    var reminderMinutes: Int
    var notes: String
    var sourceFingerprint: String?

    init(id: String = UUID().uuidString, gameID: String, gameTitle: String, gameURL: String?, title: String, date: Date, kind: GameCalendarEventKind, reminderEnabled: Bool = true, reminderMinutes: Int = 60, notes: String = "", sourceFingerprint: String? = nil) {
        self.id = id
        self.gameID = gameID
        self.gameTitle = gameTitle
        self.gameURL = gameURL
        self.title = title
        self.date = date
        self.kind = kind
        self.reminderEnabled = reminderEnabled
        self.reminderMinutes = reminderMinutes
        self.notes = notes
        self.sourceFingerprint = sourceFingerprint
    }
}

@MainActor
final class GameCalendarStore: ObservableObject {
    static let shared = GameCalendarStore()
    @Published private(set) var events: [GameCalendarEvent] = []
    private let repository: GameCalendarRepository
    private let shouldSimulateLoadFailure: () -> Bool
    private var didLoadEvents = false

    private enum LoadError: Error {
        case simulatedFailure
    }

    init(
        repository: GameCalendarRepository? = nil,
        shouldSimulateLoadFailure: @escaping () -> Bool = { false }
    ) {
        self.repository = repository ?? .shared
        self.shouldSimulateLoadFailure = shouldSimulateLoadFailure
        load()
    }

    /// Retries a failed initial read or refreshes the last known-good snapshot.
    func reload() {
        load()
    }

    func add(_ event: GameCalendarEvent) {
        guard didLoadEvents else { return }
        guard !events.contains(where: { $0.id == event.id }) else { return }
        do {
            try repository.performTransaction {
                try repository.saveEvent(event, save: false)
            }
            events.append(event)
            events.sort { $0.date < $1.date }
            Task { await GameNotificationManager.shared.schedule(event) }
        } catch {
            print("itchPocket calendar insert transaction failed: \(error)")
        }
    }

    func addDetectedUpdate(gameID: String, gameTitle: String, gameURL: String, fingerprint: String, detectedAt: Date = Date()) {
        let update = DetectedGameUpdate(
            gameID: gameID,
            gameTitle: gameTitle,
            gameURL: gameURL,
            summary: "itch.io 游戏页面发生变化。",
            fingerprint: fingerprint,
            detectedAt: detectedAt
        )
        _ = addDetectedUpdates([update])
    }

    /// Stages detected calendar events inside the caller's current database transaction.
    /// It deliberately does not mutate the published snapshot; callers reload after commit.
    func stageDetectedUpdates(_ updates: [DetectedGameUpdate]) throws -> [GameCalendarEvent] {
        guard didLoadEvents else { return [] }
        let existing = Set(events.compactMap { event in
            event.sourceFingerprint.map { "\(event.gameID)|\($0)" }
        })
        var seen = existing
        var staged: [GameCalendarEvent] = []
        for update in updates {
            guard seen.insert("\(update.gameID)|\(update.fingerprint)").inserted else { continue }
            let updateID = try repository.updateID(gameID: update.gameID, detectedAt: update.detectedAt)
            let event = GameCalendarEvent(
                gameID: update.gameID,
                gameTitle: update.gameTitle,
                gameURL: update.gameURL,
                title: "检测到游戏页面更新",
                date: update.detectedAt,
                kind: .update,
                reminderEnabled: false,
                notes: "由更新监控自动记录。此日期是页面变化的检测日期，并非经确认的官方发布日期。",
                sourceFingerprint: update.fingerprint
            )
            try repository.saveEvent(event, sourceUpdateID: updateID, save: false)
            staged.append(event)
        }
        return staged
    }

    @discardableResult
    func addDetectedUpdates(_ updates: [DetectedGameUpdate], save shouldSave: Bool = true) -> Int {
        guard didLoadEvents else { return 0 }
        do {
            let staged: [GameCalendarEvent]
            if shouldSave {
                staged = try repository.performTransaction {
                    try stageDetectedUpdates(updates)
                }
                events.append(contentsOf: staged)
                events.sort { $0.date < $1.date }
            } else {
                // Deferred callers own the surrounding transaction and refresh snapshots after commit.
                staged = try stageDetectedUpdates(updates)
            }
            return staged.count
        } catch {
            print("itchPocket detected calendar transaction failed: \(error)")
            return 0
        }
    }

    @discardableResult
    func addHistoricalUpdate(gameID: String, gameTitle: String, gameURL: String?, title: String, summary: String, publishedAt: Date, sourceID: String, postURL: String?) -> Bool {
        let update = GameLibraryUpdate(
            title: title,
            summary: summary,
            publishedAt: publishedAt,
            url: postURL,
            sourceID: sourceID,
            isHistorical: true
        )
        return addHistoricalUpdates(gameID: gameID, gameTitle: gameTitle, gameURL: gameURL, updates: [update]) > 0
    }

    /// Stages historical update rows and their calendar links in the caller's transaction.
    func stageHistoricalUpdates(gameID: String, gameTitle: String, gameURL: String?, updates: [GameLibraryUpdate]) throws -> [GameCalendarEvent] {
        guard didLoadEvents else { return [] }
        let existing = Set(events.compactMap { event in
            event.gameID == gameID ? event.sourceFingerprint : nil
        })
        var seen = existing
        var staged: [GameCalendarEvent] = []
        for update in updates {
            guard let sourceID = update.sourceID else { continue }
            let fingerprint = "devlog:\(sourceID)"
            guard seen.insert(fingerprint).inserted else { continue }
            let updateID = try repository.upsertHistoricalUpdate(
                gameID: gameID,
                update: update,
                save: false
            )
            let event = GameCalendarEvent(
                gameID: gameID,
                gameTitle: gameTitle,
                gameURL: gameURL,
                title: "更新：\(update.title ?? "游戏更新")",
                date: update.publishedAt ?? update.detectedAt,
                kind: .update,
                reminderEnabled: false,
                notes: update.summary + (update.url.map { "\n\($0)" } ?? "") + "\n来源：itch.io Devlog（历史发布日期）",
                sourceFingerprint: fingerprint
            )
            try repository.saveEvent(event, sourceUpdateID: updateID, save: false)
            staged.append(event)
        }
        return staged
    }

    @discardableResult
    func addHistoricalUpdates(gameID: String, gameTitle: String, gameURL: String?, updates: [GameLibraryUpdate], save shouldSave: Bool = true) -> Int {
        guard didLoadEvents else { return 0 }
        do {
            let staged: [GameCalendarEvent]
            if shouldSave {
                staged = try repository.performTransaction {
                    try stageHistoricalUpdates(gameID: gameID, gameTitle: gameTitle, gameURL: gameURL, updates: updates)
                }
                events.append(contentsOf: staged)
                events.sort { $0.date < $1.date }
            } else {
                staged = try stageHistoricalUpdates(gameID: gameID, gameTitle: gameTitle, gameURL: gameURL, updates: updates)
            }
            return staged.count
        } catch {
            print("itchPocket historical calendar transaction failed: \(error)")
            return 0
        }
    }

    func update(_ event: GameCalendarEvent) {
        guard didLoadEvents else { return }
        guard events.contains(where: { $0.id == event.id }) else { return }
        do {
            try repository.performTransaction {
                try repository.saveEvent(event, save: false)
            }
            if let index = events.firstIndex(where: { $0.id == event.id }) {
                events[index] = event
                events.sort { $0.date < $1.date }
            }
            Task {
                GameNotificationManager.shared.cancel(event.id)
                await GameNotificationManager.shared.schedule(event)
            }
        } catch {
            print("itchPocket calendar update transaction failed: \(error)")
        }
    }

    func delete(_ id: String) {
        guard didLoadEvents else { return }
        guard events.contains(where: { $0.id == id }) else { return }
        do {
            try repository.performTransaction {
                try repository.deleteEvent(id: id, save: false)
            }
            events.removeAll { $0.id == id }
            GameNotificationManager.shared.cancel(id)
        } catch {
            print("itchPocket calendar deletion transaction failed: \(error)")
        }
    }

    func events(on date: Date) -> [GameCalendarEvent] {
        events.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date }
    }

    private func load() {
        do {
            if shouldSimulateLoadFailure() {
                throw LoadError.simulatedFailure
            }
            let loadedEvents = try repository.events()
            events = loadedEvents
            didLoadEvents = true
        } catch {
            // Keep the last known-good snapshot. On an initial failure,
            // didLoadEvents remains false and every mutation stays blocked.
            print("itchPocket calendar database load failed: \(error)")
        }
    }

}

final class GameNotificationManager {
    static let shared = GameNotificationManager()
    private let center = UNUserNotificationCenter.current()
    private init() {}

    func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func schedule(_ event: GameCalendarEvent) async {
        guard event.reminderEnabled else { return }
        let allowed = await requestPermission()
        guard allowed else { return }
        let fireDate = event.date.addingTimeInterval(-Double(event.reminderMinutes * 60))
        guard fireDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = event.gameTitle
        content.body = "\(event.title) · \(event.date.formatted(date: .abbreviated, time: .shortened))"
        content.sound = .default
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: event.id, content: content, trigger: trigger)
        try? await center.add(request)
    }

    func cancel(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }
}
