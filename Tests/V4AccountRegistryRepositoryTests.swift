import XCTest
import SwiftData
@testable import itchPocket

final class V4AccountRegistryRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([DBAccount.self])
        let configuration = ModelConfiguration(
            "itchPocket-v4-account-registry-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testAuthenticatedIdentityCreatesOneStableAccountRecord() throws {
        let context = try makeContainer().mainContext
        let repository = V4AccountRegistryRepository(context: context)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = ItchAccountIdentity(
            itchUserID: 701,
            username: "first-name",
            displayName: "First",
            profileURL: URL(string: "https://itch.io/profile/first"),
            avatarURL: URL(string: "https://itch.io/avatar.png")
        )

        let created = try repository.recordAuthenticatedIdentity(identity, at: date)
        let loaded = try XCTUnwrap(repository.loadAccount(itchUserID: 701))

        XCTAssertEqual(created.id, "itch:701")
        XCTAssertEqual(loaded.id, created.id)
        XCTAssertEqual(loaded.firstSeenAt, date)
        XCTAssertEqual(loaded.lastAuthenticatedAt, date)
        XCTAssertEqual(loaded.lastUsedAt, date)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
    }

    @MainActor
    func testReauthenticationRefreshesProfileWithoutChangingIdentityOrFirstSeen() throws {
        let context = try makeContainer().mainContext
        let repository = V4AccountRegistryRepository(context: context)
        let firstSeen = Date(timeIntervalSince1970: 1_700_000_000)
        let refreshedAt = firstSeen.addingTimeInterval(500)

        _ = try repository.recordAuthenticatedIdentity(
            ItchAccountIdentity(itchUserID: 702, username: "old-name"),
            at: firstSeen
        )
        let refreshed = try repository.recordAuthenticatedIdentity(
            ItchAccountIdentity(
                itchUserID: 702,
                username: "new-name",
                displayName: "New Name"
            ),
            at: refreshedAt
        )

        XCTAssertEqual(refreshed.id, "itch:702")
        XCTAssertEqual(refreshed.username, "new-name")
        XCTAssertEqual(refreshed.displayName, "New Name")
        XCTAssertEqual(refreshed.firstSeenAt, firstSeen)
        XCTAssertEqual(refreshed.lastAuthenticatedAt, refreshedAt)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 1)
    }

    @MainActor
    func testRepositoryRejectsInvalidIdentityWithoutWriting() throws {
        let context = try makeContainer().mainContext
        let repository = V4AccountRegistryRepository(context: context)

        XCTAssertThrowsError(try repository.recordAuthenticatedIdentity(
            ItchAccountIdentity(itchUserID: 0, username: "invalid")
        ))
        XCTAssertThrowsError(try repository.recordAuthenticatedIdentity(
            ItchAccountIdentity(itchUserID: 703, username: "   ")
        ))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccount>()), 0)
    }

    @MainActor
    func testUnknownAccountLookupReturnsNil() throws {
        let repository = V4AccountRegistryRepository(context: try makeContainer().mainContext)
        XCTAssertNil(try repository.loadAccount(itchUserID: 999))
        XCTAssertThrowsError(try repository.loadAccount(itchUserID: 0))
    }
}
