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
}
