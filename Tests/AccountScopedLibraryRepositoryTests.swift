import XCTest
import SwiftData
@testable import itchPocket

final class AccountScopedLibraryRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-library-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testRetainedRepositoryCannotRecreateLibraryEntryAfterAccountRemoval() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 101, username: "test"))
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()

        let repository = try AccountScopedLibraryRepository(context: context, accountID: "itch:101")
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<DBAccount>()).first)
        context.delete(account)
        try context.save()

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try repository.upsertEntry(StoredAccountLibraryEntry(
            gameID: "game", status: "playing", isFavorite: false, notes: "",
            addedAt: now, updatedAt: now
        )))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()), 0)
    }

    @MainActor
    func testCollectionsMembershipAndStatusHistoryAreIsolatedAcrossAccounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 101, username: "account-a"))
        context.insert(DBAccount(itchUserID: 202, username: "account-b"))
        context.insert(DBGame(id: "shared-game", title: "Shared Game"))
        try context.save()

        let accountA = try AccountScopedLibraryRepository(context: context, accountID: "itch:101")
        let accountB = try AccountScopedLibraryRepository(context: context, accountID: "itch:202")

        try accountA.upsertCollection(collectionKey: "favorites", title: "A Favorites")
        try accountB.upsertCollection(collectionKey: "favorites", title: "B Favorites")
        try accountA.addGameToCollection(
            collectionKey: "favorites", gameID: "shared-game", sortOrder: 1
        )
        try accountB.addGameToCollection(
            collectionKey: "favorites", gameID: "shared-game", sortOrder: 9
        )
        try accountA.recordStatusEvent(
            eventKey: "status-1", gameID: "shared-game",
            fromStatus: nil, toStatus: "playing"
        )
        try accountB.recordStatusEvent(
            eventKey: "status-1", gameID: "shared-game",
            fromStatus: nil, toStatus: "completed"
        )

        XCTAssertEqual(try accountA.loadCollections(), [
            StoredAccountLibraryCollection(collectionKey: "favorites", title: "A Favorites")
        ])
        XCTAssertEqual(try accountB.loadCollections(), [
            StoredAccountLibraryCollection(collectionKey: "favorites", title: "B Favorites")
        ])
        XCTAssertEqual(try accountA.loadCollectionItems(collectionKey: "favorites").map(\\.sortOrder), [1])
        XCTAssertEqual(try accountB.loadCollectionItems(collectionKey: "favorites").map(\\.sortOrder), [9])
        XCTAssertEqual(try accountA.loadStatusEvents().map(\\.toStatus), ["playing"])
        XCTAssertEqual(try accountB.loadStatusEvents().map(\\.toStatus), ["completed"])

        try accountA.removeCollection(collectionKey: "favorites")
        XCTAssertTrue(try accountA.loadCollections().isEmpty)
        XCTAssertTrue(try accountA.loadCollectionItems(collectionKey: "favorites").isEmpty)
        XCTAssertEqual(try accountB.loadCollections().count, 1)
        XCTAssertEqual(try accountB.loadCollectionItems(collectionKey: "favorites").count, 1)
        XCTAssertEqual(try accountB.loadStatusEvents().count, 1)
    }

    @MainActor
    func testCollectionAndStatusWritesRejectRemovedAccountRegistry() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 303, username: "removed"))
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()

        let repository = try AccountScopedLibraryRepository(context: context, accountID: "itch:303")
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<DBAccount>()).first)
        context.delete(account)
        try context.save()

        XCTAssertThrowsError(try repository.upsertCollection(
            collectionKey: "favorites", title: "Favorites"
        ))
        XCTAssertThrowsError(try repository.recordStatusEvent(
            eventKey: "event", gameID: "game", fromStatus: nil, toStatus: "playing"
        ))
        XCTAssertEqual(try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        ), 0)
        XCTAssertEqual(try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()
        ), 0)
    }

}
