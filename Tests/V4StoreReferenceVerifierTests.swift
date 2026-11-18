import XCTest
import SwiftData
@testable import itchPocket

final class V4StoreReferenceVerifierTests: XCTestCase {
    @MainActor
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "v4-reference-verifier-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testAcceptsConsistentAccountScopedLibraryAndCalendarReferences() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let account = DBAccount(itchUserID: 801, username: "account")
        context.insert(account)
        context.insert(DBGame(id: "game-1", title: "Game"))
        context.insert(DBSparkMetadata(gameID: "game-1", runtimeSeconds: 12, scannedAt: Date(timeIntervalSince1970: 10)))
        let collection = ItchPocketSchemaV4.DBLibraryCollection(
            accountID: account.id, collectionKey: "favorites", title: "Favorites"
        )
        let sourceEvent = DBCalendarSourceEvent(
            sourceFingerprint: "source-1", gameID: "game-1", kind: "release"
        )
        context.insert(collection)
        context.insert(sourceEvent)
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: account.id, gameID: "game-1", status: "playing"
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryCollectionItem(
            accountID: account.id, collectionKey: "favorites", gameID: "game-1", sortOrder: 0
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryStatusEvent(
            accountID: account.id, eventKey: "event-1", gameID: "game-1",
            fromStatus: nil, toStatus: "playing"
        ))
        context.insert(DBScopedAppState(scopeID: "device", logicalKey: "launchTab"))
        context.insert(DBAccountCalendarEvent(
            accountID: account.id, eventKey: "custom-1", gameID: "game-1", kind: "custom"
        ))
        context.insert(DBAccountCalendarOverlay(
            accountID: account.id, sourceEventID: sourceEvent.id
        ))
        context.insert(ItchPocketSchemaV4.DBLibraryEntry(
            accountID: nil, gameID: "game-1", status: "backlog"
        ))
        try context.save()

        let report = try V4StoreReferenceVerifier.verify(context: context)
        XCTAssertTrue(report.isValid, "\(report.diagnostics)")
        XCTAssertGreaterThan(report.checksPerformed, 0)
        XCTAssertTrue(report.diagnostics.isEmpty)
    }

    @MainActor
    func testRejectsUnknownAccountsMissingReferencesAndForgedStableIDs() throws {
        let container = try makeContainer()
        let context = container.mainContext
        context.insert(DBAccount(itchUserID: 802, username: "known"))
        context.insert(DBGame(id: "game-1", title: "Game"))

        let orphanEntry = ItchPocketSchemaV4.DBLibraryEntry(
            accountID: "itch:999", gameID: "missing-game", status: "playing"
        )
        let orphanItem = ItchPocketSchemaV4.DBLibraryCollectionItem(
            accountID: "itch:999", collectionKey: "missing-list",
            gameID: "missing-game", sortOrder: 0
        )
        let forgedState = DBScopedAppState(scopeID: "device", logicalKey: "theme")
        forgedState.id = "forged-id"
        context.insert(orphanEntry)
        context.insert(orphanItem)
        context.insert(forgedState)
        context.insert(DBAccountCalendarEvent(
            accountID: "itch:999", eventKey: "orphan", gameID: "missing-game", kind: "custom"
        ))
        context.insert(DBSparkMetadata(gameID: "missing-game", runtimeSeconds: 1))
        try context.save()

        let report = try V4StoreReferenceVerifier.verify(context: context)
        XCTAssertFalse(report.isValid)
        XCTAssertTrue(report.diagnostics.contains("v4.libraryEntry.unknownAccount"))
        XCTAssertTrue(report.diagnostics.contains("v4.libraryEntry.missingGame"))
        XCTAssertTrue(report.diagnostics.contains("v4.collectionItem.missingCollection"))
        XCTAssertTrue(report.diagnostics.contains("v4.appState.stableIdentityMismatch"))
        XCTAssertTrue(report.diagnostics.contains("v4.accountCalendarEvent.unknownAccount"))
        XCTAssertTrue(report.diagnostics.contains("v4.sparkMetadata.missingGame"))
    }

    @MainActor
    func testRejectsUncommittedChanges() throws {
        let container = try makeContainer()
        container.mainContext.insert(DBAccount(itchUserID: 803, username: "pending"))
        let report = try V4StoreReferenceVerifier.verify(context: container.mainContext)
        XCTAssertFalse(report.isValid)
        XCTAssertEqual(report.diagnostics, ["v4.references.pendingContextChanges"])
    }
}
