import Foundation
import SwiftData

struct StoredCalendarSourceEvent: Equatable {
    let sourceFingerprint: String
    let gameID: String
    let title: String?
    let date: Date?
    let kind: String
    let sourceUpdateID: String?
    let gameTitleSnapshot: String?

    var id: String { DBCalendarSourceEvent.stableID(sourceFingerprint: sourceFingerprint) }
}

struct StoredAccountCalendarEvent: Equatable {
    let eventKey: String
    let gameID: String
    let title: String?
    let date: Date?
    let kind: String
    let reminderEnabled: Bool
    let reminderMinutes: Int
    let notes: String?
    let createdAt: Date
    let updatedAt: Date
}

struct StoredAccountCalendarOverlay: Equatable {
    let sourceEventID: String
    let reminderEnabled: Bool
    let reminderMinutes: Int
    let notes: String?
    let updatedAt: Date
}

struct ResolvedCalendarV4Event: Equatable {
    enum Origin: Equatable { case sharedSource, accountPersonal }
    let id: String
    let gameID: String
    let title: String?
    let date: Date?
    let kind: String
    let reminderEnabled: Bool
    let reminderMinutes: Int
    let notes: String?
    let origin: Origin
}

/// V4-only calendar persistence. It requires an explicit itch account and a V4 ModelContext;
/// it is intentionally not wired to the V3 app startup or global GameCalendarStore.
@MainActor
final class AccountScopedCalendarRepository {
    enum RepositoryError: LocalizedError, Equatable {
        case invalidAccountID
        case emptyKey
        case missingGame(String)
        case missingSourceEvent(String)
        case sourceUpdateGameMismatch(eventGameID: String, updateID: String, updateGameID: String)
        case duplicateRecord(String)

        var errorDescription: String? {
            switch self {
            case .invalidAccountID: return "A canonical itch:<positive-user-id> account is required."
            case .emptyKey: return "Calendar identity keys must not be empty."
            case .missingGame(let id): return "Calendar game does not exist: \(id)."
            case .missingSourceEvent(let id): return "Shared calendar source event does not exist: \(id)."
            case .sourceUpdateGameMismatch(let gameID, let updateID, let updateGameID):
                return "Calendar source for \(gameID) cannot link update \(updateID) owned by \(updateGameID)."
            case .duplicateRecord(let key): return "Multiple calendar records match \(key)."
            }
        }
    }

    private let context: ModelContext
    let accountID: String

    init(context: ModelContext, accountID: String) throws {
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == accountID,
              normalized.hasPrefix("itch:"),
              let userID = Int(normalized.dropFirst(5)),
              userID > 0,
              normalized == "itch:\(userID)" else {
            throw RepositoryError.invalidAccountID
        }
        self.context = context
        self.accountID = normalized
    }

    func loadSourceEvents() throws -> [StoredCalendarSourceEvent] {
        try context.fetch(FetchDescriptor<DBCalendarSourceEvent>()).map {
            StoredCalendarSourceEvent(
                sourceFingerprint: $0.sourceFingerprint, gameID: $0.gameID, title: $0.title,
                date: $0.date, kind: $0.kind, sourceUpdateID: $0.sourceUpdateID,
                gameTitleSnapshot: $0.gameTitleSnapshot
            )
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func upsertSourceEvent(_ event: StoredCalendarSourceEvent, save: Bool = true) throws {
        guard !event.sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.emptyKey
        }
        try requireGame(event.gameID)
        try validateUpdate(event.sourceUpdateID, gameID: event.gameID)
        let id = event.id
        let descriptor = FetchDescriptor<DBCalendarSourceEvent>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        let row = rows.first ?? DBCalendarSourceEvent(
            sourceFingerprint: event.sourceFingerprint, gameID: event.gameID, kind: event.kind
        )
        if rows.isEmpty { context.insert(row) }
        row.sourceFingerprint = event.sourceFingerprint
        row.gameID = event.gameID
        row.title = event.title
        row.date = event.date
        row.kind = event.kind
        row.sourceUpdateID = event.sourceUpdateID
        row.gameTitleSnapshot = event.gameTitleSnapshot
        row.updatedAt = .now
        if save { try context.save() }
    }

    func loadPersonalEvents() throws -> [StoredAccountCalendarEvent] {
        let scope = accountID
        let descriptor = FetchDescriptor<DBAccountCalendarEvent>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountCalendarEvent(
                eventKey: $0.eventKey, gameID: $0.gameID, title: $0.title, date: $0.date,
                kind: $0.kind, reminderEnabled: $0.reminderEnabled,
                reminderMinutes: $0.reminderMinutes, notes: $0.notes,
                createdAt: $0.createdAt, updatedAt: $0.updatedAt
            )
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    func upsertPersonalEvent(_ event: StoredAccountCalendarEvent, save: Bool = true) throws {
        guard !event.eventKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.emptyKey
        }
        try requireGame(event.gameID)
        let id = DBAccountCalendarEvent.stableID(accountID: accountID, eventKey: event.eventKey)
        let descriptor = FetchDescriptor<DBAccountCalendarEvent>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        let row = rows.first ?? DBAccountCalendarEvent(
            accountID: accountID, eventKey: event.eventKey, gameID: event.gameID, kind: event.kind
        )
        if rows.isEmpty { context.insert(row) }
        row.gameID = event.gameID
        row.title = event.title
        row.date = event.date
        row.kind = event.kind
        row.reminderEnabled = event.reminderEnabled
        row.reminderMinutes = event.reminderMinutes
        row.notes = event.notes
        row.createdAt = event.createdAt
        row.updatedAt = event.updatedAt
        if save { try context.save() }
    }

    func deletePersonalEvent(eventKey: String, save: Bool = true) throws {
        let id = DBAccountCalendarEvent.stableID(accountID: accountID, eventKey: eventKey)
        let descriptor = FetchDescriptor<DBAccountCalendarEvent>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        rows.forEach(context.delete)
        if save, !rows.isEmpty { try context.save() }
    }

    func loadOverlays() throws -> [StoredAccountCalendarOverlay] {
        let scope = accountID
        let descriptor = FetchDescriptor<DBAccountCalendarOverlay>(
            predicate: #Predicate { $0.accountID == scope }
        )
        return try context.fetch(descriptor).map {
            StoredAccountCalendarOverlay(
                sourceEventID: $0.sourceEventID, reminderEnabled: $0.reminderEnabled,
                reminderMinutes: $0.reminderMinutes, notes: $0.notes, updatedAt: $0.updatedAt
            )
        }
    }

    func upsertOverlay(_ overlay: StoredAccountCalendarOverlay, save: Bool = true) throws {
        let sourceID = overlay.sourceEventID
        guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RepositoryError.emptyKey
        }
        let sourceDescriptor = FetchDescriptor<DBCalendarSourceEvent>(
            predicate: #Predicate { $0.id == sourceID }
        )
        guard try context.fetch(sourceDescriptor).first != nil else {
            throw RepositoryError.missingSourceEvent(sourceID)
        }
        let id = DBAccountCalendarOverlay.stableID(accountID: accountID, sourceEventID: sourceID)
        let descriptor = FetchDescriptor<DBAccountCalendarOverlay>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        let row = rows.first ?? DBAccountCalendarOverlay(
            accountID: accountID, sourceEventID: sourceID
        )
        if rows.isEmpty { context.insert(row) }
        row.reminderEnabled = overlay.reminderEnabled
        row.reminderMinutes = overlay.reminderMinutes
        row.notes = overlay.notes
        row.updatedAt = overlay.updatedAt
        if save { try context.save() }
    }

