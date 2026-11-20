import CryptoKit
import Foundation
import SwiftData

struct V4CalendarEventMigrationReport: Equatable {
    let rowCount: Int
    let quarantinedRowCount: Int
    let integrityIssueCount: Int
    let inventoryDigest: String
}

struct V4CalendarEventVerificationReport: Equatable {
    let verifiedRows: Int
    let unverifiedRows: Int
    let quarantinedRowCount: Int
    let integrityIssueCount: Int
    let diagnostics: [String]
    var isVerified: Bool { unverifiedRows == 0 && diagnostics.isEmpty }
}

/// V3 calendar rows have no durable account owner. Preserve every field in the
/// unassigned legacy area; never infer an owner or publish personal notes/reminders.
@MainActor
enum V4CalendarEventConverter {
    enum ConversionError: LocalizedError, Equatable {
        case sourceHasPendingChanges
        case destinationHasPendingChanges
        case destinationNotEmpty
        case duplicateSourceIdentity

        var errorDescription: String? {
            switch self {
            case .sourceHasPendingChanges: return "The V3 source context must be clean before calendar migration."
            case .destinationHasPendingChanges: return "The V4 staging context must be clean before calendar migration."
            case .destinationNotEmpty: return "The V4 legacy calendar table must be empty before conversion."
            case .duplicateSourceIdentity: return "The V3 calendar source contains duplicate identities."
            }
        }
    }

    private static func issue(for row: DBCalendarEvent, games: Set<String>, updates: [String: DBGameUpdate]) -> String? {
        guard games.contains(row.gameID) else { return "missing-game" }
        guard let updateID = row.sourceUpdateID else { return nil }
        guard let update = updates[updateID] else { return "missing-update" }
        guard update.gameID == row.gameID else { return "cross-game-update" }
        return nil
    }

    static func convert(source: ModelContext, destination: ModelContext) throws -> V4CalendarEventMigrationReport {
        guard !source.hasChanges else { throw ConversionError.sourceHasPendingChanges }
        guard !destination.hasChanges else { throw ConversionError.destinationHasPendingChanges }

        let rows = try source.fetch(FetchDescriptor<DBCalendarEvent>())
        let games = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\.id))
        let updates = Dictionary(uniqueKeysWithValues: try source.fetch(FetchDescriptor<DBGameUpdate>()).map { ($0.id, $0) })
        guard try destination.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).isEmpty else {
            throw ConversionError.destinationNotEmpty
        }
        let sorted = rows.sorted { $0.id < $1.id }
        guard Set(sorted.map(\.id)).count == sorted.count else { throw ConversionError.duplicateSourceIdentity }

        let digestInput = sorted.map { "legacy-calendar:\($0.id)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(digestInput.utf8)).map { String(format: "%02x", $0) }.joined()
        do {
            for row in sorted {
                destination.insert(DBLegacyCalendarEvent(
                    copying: row,
                    integrityIssue: issue(for: row, games: games, updates: updates)
                ))
            }
            try destination.save()
        } catch {
            destination.rollback()
            throw error
        }
        return V4CalendarEventMigrationReport(
            rowCount: sorted.count,
            quarantinedRowCount: sorted.count,
            integrityIssueCount: sorted.filter { issue(for: $0, games: games, updates: updates) != nil }.count,
            inventoryDigest: digest
        )
    }
}

@MainActor
enum V4CalendarEventVerifier {
    private struct Value: Equatable {
        let originalEventID: String
        let gameID: String
        let title: String?
        let date: Date?
        let kind: String
        let reminderEnabled: Bool
        let reminderMinutes: Int
        let notes: String?
        let sourceFingerprint: String?
        let sourceUpdateID: String?
        let gameTitleSnapshot: String?
        let integrityIssue: String?

        init(_ row: DBCalendarEvent, games: Set<String>, updates: [String: DBGameUpdate]) {
            originalEventID = row.id
            gameID = row.gameID
            title = row.title
            date = row.date
            kind = row.kind
            reminderEnabled = row.reminderEnabled
            reminderMinutes = row.reminderMinutes
            notes = row.notes
            sourceFingerprint = row.sourceFingerprint
            sourceUpdateID = row.sourceUpdateID
            gameTitleSnapshot = row.gameTitleSnapshot
            if !games.contains(row.gameID) { integrityIssue = "missing-game" }
            else if let updateID = row.sourceUpdateID, let update = updates[updateID], update.gameID != row.gameID {
                integrityIssue = "cross-game-update"
            } else if let updateID = row.sourceUpdateID, updates[updateID] == nil {
                integrityIssue = "missing-update"
            } else { integrityIssue = nil }
        }

        init(_ row: DBLegacyCalendarEvent) {
            originalEventID = row.originalEventID
            gameID = row.gameID
            title = row.title
            date = row.date
            kind = row.kind
            reminderEnabled = row.reminderEnabled
            reminderMinutes = row.reminderMinutes
            notes = row.notes
            sourceFingerprint = row.sourceFingerprint
            sourceUpdateID = row.sourceUpdateID
            gameTitleSnapshot = row.gameTitleSnapshot
            integrityIssue = row.integrityIssue
        }
    }

    static func verify(source: ModelContext, destination: ModelContext) throws -> V4CalendarEventVerificationReport {
        guard !source.hasChanges, !destination.hasChanges else {
            return V4CalendarEventVerificationReport(verifiedRows: 0, unverifiedRows: 1,
                quarantinedRowCount: 0, integrityIssueCount: 0,
                diagnostics: ["migration.calendarEvents.pendingContextChanges"])
        }
        let games = Set(try source.fetch(FetchDescriptor<DBGame>()).map(\.id))
        let updates = Dictionary(uniqueKeysWithValues: try source.fetch(FetchDescriptor<DBGameUpdate>()).map { ($0.id, $0) })
        let lhs = Dictionary(grouping: try source.fetch(FetchDescriptor<DBCalendarEvent>()).map { Value($0, games: games, updates: updates) }, by: \.originalEventID)
        let destinationRows = try destination.fetch(FetchDescriptor<DBLegacyCalendarEvent>())
        let rhs = Dictionary(grouping: destinationRows.map(Value.init), by: \.originalEventID)
        var verified = 0
        var unverified = 0
        var issues = 0
        var diagnostics = Set<String>()
        for key in Set(lhs.keys).union(rhs.keys) {
            let a = lhs[key] ?? []
            let b = rhs[key] ?? []
            if a.count == 1, b.count == 1, a[0] == b[0],
               destinationRows.first(where: { $0.originalEventID == key })?.id == DBLegacyCalendarEvent.stableID(originalEventID: key) {
                verified += 1
                if b[0].integrityIssue != nil { issues += 1 }
            } else {
                unverified += a.count + b.count
                diagnostics.insert("migration.calendarEvents.rowMismatch")
            }
        }
        return V4CalendarEventVerificationReport(verifiedRows: verified, unverifiedRows: unverified,
            quarantinedRowCount: destinationRows.count, integrityIssueCount: issues,
            diagnostics: diagnostics.sorted())
    }
}
