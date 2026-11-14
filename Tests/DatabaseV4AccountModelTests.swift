import XCTest
import SwiftData
@testable import itchPocket

final class DatabaseV4AccountModelTests: XCTestCase {
    @MainActor
    func testV4PersistsDistinctAccountsByNumericItchUserID() throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-account-identities",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        context.insert(DBAccount(itchUserID: 101, username: "same-name"))
        context.insert(DBAccount(itchUserID: 202, username: "same-name"))
        try context.save()

        let accounts = try context.fetch(FetchDescriptor<DBAccount>())
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\\.id)), ["itch:101", "itch:202"])
        XCTAssertEqual(Set(accounts.map(\\.itchUserID)), [101, 202])
    }

    @MainActor
    func testProfileRefreshKeepsStableAccountIdentityAndFirstSeenDate() throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-account-profile-refresh",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let account = DBAccount(
            itchUserID: 303,
            username: "before",
            firstSeenAt: firstSeen
        )
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
    func testSharedGameDirectoryIsNotDuplicatedForTwoAccounts() throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-shared-game-directory",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        context.insert(DBAccount(itchUserID: 1, username: "account-a"))
        context.insert(DBAccount(itchUserID: 2, username: "account-b"))
        context.insert(DBGame(id: "shared-game", title: "Shared Game"))
        try context.save()

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBGame>()), 1)
    }
}
