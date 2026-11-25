import XCTest
import SwiftData
@testable import itchPocket

final class V4PersonalLibraryCatalogProjectionTests: XCTestCase {
    @MainActor
    func testLibraryProjectionJoinsSharedCatalogWithoutMixingAccountFields() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-library-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(
            in: supportDirectory,
            session: session
        )
        let context = dependencies.modelContext
        context.insert(DBDeveloper(
            id: "catalog-author",
            name: "Catalog Author",
            profileURL: "https://itch.io/profile/catalog-author",
            patreonURL: "https://patreon.com/catalog-author",
            discordURL: "https://discord.gg/catalog"
        ))
        context.insert(DBGame(
            id: "shared-catalog-game",
            title: "Shared Catalog Game",
            gameURL: "https://example.itch.io/game",
            coverURL: "https://example.com/cover.jpg",
            engine: "Ren'Py",
            developerID: "catalog-author"
        ))
        context.insert(DBGameDetail(
            gameID: "shared-catalog-game",
            descriptionText: "Shared description",
            galleryURLs: ["https://example.com/screenshot.jpg"],
            isComplete: true
        ))
        try context.save()

        let store = dependencies.makePersonalLibraryStore()
        let accountA = ItchAccountIdentity(itchUserID: 9401, username: "catalog-a")
        session.activate(accountA)
        let requestA = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(requestA)

        let dateA = Date(timeIntervalSince1970: 1_810_000_100)
        try store.addToLibrary(
            StoredAccountLibraryEntry(
                gameID: "shared-catalog-game",
                status: "playing",
                isFavorite: true,
                notes: "Private A note",
                addedAt: dateA,
                updatedAt: dateA
            ),
            initialEventKey: "catalog-a-initial"
        )
        try store.reloadLibraryGames()

        XCTAssertEqual(store.libraryGames.count, 1)
        let gameA = try XCTUnwrap(store.libraryGames.first)
        XCTAssertEqual(gameA.title, "Shared Catalog Game")
        XCTAssertEqual(gameA.developerName, "Catalog Author")
        XCTAssertEqual(gameA.patreonURL, "https://patreon.com/catalog-author")
        XCTAssertEqual(gameA.descriptionText, "Shared description")
        XCTAssertEqual(gameA.galleryURLs, ["https://example.com/screenshot.jpg"])
        XCTAssertEqual(gameA.status, "playing")
        XCTAssertEqual(gameA.notes, "Private A note")

        let accountB = ItchAccountIdentity(itchUserID: 9402, username: "catalog-b")
        session.activate(accountB)
        let requestB = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(requestB)
        try store.reloadLibraryGames()
        XCTAssertTrue(store.libraryGames.isEmpty)

        let dateB = Date(timeIntervalSince1970: 1_810_000_200)
        try store.addToLibrary(
            StoredAccountLibraryEntry(
                gameID: "shared-catalog-game",
                status: "completed",
                isFavorite: false,
                notes: "Private B note",
                addedAt: dateB,
                updatedAt: dateB
            ),
            initialEventKey: "catalog-b-initial"
        )
        try store.reloadLibraryGames()

        let gameB = try XCTUnwrap(store.libraryGames.first)
        XCTAssertEqual(gameB.title, gameA.title)
        XCTAssertEqual(gameB.developerName, gameA.developerName)
        XCTAssertEqual(gameB.coverURL, gameA.coverURL)
        XCTAssertEqual(gameB.descriptionText, gameA.descriptionText)
        XCTAssertEqual(gameB.status, "completed")
        XCTAssertEqual(gameB.notes, "Private B note")

        session.activate(accountA)
        try store.reloadLibraryGames()
        let reloadedA = try XCTUnwrap(store.libraryGames.first)
        XCTAssertEqual(reloadedA.status, "playing")
        XCTAssertEqual(reloadedA.notes, "Private A note")
    }

    @MainActor
    func testLibraryCatalogProjectionRejectsRemovedAccount() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("itchPocket-v4-library-catalog-removed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        let session = ItchAccountSession()
        let dependencies = try V4AppDependencies.open(in: supportDirectory, session: session)
        session.activate(ItchAccountIdentity(itchUserID: 9403, username: "removed-catalog"))
        let request = try XCTUnwrap(session.captureRequestContext())
        _ = try dependencies.recordAuthenticatedSession(request)

        let context = dependencies.modelContext
        let account = try XCTUnwrap(try context.fetch(FetchDescriptor<DBAccount>()).first)
        context.delete(account)
        try context.save()

        let store = dependencies.makePersonalLibraryStore()
        XCTAssertThrowsError(try store.reloadLibraryGames())
        XCTAssertTrue(store.libraryGames.isEmpty)
    }
}
