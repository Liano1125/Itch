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
    private let key = "itchPocket.gameCalendar.v1"

    init() { load() }

    func add(_ event: GameCalendarEvent) {
        events.append(event)
        events.sort { $0.date < $1.date }
        save()
        Task { await GameNotificationManager.shared.schedule(event) }
    }

    func addDetectedUpdate(gameID: String, gameTitle: String, gameURL: String, fingerprint: String, detectedAt: Date = Date()) {
        guard !events.contains(where: { $0.gameID == gameID && $0.sourceFingerprint == fingerprint }) else { return }
        let event = GameCalendarEvent(
            gameID: gameID,
            gameTitle: gameTitle,
            gameURL: gameURL,
            title: "检测到游戏页面更新",
            date: detectedAt,
            kind: .update,
            reminderEnabled: false,
            notes: "由更新监控自动记录。此日期是页面变化的检测日期，并非经确认的官方发布日期。",
            sourceFingerprint: fingerprint
        )
        events.append(event)
        events.sort { $0.date < $1.date }
        save()
    }

    @discardableResult
    func addHistoricalUpdate(gameID: String, gameTitle: String, gameURL: String?, title: String, summary: String, publishedAt: Date, sourceID: String, postURL: String?) -> Bool {
        let fingerprint = "devlog:\(sourceID)"
        guard !events.contains(where: { $0.gameID == gameID && $0.sourceFingerprint == fingerprint }) else { return false }
        let linkNote = postURL.map { "\n\($0)" } ?? ""
        let event = GameCalendarEvent(
            gameID: gameID,
            gameTitle: gameTitle,
            gameURL: gameURL,
            title: "更新：\(title)",
            date: publishedAt,
            kind: .update,
            reminderEnabled: false,
            notes: summary + linkNote + "\n来源：itch.io Devlog（历史发布日期）",
            sourceFingerprint: fingerprint
        )
        events.append(event)
        events.sort { $0.date < $1.date }
        save()
        return true
    }

    func update(_ event: GameCalendarEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        events.sort { $0.date < $1.date }
        save()
        Task {
            GameNotificationManager.shared.cancel(event.id)
            await GameNotificationManager.shared.schedule(event)
        }
    }

    func delete(_ id: String) {
        events.removeAll { $0.id == id }
        save()
        GameNotificationManager.shared.cancel(id)
    }

    func events(on date: Date) -> [GameCalendarEvent] {
        events.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date }
    }

    private func load() {
        events = (AppDataStore.decode([GameCalendarEvent].self, forKey: key) ?? []).sorted { $0.date < $1.date }
    }

    private func save() {
        AppDataStore.encode(events, forKey: key)
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