    func deleteOverlay(sourceEventID: String, save: Bool = true) throws {
        let id = DBAccountCalendarOverlay.stableID(accountID: accountID, sourceEventID: sourceEventID)
        let descriptor = FetchDescriptor<DBAccountCalendarOverlay>(predicate: #Predicate { $0.id == id })
        let rows = try context.fetch(descriptor)
        guard rows.count <= 1 else { throw RepositoryError.duplicateRecord(id) }
        rows.forEach(context.delete)
        if save, !rows.isEmpty { try context.save() }
    }

    /// Builds the active account's notification/UI projection. Shared source fields are combined
    /// with only this account's overlay; personal events are included only for this account.
    func resolvedEvents() throws -> [ResolvedCalendarV4Event] {
        let sources = try context.fetch(FetchDescriptor<DBCalendarSourceEvent>())
        let overlays = try loadOverlays()
        let overlayBySource = Dictionary(uniqueKeysWithValues: overlays.map { ($0.sourceEventID, $0) })
        let shared = sources.map { source -> ResolvedCalendarV4Event in
            let overlay = overlayBySource[source.id]
            return ResolvedCalendarV4Event(
                id: source.id, gameID: source.gameID, title: source.title, date: source.date,
                kind: source.kind, reminderEnabled: overlay?.reminderEnabled ?? false,
                reminderMinutes: overlay?.reminderMinutes ?? 60, notes: overlay?.notes,
                origin: .sharedSource
            )
        }
        let personal = try loadPersonalEvents().map { event in
            ResolvedCalendarV4Event(
                id: DBAccountCalendarEvent.stableID(accountID: accountID, eventKey: event.eventKey),
                gameID: event.gameID, title: event.title, date: event.date, kind: event.kind,
                reminderEnabled: event.reminderEnabled, reminderMinutes: event.reminderMinutes,
                notes: event.notes, origin: .accountPersonal
            )
        }
        return (shared + personal).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    /// Copies all V3 rows byte-for-field into an unassigned quarantine table.
    /// It never assigns ownership, deletes source rows, or changes V3 data.
    @discardableResult
    func quarantineLegacyRows(save: Bool = true) throws -> Int {
        let legacyRows = try context.fetch(FetchDescriptor<DBCalendarEvent>())
        let existing = Set(try context.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).map(\.originalEventID))
        var copied = 0
        for row in legacyRows where !existing.contains(row.id) {
            let issue: String?
            if try !gameExists(row.gameID) {
                issue = "missing-game"
            } else if let updateID = row.sourceUpdateID {
                if let update = try fetchUpdate(updateID) {
                    issue = update.gameID == row.gameID ? nil : "cross-game-source-update"
                } else {
                    issue = "missing-source-update"
                }
            } else {
                issue = nil
            }
            context.insert(DBLegacyCalendarEvent(copying: row, integrityIssue: issue))
            copied += 1
        }
        if save, copied > 0 { try context.save() }
        return copied
    }

    private func requireGame(_ gameID: String) throws {
        guard try gameExists(gameID) else { throw RepositoryError.missingGame(gameID) }
    }

    private func gameExists(_ gameID: String) throws -> Bool {
        let descriptor = FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == gameID })
        return try context.fetch(descriptor).first != nil
    }

    private func fetchUpdate(_ updateID: String) throws -> DBGameUpdate? {
        let descriptor = FetchDescriptor<DBGameUpdate>(predicate: #Predicate { $0.id == updateID })
        return try context.fetch(descriptor).first
    }

    private func validateUpdate(_ updateID: String?, gameID: String) throws {
        guard let updateID, let update = try fetchUpdate(updateID), update.gameID != gameID else { return }
        throw RepositoryError.sourceUpdateGameMismatch(
            eventGameID: gameID, updateID: updateID, updateGameID: update.gameID
        )
    }
}
