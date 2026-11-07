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
    private let database = AppDatabase.shared

    init() { load() }

    func add(_ event: GameCalendarEvent) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        events.sort { $0.date < $1.date }
        persist(event)
        Task { await GameNotificationManager.shared.schedule(event) }
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

    @discardableResult
    func addDetectedUpdates(_ updates: [DetectedGameUpdate], save shouldSave: Bool = true) -> Int {
        let context = database.context
        var inserted = 0
        for update in updates {
            guard !events.contains(where: { $0.gameID == update.gameID && $0.sourceFingerprint == update.fingerprint }) else { continue }
            let descriptor = FetchDescriptor<DBGameUpdate>(
                predicate: #Predicate { $0.gameID == update.gameID && $0.detectedAt == update.detectedAt }
            )
            let updateID = try? context.fetch(descriptor).first?.id
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
            events.append(event)
            persist(event, sourceUpdateID: updateID ?? nil, save: false)
            inserted += 1
        }
        if inserted > 0 {
            events.sort { $0.date < $1.date }
            if shouldSave {
                do { try database.save() }
                catch { print("itchPocket detected calendar batch save failed: \(error)") }
            }
        }
        return inserted
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

    @discardableResult
    func addHistoricalUpdates(gameID: String, gameTitle: String, gameURL: String?, updates: [GameLibraryUpdate]) -> Int {
        let context = database.context
        var inserted = 0
        for update in updates {
            guard let sourceID = update.sourceID else { continue }
            let fingerprint = "devlog:\(sourceID)"
            guard !events.contains(where: { $0.gameID == gameID && $0.sourceFingerprint == fingerprint }) else { continue }
            let descriptor = FetchDescriptor<DBGameUpdate>(
                predicate: #Predicate { $0.gameID == gameID && $0.sourceID == sourceID }
            )
            guard let storedUpdate = try? context.fetch(descriptor).first else { continue }
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
            events.append(event)
            persist(event, sourceUpdateID: storedUpdate.id, save: false)
            inserted += 1
        }
        if inserted > 0 {
            events.sort { $0.date < $1.date }
            do { try database.save() }
            catch { print("itchPocket historical calendar batch save failed: \(error)") }
        }
        return inserted
    }

    func update(_ event: GameCalendarEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        events.sort { $0.date < $1.date }
        persist(event)
        Task {
            GameNotificationManager.shared.cancel(event.id)
            await GameNotificationManager.shared.schedule(event)
        }
    }

    func delete(_ id: String) {
        events.removeAll { $0.id == id }
        do {
            let descriptor = FetchDescriptor<DBCalendarEvent>(predicate: #Predicate { $0.id == id })
            if let item = try database.context.fetch(descriptor).first {
                database.context.delete(item)
                try database.save()
            }
        } catch {
            print("itchPocket calendar deletion failed: \(error)")
        }
        GameNotificationManager.shared.cancel(id)
    }

    func events(on date: Date) -> [GameCalendarEvent] {
        events.filter { Calendar.current.isDate($0.date, inSameDayAs: date) }.sorted { $0.date < $1.date }
    }

    private func load() {
        let context = database.context
        do {
            let storedEvents = try context.fetch(FetchDescriptor<DBCalendarEvent>())
            let games = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBGame>()).map { ($0.id, $0) })
            let updates = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBGameUpdate>()).map { ($0.id, $0) })
            events = storedEvents.compactMap { stored in
                let update = stored.sourceUpdateID.flatMap { updates[$0] }
                let game = games[stored.gameID]
                let title = update?.title.map { "更新：\($0)" } ?? stored.title ?? "日历事件"
                let date = update?.publishedAt ?? update?.detectedAt ?? stored.date ?? .now
                let notes: String
                if let update {
                    notes = update.summary + (update.url.map { "\n\($0)" } ?? "") + (update.isHistorical ? "\n来源：itch.io Devlog（历史发布日期）" : "")
                } else {
                    notes = stored.notes ?? ""
                }
                return GameCalendarEvent(
                    id: stored.id,
                    gameID: stored.gameID,
                    gameTitle: game?.title ?? "未知游戏",
                    gameURL: game?.gameURL,
                    title: title,
                    date: date,
                    kind: GameCalendarEventKind(rawValue: stored.kind) ?? .custom,
                    reminderEnabled: stored.reminderEnabled,
                    reminderMinutes: stored.reminderMinutes,
                    notes: notes,
                    sourceFingerprint: stored.sourceFingerprint
                )
            }.sorted { $0.date < $1.date }
        } catch {
            print("itchPocket calendar database load failed: \(error)")
            events = []
        }
    }

    private func persist(_ event: GameCalendarEvent, sourceUpdateID: String? = nil, save shouldSave: Bool = true) {
        let context = database.context
        do {
            let descriptor = FetchDescriptor<DBCalendarEvent>(predicate: #Predicate { $0.id == event.id })
            let item = try context.fetch(descriptor).first ?? DBCalendarEvent(
                id: event.id,
                gameID: event.gameID,
                kind: event.kind.rawValue
            )
            if item.modelContext == nil { context.insert(item) }
            item.gameID = event.gameID
            item.kind = event.kind.rawValue
            item.reminderEnabled = event.reminderEnabled
            item.reminderMinutes = event.reminderMinutes
            item.sourceFingerprint = event.sourceFingerprint
            if let sourceUpdateID {
                // Devlog title, summary and published date are read from DBGameUpdate.
                item.sourceUpdateID = sourceUpdateID
                item.title = event.title == "检测到游戏页面更新" ? event.title : nil
                item.date = nil
                item.notes = nil
            } else {
                item.sourceUpdateID = nil
                item.title = event.title
                item.date = event.date
                item.notes = event.notes
            }
            if shouldSave { try database.save() }
        } catch {
            print("itchPocket calendar database write failed: \(error)")
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
