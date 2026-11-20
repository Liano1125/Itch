import XCTest
import SwiftData
@testable import itchPocket

final class V4CalendarEventMigrationTests: XCTestCase {
    @MainActor
    private func makeV4Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration("v4-calendar-migration-\(UUID().uuidString)", schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testCalendarRowsAreCopiedLosslesslyToUnassignedQuarantine() throws {
        let source = try AppDatabase(inMemory: true)
        let date = Date(timeIntervalSince1970: 12345)
        source.context.insert(DBGame(id: "calendar-game", title: "Game"))
        source.context.insert(DBGameUpdate(id: "calendar-update", gameID: "calendar-game", summary: "update"))
        source.context.insert(DBCalendarEvent(
            id: "source-event", gameID: "calendar-game", title: "Private title", date: date,
            kind: "custom", reminderEnabled: true, reminderMinutes: 37, notes: "Private note",
            sourceFingerprint: "fingerprint", sourceUpdateID: "calendar-update",
            gameTitleSnapshot: "Snapshot"
        ))
        source.context.insert(DBCalendarEvent(
            id: "orphan-event", gameID: "calendar-game", title: "Orphan", kind: "release",
            reminderEnabled: false, reminderMinutes: 0, notes: "Keep me", sourceUpdateID: "missing-update"
        ))
        try source.save()

        let destination = try makeV4Container()
        let report = try V4CalendarEventConverter.convert(source: source.context, destination: destination.mainContext)
        let verification = try V4CalendarEventVerifier.verify(source: source.context, destination: destination.mainContext)
        let rows = try destination.mainContext.fetch(FetchDescriptor<DBLegacyCalendarEvent>())

        XCTAssertEqual(rows.count, 2)
        let copied = try XCTUnwrap(rows.first { $0.originalEventID == "source-event" })
        XCTAssertEqual(copied.gameID, "calendar-game")
        XCTAssertEqual(copied.title, "Private title")
        XCTAssertEqual(copied.date, date)
        XCTAssertEqual(copied.kind, "custom")
        XCTAssertTrue(copied.reminderEnabled)
        XCTAssertEqual(copied.reminderMinutes, 37)
        XCTAssertEqual(copied.notes, "Private note")
        XCTAssertEqual(copied.sourceFingerprint, "fingerprint")
        XCTAssertEqual(copied.sourceUpdateID, "calendar-update")
        XCTAssertEqual(copied.gameTitleSnapshot, "Snapshot")
        XCTAssertNil(copied.integrityIssue)

        let orphan = try XCTUnwrap(rows.first { $0.originalEventID == "orphan-event" })
        XCTAssertEqual(orphan.integrityIssue, "missing-update")
        XCTAssertEqual(report.rowCount, 2)
        XCTAssertEqual(report.quarantinedRowCount, 2)
        XCTAssertEqual(report.integrityIssueCount, 1)
        XCTAssertTrue(verification.isVerified, "\(verification.diagnostics)")
        XCTAssertEqual(verification.verifiedRows, 2)
        XCTAssertEqual(verification.integrityIssueCount, 1)
        XCTAssertEqual(try source.context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 2)
    }

    @MainActor
    func testCalendarVerifierRejectsMutationOfPrivatePayload() throws {
        let source = try AppDatabase(inMemory: true)
        source.context.insert(DBGame(id: "calendar-game", title: "Game"))
        source.context.insert(DBCalendarEvent(id: "event", gameID: "calendar-game", kind: "custom", notes: "original"))
        try source.save()
        let destination = try makeV4Container()
        _ = try V4CalendarEventConverter.convert(source: source.context, destination: destination.mainContext)
        let row = try XCTUnwrap(destination.mainContext.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).first)
        row.notes = "mutated"
        try destination.mainContext.save()

        let report = try V4CalendarEventVerifier.verify(source: source.context, destination: destination.mainContext)
        XCTAssertFalse(report.isVerified)
        XCTAssertTrue(report.diagnostics.contains("migration.calendarEvents.rowMismatch"))
    }
}
