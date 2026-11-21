import XCTest
import SwiftData
@testable import itchPocket

final class AccountScopedCalendarRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-calendar-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        for userID in [1, 9, 11, 22, 101, 202] {
            container.mainContext.insert(DBAccount(itchUserID: userID, username: "test-\\(userID)"))
        }
        try container.mainContext.save()
        return container
    }

    @MainActor
    func testSharedSourceEventIsVisibleToBothAccountsButOverlaysArePrivate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Shared Game"))
        try context.save()
        let a = try AccountScopedCalendarRepository(context: context, accountID: "itch:101")
        let b = try AccountScopedCalendarRepository(context: context, accountID: "itch:202")
        let source = StoredCalendarSourceEvent(
            sourceFingerprint: "devlog:42", gameID: "game", title: "Update",
            date: Date(timeIntervalSince1970: 1_700_000_000), kind: "update"
        )
        try a.upsertSourceEvent(source)
        try a.upsertOverlay(StoredAccountCalendarOverlay(
            sourceEventID: source.id, reminderEnabled: true, reminderMinutes: 15, notes: "A private note",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        ))
        try b.upsertOverlay(StoredAccountCalendarOverlay(
            sourceEventID: source.id, reminderEnabled: false, reminderMinutes: 90, notes: "B private note",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_200)
        ))

        let resolvedA = try XCTUnwrap(a.resolvedEvents().first)
        let resolvedB = try XCTUnwrap(b.resolvedEvents().first)
        XCTAssertEqual(resolvedA.id, resolvedB.id)
        XCTAssertTrue(resolvedA.reminderEnabled)
        XCTAssertEqual(resolvedA.reminderMinutes, 15)
        XCTAssertEqual(resolvedA.notes, "A private note")
        XCTAssertFalse(resolvedB.reminderEnabled)
        XCTAssertEqual(resolvedB.reminderMinutes, 90)
        XCTAssertEqual(resolvedB.notes, "B private note")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarSourceEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountCalendarOverlay>()), 2)
    }

    @MainActor
    func testPersonalEventsNeverCrossAccountBoundary() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()
        let a = try AccountScopedCalendarRepository(context: context, accountID: "itch:11")
        let b = try AccountScopedCalendarRepository(context: context, accountID: "itch:22")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try a.upsertPersonalEvent(StoredAccountCalendarEvent(
            eventKey: "plan", gameID: "game", title: "A plan", date: now, kind: "planned",
            reminderEnabled: true, reminderMinutes: 30, notes: "private", createdAt: now, updatedAt: now
        ))

        XCTAssertEqual(try a.loadPersonalEvents().map(\.title), ["A plan"])
        XCTAssertTrue(try b.loadPersonalEvents().isEmpty)
        XCTAssertEqual(try b.resolvedEvents().count, 0)
        try b.deletePersonalEvent(eventKey: "plan")
        XCTAssertEqual(try a.loadPersonalEvents().map(\.notes), ["private"])
    }

    @MainActor
    func testRepositoryRejectsNonCanonicalOrMissingAccountIdentity() throws {
        let container = try makeContainer()
        for invalid in ["", "  itch:1", "itch:0", "itch:01", "itch:-1", "patreon:1"] {
            XCTAssertThrowsError(try AccountScopedCalendarRepository(context: container.mainContext, accountID: invalid))
        }
    }

    @MainActor
    func testWritesRejectMissingGameBeforeMutatingContext() throws {
        let container = try makeContainer()
        let repository = try AccountScopedCalendarRepository(context: container.mainContext, accountID: "itch:1")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try repository.upsertPersonalEvent(StoredAccountCalendarEvent(
            eventKey: "orphan", gameID: "missing", title: nil, date: now, kind: "custom",
            reminderEnabled: false, reminderMinutes: 60, notes: nil, createdAt: now, updatedAt: now
        )))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBAccountCalendarEvent>()), 0)
    }

    @MainActor
    func testSourceEventRejectsCrossGameUpdateLinkBeforeMutation() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game-a", title: "A"))
        context.insert(DBGame(id: "game-b", title: "B"))
        context.insert(DBGameUpdate(id: "update-b", gameID: "game-b", summary: ""))
        try context.save()
        let repository = try AccountScopedCalendarRepository(context: context, accountID: "itch:1")
        XCTAssertThrowsError(try repository.upsertSourceEvent(StoredCalendarSourceEvent(
            sourceFingerprint: "devlog:1", gameID: "game-a", title: "Bad link",
            date: nil, kind: "update", sourceUpdateID: "update-b"
        )))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarSourceEvent>()), 0)
    }

    @MainActor
    func testOverlayRequiresExistingSharedSourceEvent() throws {
        let container = try makeContainer()
        let repository = try AccountScopedCalendarRepository(context: container.mainContext, accountID: "itch:1")
        XCTAssertThrowsError(try repository.upsertOverlay(StoredAccountCalendarOverlay(
            sourceEventID: "missing", reminderEnabled: true, reminderMinutes: 5, notes: "x", updatedAt: .now
        )))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBAccountCalendarOverlay>()), 0)
    }

    @MainActor
    func testLegacyRowsAreCopiedLosslesslyAndRemainUnassignedAndIdempotent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(DBGame(id: "game", title: "Game"))
        context.insert(DBCalendarEvent(
            id: "legacy-event", gameID: "game", title: "Personal title", date: date,
            kind: "计划游玩", reminderEnabled: true, reminderMinutes: 17, notes: "Do not leak",
            sourceFingerprint: nil, sourceUpdateID: nil, gameTitleSnapshot: "Old title"
        ))
        try context.save()
        let a = try AccountScopedCalendarRepository(context: context, accountID: "itch:101")

        XCTAssertEqual(try a.quarantineLegacyRows(), 1)
        XCTAssertEqual(try a.quarantineLegacyRows(), 0)
        let preserved = try XCTUnwrap(context.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).first)
        XCTAssertEqual(preserved.originalEventID, "legacy-event")
        XCTAssertEqual(preserved.gameID, "game")
        XCTAssertEqual(preserved.title, "Personal title")
        XCTAssertEqual(preserved.date, date)
        XCTAssertEqual(preserved.reminderMinutes, 17)
        XCTAssertEqual(preserved.notes, "Do not leak")
        XCTAssertNil(preserved.sourceFingerprint)
        XCTAssertNil(preserved.integrityIssue)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBCalendarEvent>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountCalendarEvent>()), 0)
    }

    @MainActor
    func testLegacyBrokenReferencesArePreservedWithIntegrityIssue() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBCalendarEvent(
            id: "broken", gameID: "missing-game", title: "Keep me", kind: "update",
            sourceUpdateID: "missing-update"
        ))
        try context.save()
        let repository = try AccountScopedCalendarRepository(context: context, accountID: "itch:9")
        XCTAssertEqual(try repository.quarantineLegacyRows(), 1)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).first)
        XCTAssertEqual(row.integrityIssue, "missing-game")
        XCTAssertEqual(row.gameID, "missing-game")
        XCTAssertEqual(row.sourceUpdateID, "missing-update")
    }
    @MainActor
    func testLegacyMissingSourceUpdateLinkIsPreservedAndDiagnosed() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Game"))
        context.insert(DBCalendarEvent(
            id: "missing-update-row", gameID: "game", title: "Keep snapshot", kind: "update",
            sourceFingerprint: "devlog:missing", sourceUpdateID: "deleted-update"
        ))
        try context.save()
        let repository = try AccountScopedCalendarRepository(context: context, accountID: "itch:9")
        XCTAssertEqual(try repository.quarantineLegacyRows(), 1)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<DBLegacyCalendarEvent>()).first)
        XCTAssertEqual(row.integrityIssue, "missing-source-update")
        XCTAssertEqual(row.sourceFingerprint, "devlog:missing")
        XCTAssertEqual(row.sourceUpdateID, "deleted-update")
    }


    @MainActor
    func testRetainedRepositoryCannotRecreatePersonalRowsAfterAccountRemoval() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()
        let repository = try AccountScopedCalendarRepository(context: context, accountID: "itch:101")
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<DBAccount>()).first { $0.id == "itch:101" })
        context.delete(account)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try repository.upsertPersonalEvent(StoredAccountCalendarEvent(
            eventKey: "late", gameID: "game", title: "Late write", date: now, kind: "custom",
            reminderEnabled: false, reminderMinutes: 60, notes: nil, createdAt: now, updatedAt: now
        )))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountCalendarEvent>()), 0)
    }

}
