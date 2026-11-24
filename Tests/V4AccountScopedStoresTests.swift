import XCTest
import SwiftData
@testable import itchPocket

final class V4AccountScopedStoresTests: XCTestCase {
    @MainActor
    private func makeDependencies() throws -> (URL, V4AppDependencies, ItchAccountSession) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-account-stores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(in: directory, session: session)
        dependencies.modelContext.insert(DBGame(id: "shared-game", title: "Shared Game"))
        try dependencies.modelContext.save()
        return (directory, dependencies, session)
    }

    @MainActor
    private func activate(_ userID: Int, session: ItchAccountSession, dependencies: V4AppDependencies) throws {
        session.activate(ItchAccountIdentity(itchUserID: userID, username: "user-\(userID)"))
        let request = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(request)
    }

    @MainActor
    func testCalendarStoreKeepsPersonalEventsAndOverlaysIsolatedAcrossAccounts() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4CalendarStore(dependencies: dependencies)
        try activate(7101, session: session, dependencies: dependencies)

        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let source = StoredCalendarSourceEvent(
            sourceFingerprint: "devlog:shared", gameID: "shared-game",
            title: "Shared update", date: now, kind: "update"
        )
        try store.upsertSourceEvent(source)
        try store.upsertOverlay(StoredAccountCalendarOverlay(
            sourceEventID: source.id, reminderEnabled: true, reminderMinutes: 20,
            notes: "A overlay", updatedAt: now
        ))
        try store.upsertPersonalEvent(StoredAccountCalendarEvent(
            eventKey: "private-plan", gameID: "shared-game", title: "A private plan",
            date: now, kind: "planned", reminderEnabled: true, reminderMinutes: 30,
            notes: "A private note", createdAt: now, updatedAt: now
        ))
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first(where: { $0.origin == .sharedSource })?.notes, "A overlay")

        try activate(7102, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertEqual(store.events.count, 1)
        XCTAssertNil(store.events.first?.notes)
        XCTAssertFalse(try XCTUnwrap(store.events.first).reminderEnabled)

        try store.upsertOverlay(StoredAccountCalendarOverlay(
            sourceEventID: source.id, reminderEnabled: false, reminderMinutes: 90,
            notes: "B overlay", updatedAt: now.addingTimeInterval(1)
        ))
        try store.upsertPersonalEvent(StoredAccountCalendarEvent(
            eventKey: "private-plan", gameID: "shared-game", title: "B private plan",
            date: now, kind: "planned", reminderEnabled: false, reminderMinutes: 60,
            notes: "B private note", createdAt: now, updatedAt: now
        ))
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first(where: { $0.origin == .sharedSource })?.notes, "B overlay")

        try activate(7101, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertEqual(store.events.count, 2)
        XCTAssertEqual(store.events.first(where: { $0.origin == .sharedSource })?.notes, "A overlay")
        XCTAssertEqual(store.events.first(where: { $0.origin == .accountPersonal })?.notes, "A private note")

        try activate(7102, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertEqual(store.events.first(where: { $0.origin == .sharedSource })?.notes, "B overlay")
        XCTAssertEqual(store.events.first(where: { $0.origin == .accountPersonal })?.notes, "B private note")
    }

    @MainActor
    func testUpdateWatchStoreKeepsPreferencesAndValidatorsIsolatedAcrossAccounts() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4UpdateWatchStore(dependencies: dependencies)

        try activate(7201, session: session, dependencies: dependencies)
        try store.upsert(StoredAccountUpdateWatch(
            gameID: "shared-game", entityTag: "A-etag", lastModified: "A-date",
            contentHash: "A-hash", lastCheckedAt: Date(timeIntervalSince1970: 100),
            hasBaseline: true, isEnabled: true
        ))
        XCTAssertEqual(try XCTUnwrap(store.watches.first).entityTag, "A-etag")

        try activate(7202, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertTrue(store.watches.isEmpty)
        try store.upsert(StoredAccountUpdateWatch(
            gameID: "shared-game", entityTag: "B-etag", lastModified: "B-date",
            contentHash: "B-hash", lastCheckedAt: Date(timeIntervalSince1970: 200),
            hasBaseline: false, isEnabled: false
        ))
        XCTAssertEqual(try XCTUnwrap(store.watches.first).entityTag, "B-etag")

        try activate(7201, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertEqual(try XCTUnwrap(store.watches.first).entityTag, "A-etag")
        XCTAssertTrue(try XCTUnwrap(store.watches.first).isEnabled)

        try activate(7202, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertEqual(try XCTUnwrap(store.watches.first).entityTag, "B-etag")
        XCTAssertFalse(try XCTUnwrap(store.watches.first).isEnabled)
    }

    @MainActor
    func testCalendarAndUpdateWatchStoresRejectSignedOutAccess() throws {
        let (directory, dependencies, _) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = V4CalendarStore(dependencies: dependencies)
        let watches = V4UpdateWatchStore(dependencies: dependencies)

        XCTAssertThrowsError(try calendar.reload())
        XCTAssertThrowsError(try watches.reload())
        XCTAssertTrue(calendar.events.isEmpty)
        XCTAssertTrue(watches.watches.isEmpty)
    }

    @MainActor
    func testPersonalLibraryStoreKeepsSameGameEntriesIsolatedAcrossAccounts() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4PersonalLibraryStore(dependencies: dependencies)
        let firstDate = Date(timeIntervalSince1970: 1_800_000_300)

        try activate(7301, session: session, dependencies: dependencies)
        try store.upsert(StoredAccountLibraryEntry(
            gameID: "shared-game", status: "playing", isFavorite: true,
            notes: "A private note", addedAt: firstDate, updatedAt: firstDate
        ))
        XCTAssertEqual(try XCTUnwrap(store.entries.first).status, "playing")
        XCTAssertEqual(try XCTUnwrap(store.entries.first).notes, "A private note")

        try activate(7302, session: session, dependencies: dependencies)
        try store.reload()
        XCTAssertTrue(store.entries.isEmpty)
        try store.upsert(StoredAccountLibraryEntry(
            gameID: "shared-game", status: "completed", isFavorite: false,
            notes: "B private note", addedAt: firstDate, updatedAt: firstDate
        ))
        XCTAssertEqual(try XCTUnwrap(store.entries.first).status, "completed")

        try activate(7301, session: session, dependencies: dependencies)
        try store.reload()
        let firstAccountEntry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(firstAccountEntry.status, "playing")
        XCTAssertTrue(firstAccountEntry.isFavorite)
        XCTAssertEqual(firstAccountEntry.notes, "A private note")

        try activate(7302, session: session, dependencies: dependencies)
        try store.reload()
        let secondAccountEntry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(secondAccountEntry.status, "completed")
        XCTAssertFalse(secondAccountEntry.isFavorite)
        XCTAssertEqual(secondAccountEntry.notes, "B private note")
    }

    @MainActor
    func testPersonalLibraryStoreRejectsSignedOutAndMissingCatalogGame() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4PersonalLibraryStore(dependencies: dependencies)

        XCTAssertThrowsError(try store.reload())
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertThrowsError(try store.upsert(StoredAccountLibraryEntry(
            gameID: "not-in-shared-catalog", status: "playing", isFavorite: false,
            notes: "", addedAt: .now, updatedAt: .now
        )))

        try activate(7303, session: session, dependencies: dependencies)
        XCTAssertThrowsError(try store.upsert(StoredAccountLibraryEntry(
            gameID: "not-in-shared-catalog", status: "playing", isFavorite: false,
            notes: "", addedAt: .now, updatedAt: .now
        )))
        XCTAssertTrue(store.entries.isEmpty)
    }
    @MainActor
    func testPersonalLibraryStoreKeepsCollectionsAndStatusHistoryIsolatedAcrossAccounts() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4PersonalLibraryStore(dependencies: dependencies)

        try activate(7401, session: session, dependencies: dependencies)
        try store.upsertCollection(collectionKey: "favorites", title: "A Favorites")
        try store.addGameToCollection(collectionKey: "favorites", gameID: "shared-game", sortOrder: 3)
        try store.recordStatusEvent(
            eventKey: "a-status-1", gameID: "shared-game",
            fromStatus: nil, toStatus: "playing"
        )
        XCTAssertEqual(try XCTUnwrap(store.collections.first).title, "A Favorites")
        XCTAssertEqual(try XCTUnwrap(store.collectionItems.first).sortOrder, 3)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).toStatus, "playing")

        try activate(7402, session: session, dependencies: dependencies)
        try store.reloadCollections()
        try store.reloadCollectionItems(collectionKey: "favorites")
        try store.reloadStatusEvents()
        XCTAssertTrue(store.collections.isEmpty)
        XCTAssertTrue(store.collectionItems.isEmpty)
        XCTAssertTrue(store.statusEvents.isEmpty)

        try store.upsertCollection(collectionKey: "favorites", title: "B Favorites")
        try store.addGameToCollection(collectionKey: "favorites", gameID: "shared-game", sortOrder: 8)
        try store.recordStatusEvent(
            eventKey: "b-status-1", gameID: "shared-game",
            fromStatus: nil, toStatus: "completed"
        )
        XCTAssertEqual(try XCTUnwrap(store.collections.first).title, "B Favorites")
        XCTAssertEqual(try XCTUnwrap(store.collectionItems.first).sortOrder, 8)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).toStatus, "completed")

        try activate(7401, session: session, dependencies: dependencies)
        try store.reloadCollections()
        try store.reloadCollectionItems(collectionKey: "favorites")
        try store.reloadStatusEvents()
        XCTAssertEqual(try XCTUnwrap(store.collections.first).title, "A Favorites")
        XCTAssertEqual(try XCTUnwrap(store.collectionItems.first).sortOrder, 3)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).eventKey, "a-status-1")

        try activate(7402, session: session, dependencies: dependencies)
        try store.reloadCollections()
        try store.reloadCollectionItems(collectionKey: "favorites")
        try store.reloadStatusEvents()
        XCTAssertEqual(try XCTUnwrap(store.collections.first).title, "B Favorites")
        XCTAssertEqual(try XCTUnwrap(store.collectionItems.first).sortOrder, 8)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).eventKey, "b-status-1")
    }


    @MainActor
    func testStatusChangeAndHistoryCommitAtomicallyAndRollbackTogether() throws {
        let (directory, dependencies, session) = try makeDependencies()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = V4PersonalLibraryStore(dependencies: dependencies)
        let now = Date(timeIntervalSince1970: 1_800_000_500)

        try activate(7501, session: session, dependencies: dependencies)
        try store.upsert(StoredAccountLibraryEntry(
            gameID: "shared-game", status: "playing", isFavorite: true,
            notes: "keep me", addedAt: now, updatedAt: now
        ))

        try store.changeStatus(
            gameID: "shared-game", toStatus: "completed",
            eventKey: "status-transition-1", at: now.addingTimeInterval(10)
        )
        XCTAssertEqual(try XCTUnwrap(store.entries.first).status, "completed")
        XCTAssertEqual(store.statusEvents.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).fromStatus, "playing")
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).toStatus, "completed")

        // An unrelated unsaved edit in the shared main context must survive
        // rollback of the isolated library transaction context.
        let sharedGame = try XCTUnwrap(dependencies.modelContext.fetch(
            FetchDescriptor<DBGame>(predicate: #Predicate { $0.id == "shared-game" })
        ).first)
        sharedGame.title = "Unrelated pending edit"

        XCTAssertThrowsError(try store.changeStatus(
            gameID: "shared-game", toStatus: "paused",
            eventKey: "status-transition-1", at: now.addingTimeInterval(20)
        ))

        try store.reload()
        try store.reloadStatusEvents()
        XCTAssertEqual(try XCTUnwrap(store.entries.first).status, "completed")
        XCTAssertEqual(store.statusEvents.count, 1)
        XCTAssertEqual(try XCTUnwrap(store.statusEvents.first).toStatus, "completed")
        XCTAssertEqual(try XCTUnwrap(store.entries.first).notes, "keep me")
        XCTAssertEqual(sharedGame.title, "Unrelated pending edit")
    }

}
