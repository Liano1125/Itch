import XCTest
import SwiftData
@testable import itchPocket

final class V4LegacyLibraryConverterTests: XCTestCase {
    @MainActor
    private func makeV4Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-library-migration-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testCopiesLegacyLibraryRowsWithoutAssigningCurrentAccountOwnership() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let changed = Date(timeIntervalSince1970: 1_700_000_100)

        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBGame(id: "game-b", title: "Game B"))
        source.insert(DBLibraryEntry(
            gameID: "game-a", status: "playing", isFavorite: true,
            notes: "private library note", addedAt: created, updatedAt: changed
        ))
        source.insert(DBLibraryCollection(
            id: "collection-a", title: "Favorites", createdAt: created, updatedAt: changed
        ))
        source.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-a", gameID: "game-b"),
            collectionID: "collection-a", gameID: "game-b", sortOrder: 3, addedAt: changed
        ))
        source.insert(DBLibraryStatusEvent(
            id: "status-event-a", gameID: "game-a", fromStatus: "backlog",
            toStatus: "playing", changedAt: changed
        ))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        let report = try V4LegacyLibraryConverter.convert(
            source: source, destination: destination.mainContext
        )

        XCTAssertEqual(report.libraryEntryCount, 1)
        XCTAssertEqual(report.collectionCount, 1)
        XCTAssertEqual(report.collectionItemCount, 1)
        XCTAssertEqual(report.statusEventCount, 1)
        XCTAssertEqual(report.totalRows, 4)
        XCTAssertEqual(report.inventoryDigest.count, 64)

        let context = destination.mainContext
        let entry = try XCTUnwrap(context.fetch(FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()).first)
        XCTAssertNil(entry.accountID)
        XCTAssertEqual(entry.gameID, "game-a")
        XCTAssertEqual(entry.status, "playing")
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.notes, "private library note")
        XCTAssertEqual(entry.addedAt, created)
        XCTAssertEqual(entry.updatedAt, changed)

        let collection = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollection>()
        ).first)
        XCTAssertNil(collection.accountID)
        XCTAssertEqual(collection.collectionKey, "collection-a")
        XCTAssertEqual(collection.title, "Favorites")

        let item = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryCollectionItem>()
        ).first)
        XCTAssertNil(item.accountID)
        XCTAssertEqual(item.collectionKey, "collection-a")
        XCTAssertEqual(item.gameID, "game-b")
        XCTAssertEqual(item.sortOrder, 3)

        let event = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryStatusEvent>()
        ).first)
        XCTAssertNil(event.accountID)
        XCTAssertEqual(event.eventKey, "status-event-a")
        XCTAssertEqual(event.gameID, "game-a")
        XCTAssertEqual(event.fromStatus, "backlog")
        XCTAssertEqual(event.toStatus, "playing")

        // Conversion is copy-only: the V3 source rows remain intact.
        XCTAssertEqual(try source.fetchCount(FetchDescriptor<DBLibraryEntry>()), 1)
        XCTAssertEqual(try source.fetchCount(FetchDescriptor<DBLibraryCollection>()), 1)
        XCTAssertEqual(try source.fetchCount(FetchDescriptor<DBLibraryCollectionItem>()), 1)
        XCTAssertEqual(try source.fetchCount(FetchDescriptor<DBLibraryStatusEvent>()), 1)
    }

    @MainActor
    func testRejectsBrokenReferencesBeforeWritingToV4() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBLibraryEntry(gameID: "missing-game", status: "playing"))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        XCTAssertThrowsError(try V4LegacyLibraryConverter.convert(
            source: source, destination: destination.mainContext
        )) { error in
            XCTAssertEqual(
                error as? V4LegacyLibraryConverter.ConversionError,
                .missingGame("missing-game")
            )
        }
        XCTAssertEqual(try destination.mainContext.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ), 0)
    }

    @MainActor
    func testRefusesNonEmptyDestinationRatherThanMergingUnknownStagingRows() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBLibraryEntry(gameID: "game-a", status: "playing"))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        let context = destination.mainContext
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: nil, gameID: "preexisting", status: "backlog"
        ))
        try context.save()

        XCTAssertThrowsError(try V4LegacyLibraryConverter.convert(
            source: source, destination: context
        )) { error in
            XCTAssertEqual(error as? V4LegacyLibraryConverter.ConversionError, .destinationNotEmpty)
        }
        XCTAssertEqual(try context.fetchCount(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ), 1)
    }

    @MainActor
    func testRejectsPendingSourceOrDestinationChanges() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBGame(id: "game-a", title: "Game A"))

        let destination = try makeV4Container()
        XCTAssertThrowsError(try V4LegacyLibraryConverter.convert(
            source: source, destination: destination.mainContext
        )) { error in
            XCTAssertEqual(error as? V4LegacyLibraryConverter.ConversionError, .sourceHasPendingChanges)
        }

        try sourceDatabase.save()
        destination.mainContext.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: nil, gameID: "pending", status: "backlog"
        ))
        XCTAssertThrowsError(try V4LegacyLibraryConverter.convert(
            source: source, destination: destination.mainContext
        )) { error in
            XCTAssertEqual(error as? V4LegacyLibraryConverter.ConversionError, .destinationHasPendingChanges)
        }
    }
}
