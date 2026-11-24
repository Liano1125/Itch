import XCTest
import SwiftData
@testable import itchPocket

final class AccountScopedUpdateWatchRepositoryTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-update-watch-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        for userID in [5, 101, 202, 999] {
            container.mainContext.insert(DBAccount(itchUserID: userID, username: "test-\(userID)"))
        }
        try container.mainContext.save()
        return container
    }

    @MainActor
    func testSameGameWatchPreferencesAndValidatorsAreIsolatedByAccount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()
        let a = try AccountScopedUpdateWatchRepository(context: context, accountID: "itch:101")
        let b = try AccountScopedUpdateWatchRepository(context: context, accountID: "itch:202")

        try a.upsert(StoredAccountUpdateWatch(
            gameID: "game", entityTag: "A-etag", lastModified: "A-date",
            contentHash: "A-hash", lastCheckedAt: Date(timeIntervalSince1970: 10),
            hasBaseline: true, isEnabled: true
        ))
        try b.upsert(StoredAccountUpdateWatch(
            gameID: "game", entityTag: "B-etag", lastModified: "B-date",
            contentHash: "B-hash", lastCheckedAt: Date(timeIntervalSince1970: 20),
            hasBaseline: false, isEnabled: false
        ))

        XCTAssertEqual(try a.loadWatches(), [StoredAccountUpdateWatch(
            gameID: "game", entityTag: "A-etag", lastModified: "A-date",
            contentHash: "A-hash", lastCheckedAt: Date(timeIntervalSince1970: 10),
            hasBaseline: true, isEnabled: true
        )])
        XCTAssertEqual(try b.loadWatches(), [StoredAccountUpdateWatch(
            gameID: "game", entityTag: "B-etag", lastModified: "B-date",
            contentHash: "B-hash", lastCheckedAt: Date(timeIntervalSince1970: 20),
            hasBaseline: false, isEnabled: false
        )])

        try b.setEnabled(gameID: "game", isEnabled: true)
        XCTAssertTrue(try XCTUnwrap(b.loadWatches().first).isEnabled)
        XCTAssertEqual(try XCTUnwrap(b.loadWatches().first).entityTag, "B-etag")
        XCTAssertTrue(try XCTUnwrap(a.loadWatches().first).isEnabled)
        XCTAssertEqual(try XCTUnwrap(a.loadWatches().first).entityTag, "A-etag")

        try b.delete(gameID: "game")
        XCTAssertEqual(try a.loadWatches().count, 1)
        XCTAssertTrue(try b.loadWatches().isEmpty)
    }

    @MainActor
    func testRejectsInvalidAccountAndMissingGameBeforeMutation() throws {
        let container = try makeContainer()
        for invalid in ["", "itch:0", "itch:01", "patreon:5", " itch:5"] {
            XCTAssertThrowsError(try AccountScopedUpdateWatchRepository(
                context: container.mainContext, accountID: invalid
            ))
        }
        let repository = try AccountScopedUpdateWatchRepository(
            context: container.mainContext, accountID: "itch:5"
        )
        XCTAssertThrowsError(try repository.upsert(StoredAccountUpdateWatch(
            gameID: "missing", entityTag: nil, lastModified: nil, contentHash: nil,
            lastCheckedAt: nil, hasBaseline: false, isEnabled: true
        )))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBAccountUpdateWatch>()), 0)
    }

    @MainActor
    func testLegacyRowsAreCopiedLosslesslyToUnassignedQuarantineAndRemainInSource() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_123)
        context.insert(DBGame(id: "known", title: "Known"))
        context.insert(DBUpdateWatch(
            gameID: "known", entityTag: "etag", lastModified: "modified",
            contentHash: "hash", lastCheckedAt: checkedAt, hasBaseline: true, isEnabled: false
        ))
        context.insert(DBUpdateWatch(
            gameID: "orphan", entityTag: nil, lastModified: "orphan-date",
            contentHash: "orphan-hash", lastCheckedAt: nil, hasBaseline: false, isEnabled: true
        ))
        try context.save()
        let repository = try AccountScopedUpdateWatchRepository(context: context, accountID: "itch:999")

        XCTAssertEqual(try repository.quarantineLegacyRows(quarantinedAt: checkedAt), 2)
        XCTAssertEqual(try repository.quarantineLegacyRows(quarantinedAt: checkedAt), 0)

        let quarantined = try context.fetch(FetchDescriptor<DBLegacyUpdateWatch>())
        let known = try XCTUnwrap(quarantined.first { $0.originalGameID == "known" })
        XCTAssertEqual(known.entityTag, "etag")
        XCTAssertEqual(known.lastModified, "modified")
        XCTAssertEqual(known.contentHash, "hash")
        XCTAssertEqual(known.lastCheckedAt, checkedAt)
        XCTAssertTrue(known.hasBaseline)
        XCTAssertFalse(known.isEnabled)
        XCTAssertNil(known.integrityIssue)

        let orphan = try XCTUnwrap(quarantined.first { $0.originalGameID == "orphan" })
        XCTAssertEqual(orphan.integrityIssue, "missing-game")
        XCTAssertNil(orphan.entityTag)
        XCTAssertEqual(orphan.lastModified, "orphan-date")
        XCTAssertEqual(orphan.contentHash, "orphan-hash")

        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBUpdateWatch>()), 2)
        XCTAssertTrue(try repository.loadWatches().isEmpty)
    }

    @MainActor
    func testRetainedRepositoryCannotRecreateWatchAfterAccountRemoval() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBGame(id: "game", title: "Game"))
        try context.save()
        let repository = try AccountScopedUpdateWatchRepository(context: context, accountID: "itch:101")
        let account = try XCTUnwrap(context.fetch(FetchDescriptor<DBAccount>()).first { $0.id == "itch:101" })
        context.delete(account)
        try context.save()

        XCTAssertThrowsError(try repository.upsert(StoredAccountUpdateWatch(
            gameID: "game", entityTag: "late", lastModified: nil, contentHash: nil,
            lastCheckedAt: .now, hasBaseline: true, isEnabled: true
        )))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DBAccountUpdateWatch>()), 0)
    }

}
