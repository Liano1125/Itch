import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseV4AccountModelTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        // Give every container a unique in-memory store identity. This keeps
        // independent XCTest cases from sharing a SwiftData coordinator.
        let configuration = ModelConfiguration(
            "itchPocket-v4-account-scope-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testV4PersistsDistinctAccountsByNumericItchUserID() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 101, username: "same-name"))
        context.insert(DBAccount(itchUserID: 202, username: "same-name"))
        try context.save()

        let accounts = try context.fetch(FetchDescriptor<DBAccount>())
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\.id)), ["itch:101", "itch:202"])
        XCTAssertEqual(Set(accounts.map(\.itchUserID)), [101, 202])
    }

    @MainActor
    func testProfileRefreshKeepsStableAccountIdentityAndFirstSeenDate() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let account = DBAccount(itchUserID: 303, username: "before", firstSeenAt: firstSeen)
        context.insert(account)
        try context.save()

        account.refreshProfile(from: ItchAccountIdentity(
            itchUserID: 303,
            username: "after",
            displayName: "Updated",
            profileURL: URL(string: "https://itch.io/profile/after")
        ))
        try context.save()

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<DBAccount>()).first)
        XCTAssertEqual(stored.id, "itch:303")
        XCTAssertEqual(stored.username, "after")
        XCTAssertEqual(stored.displayName, "Updated")
        XCTAssertEqual(stored.firstSeenAt, firstSeen)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
    }

    @MainActor
    func testSameGameCanHaveIndependentLibraryEntriesForTwoAccounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let accountA = DBAccount(itchUserID: 1, username: "a")
        let accountB = DBAccount(itchUserID: 2, username: "b")
        context.insert(accountA)
        context.insert(accountB)

        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: accountA.id, gameID: "game-1", status: "playing"
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: accountB.id, gameID: "game-1", status: "completed"
        ))
        try context.save()

        let entries = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>())
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.accountID)), [accountA.id, accountB.id])
        XCTAssertEqual(Set(entries.map(\.status)), ["playing", "completed"])
        XCTAssertEqual(Set(entries.map(\.gameID)), ["game-1"])
    }

    @MainActor
    func testCollectionsMembershipAndStatusEventsAreAccountScoped() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let accountA = DBAccount(itchUserID: 11, username: "a")
        let accountB = DBAccount(itchUserID: 22, username: "b")
        context.insert(accountA)
        context.insert(accountB)

        let collectionA = ItchPocketSchemaV4.DBLibraryCollection(
            accountID: accountA.id, collectionKey: "favorites", title: "Favorites"
        )
        let collectionB = ItchPocketSchemaV4.DBLibraryCollection(
            accountID: accountB.id, collectionKey: "favorites", title: "Favorites"
        )
        context.insert(collectionA)
        context.insert(collectionB)
        context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(
            accountID: accountA.id, collectionKey: "favorites", gameID: "game-1", sortOrder: 0
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(
            accountID: accountB.id, collectionKey: "favorites", gameID: "game-1", sortOrder: 0
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(
            accountID: accountA.id, eventKey: "event-1", gameID: "game-1",
            fromStatus: nil, toStatus: "playing"
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(
            accountID: accountB.id, eventKey: "event-1", gameID: "game-1",
            fromStatus: nil, toStatus: "completed"
        ))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()), 2)
        XCTAssertNotEqual(collectionA.id, collectionB.id)
    }

    @MainActor
    func testLegacyRowsRemainExplicitlyUnassigned() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: nil, gameID: "legacy-game", status: "playing"
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryCollection(
            accountID: nil, collectionKey: "legacy-list", title: "Legacy"
        ))
        try context.save()

        let entry = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ).first)
        let collection = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        ).first)
        XCTAssertNil(entry.accountID)
        XCTAssertNil(collection.accountID)
        XCTAssertEqual(entry.id, ItchPocketSchemaV4.DBLibraryEntry.stableID(
            accountID: nil, gameID: "legacy-game"
        ))
    }


    @MainActor
    func testAccountScopedLibraryRepositoryKeepsSameGameEntriesIndependent() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "shared-game", title: "Shared"))
        try context.save()

        let accountA = try AccountScopedLibraryRepository(context: context, accountID: "itch:101")
        let accountB = try AccountScopedLibraryRepository(context: context, accountID: "itch:202")
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try accountA.upsertEntry(StoredAccountLibraryEntry(
            gameID: "shared-game", status: "playing", isFavorite: true,
            notes: "A only", addedAt: now, updatedAt: now
        ))
        try accountB.upsertEntry(StoredAccountLibraryEntry(
            gameID: "shared-game", status: "completed", isFavorite: false,
            notes: "B only", addedAt: now, updatedAt: now
        ))

        XCTAssertEqual(try accountA.loadEntries().map(\.notes), ["A only"])
        XCTAssertEqual(try accountB.loadEntries().map(\.notes), ["B only"])
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()), 2)
    }

    @MainActor
    func testAccountScopedLibraryRepositoryCannotReadOrDeleteAnotherAccountEntry() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "shared-game", title: "Shared"))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: "itch:202", gameID: "shared-game", status: "completed"
        ))
        try context.save()

        let accountA = try AccountScopedLibraryRepository(context: context, accountID: "itch:101")
        XCTAssertTrue(try accountA.loadEntries().isEmpty)
        try accountA.removeEntry(gameID: "shared-game")

        let remaining = try context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.accountID, "itch:202")
    }

    @MainActor
    func testAccountScopedLibraryRepositoryRejectsMissingIdentityAndMissingSharedGame() throws {
        let container = try makeContainer()
        XCTAssertThrowsError(try AccountScopedLibraryRepository(
            context: container.mainContext, accountID: ""
        ))

        let repository = try AccountScopedLibraryRepository(
            context: container.mainContext, accountID: "itch:101"
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertThrowsError(try repository.upsertEntry(StoredAccountLibraryEntry(
            gameID: "not-in-directory", status: "playing", isFavorite: false,
            notes: "", addedAt: now, updatedAt: now
        )))
        XCTAssertEqual(try container.mainContext.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ), 0)
    }

    @MainActor
    func testSharedGameDirectoryIsNotDuplicatedForTwoAccounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 1, username: "account-a"))
        context.insert(DBAccount(itchUserID: 2, username: "account-b"))
        context.insert(DBGame(id: "shared-game", title: "Shared Game"))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1)
    }
}
