import XCTest
import SwiftData
@testable import itchPocket

final class DeveloperRepositoryTests: XCTestCase {
    @MainActor
    func testIdentityUpsertAndLoadPreserveAllDeveloperFields() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DeveloperRepository(database: database)

        try repository.upsertIdentity(
            id: "https://itch.io/profile/author",
            name: "Author",
            profileURL: "https://itch.io/profile/author",
            patreonURL: "https://patreon.com/author",
            discordURL: "https://discord.gg/example"
        )
        try repository.setAvatar(
            id: "https://itch.io/profile/author",
            url: "https://cdn.example/avatar.png",
            source: "patreon",
            resolvedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let stored = try XCTUnwrap(repository.developer(id: "https://itch.io/profile/author"))
        XCTAssertEqual(stored.name, "Author")
        XCTAssertEqual(stored.profileURL, "https://itch.io/profile/author")
        XCTAssertEqual(stored.patreonURL, "https://patreon.com/author")
        XCTAssertEqual(stored.discordURL, "https://discord.gg/example")
        XCTAssertEqual(stored.avatarURL, "https://cdn.example/avatar.png")
        XCTAssertEqual(stored.avatarSource, "patreon")
        XCTAssertEqual(stored.avatarResolvedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    func testIdentityUpsertPreservesExistingOptionalFieldsWhenIncomingValuesAreNil() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DeveloperRepository(database: database)
        try repository.upsertIdentity(
            id: "author",
            name: "Original",
            profileURL: "https://itch.io/profile/author",
            patreonURL: "https://patreon.com/author",
            discordURL: "https://discord.gg/example"
        )

        try repository.upsertIdentity(id: "author", name: "Updated")

        let stored = try XCTUnwrap(repository.developer(id: "author"))
        XCTAssertEqual(stored.name, "Updated")
        XCTAssertEqual(stored.profileURL, "https://itch.io/profile/author")
        XCTAssertEqual(stored.patreonURL, "https://patreon.com/author")
        XCTAssertEqual(stored.discordURL, "https://discord.gg/example")
    }

    @MainActor
    func testAvatarUpdateCanDeferSaveAndPreserveResolutionTimestamp() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DeveloperRepository(database: database)
        let resolvedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try repository.upsertIdentity(id: "author", name: "Author")
        try repository.setAvatar(id: "author", url: "https://cdn.example/one.png", source: "itch", resolvedAt: resolvedAt)

        try repository.setAvatar(
            id: "author",
            url: "https://cdn.example/two.png",
            source: "patreon",
            save: false
        )

        XCTAssertTrue(database.context.hasChanges)
        let stored = try XCTUnwrap(repository.developer(id: "author"))
        XCTAssertEqual(stored.avatarURL, "https://cdn.example/two.png")
        XCTAssertEqual(stored.avatarResolvedAt, resolvedAt)
        try database.save()
        XCTAssertFalse(database.context.hasChanges)
    }

    @MainActor
    func testAvatarCacheInvalidationOnlyClearsAvatarFields() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DeveloperRepository(database: database)
        try repository.upsertIdentity(
            id: "author",
            name: "Author",
            profileURL: "https://itch.io/profile/author",
            patreonURL: "https://patreon.com/author",
            discordURL: "https://discord.gg/example"
        )
        try repository.setAvatar(
            id: "author",
            url: "https://cdn.example/avatar.png",
            source: "patreon",
            resolvedAt: .now
        )

        try repository.invalidateAvatarCaches()

        let stored = try XCTUnwrap(repository.developer(id: "author"))
        XCTAssertNil(stored.avatarURL)
        XCTAssertNil(stored.avatarSource)
        XCTAssertNil(stored.avatarResolvedAt)
        XCTAssertEqual(stored.name, "Author")
        XCTAssertEqual(stored.profileURL, "https://itch.io/profile/author")
        XCTAssertEqual(stored.patreonURL, "https://patreon.com/author")
        XCTAssertEqual(stored.discordURL, "https://discord.gg/example")
    }

    @MainActor
    func testLoadByIDReturnsSharedCanonicalDeveloperRows() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = DeveloperRepository(database: database)
        try repository.upsertIdentity(id: "author-a", name: "Author A")
        try repository.upsertIdentity(id: "author-b", name: "Author B")

        let stored = try repository.loadByID()
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored["author-a"]?.name, "Author A")
        XCTAssertEqual(stored["author-b"]?.name, "Author B")
    }

    func testCanonicalIDNormalizesSchemeHostAndTrailingSlash() {
        XCTAssertEqual(
            DeveloperRepository.canonicalID(for: "HTTPS://ITCH.IO/profile/author/?token=1#bio"),
            "https://itch.io/profile/author"
        )
    }
}
