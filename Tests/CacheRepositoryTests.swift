import XCTest
import SwiftData
@testable import itchPocket

final class CacheRepositoryTests: XCTestCase {
    @MainActor
    func testTranslationCacheStoresAndUpdatesEntries() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = CacheRepository(database: database)

        try repository.storeTranslation(
            "Bonjour",
            source: "Hello",
            sourceHash: "source-hash",
            scope: "description",
            target: "fr",
            for: "translation-key"
        )

        let stored = try XCTUnwrap(repository.translation(for: "translation-key"))
        XCTAssertEqual(stored.translation, "Bonjour")
        XCTAssertEqual(stored.sourceText, "Hello")
        XCTAssertEqual(stored.sourceHash, "source-hash")
        XCTAssertEqual(stored.scope, "description")
        XCTAssertEqual(stored.target, "fr")

        try repository.storeTranslation(
            "Salut",
            source: "Hello there",
            sourceHash: "updated-hash",
            scope: "description",
            target: "fr",
            for: "translation-key"
        )

        let updated = try XCTUnwrap(repository.translation(for: "translation-key"))
        XCTAssertEqual(updated.translation, "Salut")
        XCTAssertEqual(updated.sourceText, "Hello there")
        XCTAssertEqual(try repository.counts().translations, 1)
    }

    @MainActor
    func testTranslationCacheEvictsOldestEntriesWhenCapacityIsExceeded() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        let baseline = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<1201 {
            context.insert(DBTranslation(
                cacheKey: "existing-\(index)",
                scope: "description",
                sourceHash: "hash-\(index)",
                sourceText: "source-\(index)",
                targetLanguage: "en",
                translatedText: "translated-\(index)",
                updatedAt: baseline.addingTimeInterval(TimeInterval(index))
            ))
        }
        try database.save()

        let repository = CacheRepository(database: database)
        try repository.storeTranslation(
            "newest",
            source: "new source",
            sourceHash: "new-hash",
            scope: "description",
            target: "en",
            for: "new-entry"
        )

        XCTAssertEqual(try repository.counts().translations, 1000)
        XCTAssertNil(try repository.translation(for: "existing-0"))
        XCTAssertNotNil(try repository.translation(for: "new-entry"))
        XCTAssertNotNil(try repository.translation(for: "existing-1200"))
    }

    @MainActor
    func testDiscoverySnapshotExpiresAndIsRemovedOnRead() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = CacheRepository(database: database)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = Data("snapshot".utf8)

        try repository.storeDiscoverySnapshot(
            payload,
            key: "expired",
            timeToLive: 60,
            now: now.addingTimeInterval(-120)
        )

        XCTAssertNil(try repository.discoverySnapshot(for: "expired", now: now))
        XCTAssertEqual(try repository.counts().discoverySnapshots, 0)
    }

    @MainActor
    func testClearingRebuildableCachesPreservesDurableRecordsAndInvalidatesOwnedCaches() throws {
        let database = try AppDatabase(inMemory: true)
        let context = database.context
        context.insert(DBGame(id: "durable-game", title: "Durable Game"))
        context.insert(DBDeveloper(
            id: "developer",
            name: "Developer",
            avatarURL: "https://example.com/avatar.png",
            avatarSource: "patreon",
            avatarResolvedAt: .now
        ))
        context.insert(DBTranslation(
            cacheKey: "translation",
            scope: "description",
            sourceHash: "hash",
            sourceText: "source",
            targetLanguage: "en",
            translatedText: "translated"
        ))
        context.insert(DBDiscoverySnapshot(
            key: "discovery",
            payload: Data(),
            expiresAt: .now.addingTimeInterval(3600)
        ))
        context.insert(DBAppState(key: "avatarFailure.developer", stringValue: "failed"))
        context.insert(DBAppState(key: "user.preference", stringValue: "keep"))
        try database.save()

        let cacheRepository = CacheRepository(database: database)
        try cacheRepository.clearRebuildableCaches(save: false)
        try AppStateRepository(database: database)
            .removeAll(matchingKeyPrefix: "avatarFailure.", save: false)
        try DeveloperRepository(database: database).invalidateAvatarCaches(save: false)
        try database.save()

        XCTAssertNotNil(try GameRepository(database: database).game(id: "durable-game"))
        XCTAssertEqual(try cacheRepository.counts().translations, 0)
        XCTAssertEqual(try cacheRepository.counts().discoverySnapshots, 0)
        XCTAssertNil(try AppStateRepository(database: database).state(for: "avatarFailure.developer"))
        XCTAssertEqual(
            try AppStateRepository(database: database).state(for: "user.preference")?.stringValue,
            "keep"
        )

        let storedDeveloper = try XCTUnwrap(
            DeveloperRepository(database: database).developer(id: "developer")
        )
        XCTAssertNil(storedDeveloper.avatarURL)
        XCTAssertNil(storedDeveloper.avatarSource)
        XCTAssertNil(storedDeveloper.avatarResolvedAt)
    }

    @MainActor
    func testCacheTranslationStoreFailureRollsBackInsertedRow() throws {
        let database = try AppDatabase(inMemory: true)
        let repository = CacheRepository(database: database)
        database.simulatedSaveError = { NSError(domain: "test", code: 1) }

        XCTAssertThrowsError(try repository.storeTranslation(
            "translated",
            source: "source",
            sourceHash: "hash",
            scope: "description",
            target: "zh-CN",
            for: "cache-key"
        ))
        database.simulatedSaveError = nil

        XCTAssertFalse(database.context.hasChanges)
        XCTAssertTrue(try database.context.fetch(FetchDescriptor<DBTranslation>()).isEmpty)
    }
}
