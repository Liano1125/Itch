import XCTest
import SwiftData
@testable import itchPocket

final class V4LibraryMigrationParityGateTests: XCTestCase {
    @MainActor
    func testAcceptsExactLibraryCountsFromCleanPreflight() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBLibraryEntry(gameID: "game-a", status: "playing"))
        source.insert(DBLibraryCollection(id: "collection-a", title: "Favorites"))
        source.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-a", gameID: "game-a"),
            collectionID: "collection-a", gameID: "game-a", sortOrder: 0
        ))
        source.insert(DBLibraryStatusEvent(
            id: "status-a", gameID: "game-a", fromStatus: nil, toStatus: "playing"
        ))
        try sourceDatabase.save()

        let preflight = try V3MigrationPreflight.inspect(context: source)
        XCTAssertTrue(preflight.isStructurallyValid)

        let converted = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 1,
            collectionCount: 1,
            collectionItemCount: 1,
            statusEventCount: 1,
            inventoryDigest: String(repeating: "a", count: 64)
        )
        XCTAssertNoThrow(try V4LibraryMigrationParityGate.validate(
            source: preflight, converted: converted
        ))
    }

    @MainActor
    func testRejectsCountMismatchEvenWhenSourceIsStructurallyValid() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBLibraryEntry(gameID: "game-a", status: "playing"))
        try sourceDatabase.save()

        let preflight = try V3MigrationPreflight.inspect(context: source)
        let converted = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 0,
            collectionCount: 0,
            collectionItemCount: 0,
            statusEventCount: 0,
            inventoryDigest: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(try V4LibraryMigrationParityGate.validate(
            source: preflight, converted: converted
        )) { error in
            XCTAssertEqual(
                error as? V4LibraryMigrationParityGate.GateError,
                .countMismatch(domain: "libraryEntries", source: 1, converted: 0)
            )
        }
    }

    @MainActor
    func testRejectsStructurallyInvalidSourceBeforeConsideringCounts() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBLibraryEntry(gameID: "missing-game", status: "playing"))
        try sourceDatabase.save()

        let preflight = try V3MigrationPreflight.inspect(context: source)
        XCTAssertFalse(preflight.isStructurallyValid)
        let converted = V4LegacyLibraryMigrationReport(
            libraryEntryCount: 1,
            collectionCount: 0,
            collectionItemCount: 0,
            statusEventCount: 0,
            inventoryDigest: String(repeating: "c", count: 64)
        )

        XCTAssertThrowsError(try V4LibraryMigrationParityGate.validate(
            source: preflight, converted: converted
        )) { error in
            guard case .sourceIntegrityIssues(let issues) = error as? V4LibraryMigrationParityGate.GateError else {
                return XCTFail("Expected sourceIntegrityIssues, got \(error)")
            }
            XCTAssertTrue(issues.contains("libraryEntry.missingGame:missing-game"))
        }
    }
}
