import XCTest
import SwiftData
@testable import itchPocket

final class V4MigrationPayloadVerifierTests: XCTestCase {
    @MainActor
    private func makeV4Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-payload-verifier-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testVerifiesEveryLibraryAndAppStateFieldAfterConversion() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        let added = Date(timeIntervalSince1970: 1_700_000_001)
        let updated = Date(timeIntervalSince1970: 1_700_000_002)
        let bytes = Data([0x00, 0x01, 0xFE, 0xFF])

        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBLibraryEntry(
            gameID: "game-a", status: "playing", isFavorite: true,
            notes: "private note", addedAt: added, updatedAt: updated
        ))
        source.insert(DBLibraryCollection(
            id: "collection-a", title: "Favorites", createdAt: added, updatedAt: updated
        ))
        source.insert(DBLibraryCollectionItem(
            id: DBLibraryCollectionItem.stableID(collectionID: "collection-a", gameID: "game-a"),
            collectionID: "collection-a", gameID: "game-a",
            sortOrder: 7, addedAt: updated
        ))
        source.insert(DBLibraryStatusEvent(
            id: "event-a", gameID: "game-a", fromStatus: nil,
            toStatus: "playing", changedAt: updated
        ))
        source.insert(DBAppState(
            key: "itchPocket.sparkLastSyncAt.v2",
            dateValue: added, updatedAt: updated
        ))
        source.insert(DBAppState(
            key: "unknown.private.key", stringValue: "secret",
            dataValue: bytes, updatedAt: updated
        ))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        try V4LegacyLibraryConverter.convert(source: source, destination: destination.mainContext)
        try V4LegacyAppStateConverter.convert(source: source, destination: destination.mainContext)

        let report = try V4MigrationPayloadVerifier.verify(
            source: source, destination: destination.mainContext
        )
        XCTAssertTrue(report.isVerified)
        XCTAssertEqual(report.library.status, .verified)
        XCTAssertEqual(report.library.verifiedRows, 4)
        XCTAssertEqual(report.library.unverifiedRows, 0)
        XCTAssertEqual(report.appState.status, .verified)
        XCTAssertEqual(report.appState.verifiedRows, 2)
        XCTAssertEqual(report.appState.unverifiedRows, 0)
        XCTAssertTrue(report.integrityDiagnostics.isEmpty)
    }

    @MainActor
    func testDetectsPayloadMutationScopeMismatchAndExtraDestinationRows() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBGame(id: "game-a", title: "Game A"))
        source.insert(DBLibraryEntry(gameID: "game-a", status: "playing", notes: "source"))
        source.insert(DBAppState(
            key: "itchPocket.sparkLastSyncAt.v2",
            stringValue: "source-value"
        ))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        try V4LegacyLibraryConverter.convert(source: source, destination: destination.mainContext)
        try V4LegacyAppStateConverter.convert(source: source, destination: destination.mainContext)

        let context = destination.mainContext
        let entry = try XCTUnwrap(context.fetch(
            FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
        ).first)
        entry.notes = "tampered"
        let state = try XCTUnwrap(context.fetch(FetchDescriptor<DBScopedAppState>()).first)
        state.scopeID = AppStateScope.appGlobal.scopeID
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: nil, gameID: "extra-game", status: "backlog"
        ))
        try context.save()

        let report = try V4MigrationPayloadVerifier.verify(source: source, destination: context)
        XCTAssertFalse(report.isVerified)
        XCTAssertEqual(report.library.status, .failed)
        XCTAssertGreaterThan(report.library.unverifiedRows, 0)
        XCTAssertEqual(report.appState.status, .failed)
        XCTAssertGreaterThan(report.appState.unverifiedRows, 0)
        XCTAssertTrue(report.integrityDiagnostics.contains(
            "migration.library.entry.payloadMismatch"
        ))
        XCTAssertTrue(report.integrityDiagnostics.contains(
            "migration.appState.payloadOrScopeMismatch"
        ))
    }

    @MainActor
    func testRejectsUncommittedContextChangesWithoutReadingThemAsVerified() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let destination = try makeV4Container()
        sourceDatabase.context.insert(DBAppState(key: "pending"))
        let report = try V4MigrationPayloadVerifier.verify(
            source: sourceDatabase.context, destination: destination.mainContext
        )
        XCTAssertFalse(report.isVerified)
        XCTAssertTrue(report.integrityDiagnostics.contains(
            "migration.verification.pendingContextChanges"
        ))
    }
}
