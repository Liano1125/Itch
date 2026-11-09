import XCTest
import SwiftData
@testable import itchPocket

final class GameRepositoryTests: XCTestCase {
    @MainActor
    func testLoadByIDReturnsCompleteImmutableGameSnapshots() throws {
        let database = try AppDatabase(inMemory: true)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        database.context.insert(DBGame(
            id: "game-a",
            title: "Game A",
            gameURL: "https://author.itch.io/game-a",
            coverURL: "https://cdn.example/cover.png",
            descriptionText: "Description",
            galleryURLs: ["https://cdn.example/1.png"],
            discoveryTagsData: Data("[{\"name\":\"Ren'Py\",\"url\":\"https://itch.io/tags/renpy\"}]".utf8),
            engine: "Ren'Py",
            developerID: "author-a",
            updatedAt: updatedAt
        ))
        try database.save()

        let repository = GameRepository(database: database)
        let game = try XCTUnwrap(repository.game(id: "game-a"))
        XCTAssertEqual(game.title, "Game A")
        XCTAssertEqual(game.gameURL, "https://author.itch.io/game-a")
        XCTAssertEqual(game.coverURL, "https://cdn.example/cover.png")
        XCTAssertEqual(game.descriptionText, "Description")
        XCTAssertEqual(game.galleryURLs, ["https://cdn.example/1.png"])
        XCTAssertNotNil(game.discoveryTagsData)
        XCTAssertEqual(game.engine, "Ren'Py")
        XCTAssertEqual(game.developerID, "author-a")
        XCTAssertEqual(game.updatedAt, updatedAt)
        XCTAssertEqual(try repository.loadByID()["game-a"], game)
    }

    @MainActor
    func testMetadataUpsertPreservesOptionalFieldsWhenIncomingValuesAreNil() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(
            id: "game-a",
            title: "Old title",
            gameURL: "https://author.itch.io/game-a",
            coverURL: "https://cdn.example/cover.png",
            engine: "Ren'Py",
            developerID: "author-a"
        ))
        try database.save()

        let repository = GameRepository(database: database)
        try repository.upsertMetadata(id: "game-a", title: "New title")

        let game = try XCTUnwrap(repository.game(id: "game-a"))
        XCTAssertEqual(game.title, "New title")
        XCTAssertEqual(game.gameURL, "https://author.itch.io/game-a")
        XCTAssertEqual(game.coverURL, "https://cdn.example/cover.png")
        XCTAssertEqual(game.engine, "Ren'Py")
        XCTAssertEqual(game.developerID, "author-a")
    }

    @MainActor
    func testMetadataUpsertCreatesAndUpdatesOnlyTheRequestedGame() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "other", title: "Other"))
        try database.save()

        let repository = GameRepository(database: database)
        try repository.upsertMetadata(
            id: "game-a",
            title: "Game A",
            gameURL: "https://author.itch.io/game-a",
            engine: "Ren'Py",
            developerID: "author-a",
            save: false
        )

        XCTAssertTrue(database.context.hasChanges)
        XCTAssertEqual(try repository.game(id: "game-a")?.developerID, "author-a")
        XCTAssertEqual(try repository.game(id: "other")?.title, "Other")
        try database.save()

        try repository.upsertMetadata(id: "game-a", title: "Game A Updated", coverURL: "https://cdn.example/new.png")
        XCTAssertEqual(try repository.game(id: "game-a")?.title, "Game A Updated")
        XCTAssertEqual(try repository.game(id: "game-a")?.coverURL, "https://cdn.example/new.png")
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBGame>()).count, 2)
    }

    @MainActor
    func testLegacyDetailCanBeReadAndUpdatedWithoutExposingDBGame() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "Game A"))
        try database.save()

        let repository = GameRepository(database: database)
        let original = try XCTUnwrap(repository.legacyDetail(for: "game-a"))
        XCTAssertNil(original.descriptionText)
        XCTAssertEqual(original.galleryURLs, [])
        XCTAssertNil(original.discoveryTagsData)

        let updated = StoredLegacyGameDetail(
            descriptionText: "Details",
            galleryURLs: ["https://cdn.example/gallery.png"],
            discoveryTagsData: Data("[]".utf8)
        )
        try repository.setLegacyDetail(updated, for: "game-a", save: false)
        XCTAssertTrue(database.context.hasChanges)
        XCTAssertEqual(try repository.legacyDetail(for: "game-a"), updated)
    }

    @MainActor
    func testExistingGameIDsReturnsOnlyRequestedExistingIDs() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        database.context.insert(DBGame(id: "game-b", title: "B"))
        database.context.insert(DBGame(id: "unrelated", title: "Other"))
        try database.save()

        let repository = GameRepository(database: database)
        XCTAssertEqual(
            try repository.existingGameIDs(in: ["game-a", "missing", "game-b", "game-a"]),
            ["game-a", "game-b"]
        )
        XCTAssertTrue(try repository.existingGameIDs(in: []).isEmpty)
    }

    @MainActor
    func testUpsertNeverDeletesUnmentionedGameRows() throws {
        let database = try AppDatabase(inMemory: true)
        database.context.insert(DBGame(id: "game-a", title: "A"))
        database.context.insert(DBGame(id: "game-b", title: "B"))
        try database.save()

        let repository = GameRepository(database: database)
        try repository.upsertMetadata(id: "game-a", title: "A updated")

        XCTAssertNotNil(try repository.game(id: "game-b"))
        XCTAssertEqual(try database.context.fetch(FetchDescriptor<DBGame>()).count, 2)
    }
}
