import Foundation
import SwiftData

/// Owns all SwiftData access for calendar events and their optional game/update context.
@MainActor
final class GameCalendarRepository {
    static let shared = GameCalendarRepository(database: .shared)

    private let database: AppDatabase
    private let context: ModelContext

    init(database: AppDatabase) {
        self.database = database
        self.context = database.context
    }

    func events() throws -> [GameCalendarEvent] {
        let storedEvents = try context.fetch(FetchDescriptor<DBCalendarEvent>())
        let games = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBGame>()).map { ($0.id, $0) })
        let updates = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<DBGameUpdate>()).map { ($0.id, $0) })

        return storedEvents.compactMap { stored in
            let linkedUpdate = stored.sourceUpdateID.flatMap { updates[$0] }
            let update = linkedUpdate.flatMap { $0.gameID == stored.gameID ? $0 : nil }
            let game = games[stored.gameID]
            let title = update?.title.map { "更新：\($0)" } ?? stored.title ?? "日历事件"
            let date = update?.publishedAt
                ?? (update?.isHistorical == true ? stored.date : update?.detectedAt)
                ?? stored.date
                ?? .now
            let notes: String
            if let update, !update.summary.isEmpty {
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
    }

    func updateID(gameID: String, detectedAt: Date) throws -> String? {
        let descriptor = FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.gameID == gameID && $0.detectedAt == detectedAt }
        )
        return try context.fetch(descriptor).first?.id
    }

    /// Inserts or refreshes a historical Devlog row while preserving its stable database identity.
    func upsertHistoricalUpdate(gameID: String, update: GameLibraryUpdate) throws -> String {
        guard let sourceID = update.sourceID else {
            throw RepositoryError.missingHistoricalSourceID
        }
        let descriptor = FetchDescriptor<DBGameUpdate>(
            predicate: #Predicate { $0.gameID == gameID && $0.sourceID == sourceID }
        )
        let stored: DBGameUpdate
        if let existing = try context.fetch(descriptor).first {
            stored = existing
            stored.title = update.title
            stored.summary = update.summary
            stored.publishedAt = update.publishedAt
            stored.url = update.url
            stored.isHistorical = true
        } else {
            stored = DBGameUpdate(
                id: update.id,
                gameID: gameID,
                title: update.title,
                summary: update.summary,
                detectedAt: update.detectedAt,
                publishedAt: update.publishedAt,
                url: update.url,
                sourceID: sourceID,
                isHistorical: true
            )
            context.insert(stored)
        }
        return stored.id
    }

    func saveEvent(
        _ event: GameCalendarEvent,
        sourceUpdateID: String? = nil,
        clearSourceUpdateLink: Bool = false,
        save shouldSave: Bool = true
    ) throws {
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
        // A missing incoming link means "keep the existing link"; clearing is always explicit.
        item.sourceUpdateID = CalendarSourceUpdateLinkPolicy.resolvedValue(
            existing: item.sourceUpdateID,
            incoming: sourceUpdateID,
            clear: clearSourceUpdateLink
        )
        item.title = event.title
        item.date = event.date
        item.notes = event.notes
        if shouldSave { try database.save() }
    }

    func deleteEvent(id: String) throws {
        let descriptor = FetchDescriptor<DBCalendarEvent>(predicate: #Predicate { $0.id == id })
        if let item = try context.fetch(descriptor).first {
            context.delete(item)
            try database.save()
        }
    }

    func save() throws {
        try database.save()
    }

    enum RepositoryError: Error {
        case missingHistoricalSourceID
    }
}
