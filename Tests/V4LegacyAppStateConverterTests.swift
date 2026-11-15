import XCTest
import SwiftData
@testable import itchPocket

final class V4LegacyAppStateConverterTests: XCTestCase {
    @MainActor
    private func makeV4Container() throws -> ModelContainer {
        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "itchPocket-v4-appstate-migration-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    @MainActor
    func testCopiesKnownDeviceAndAppGlobalKeysButQuarantinesAccountAndUnknownKeys() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])

        source.insert(DBAppState(
            key: "itchPocket.sparkLastSyncAt.v2",
            dateValue: date,
            updatedAt: date
        ))
        source.insert(DBAppState(
            key: "itchPocket.avatarResolver.version",
            stringValue: "v3",
            updatedAt: date
        ))
        source.insert(DBAppState(
            key: "devlogSync.lastDate",
            dateValue: date,
            updatedAt: date
        ))
        source.insert(DBAppState(
            key: "unknown.private.payload",
            dataValue: payload,
            updatedAt: date
        ))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        let report = try V4LegacyAppStateConverter.convert(
            source: source, destination: destination.mainContext
        )

        XCTAssertEqual(report.totalRows, 4)
        XCTAssertEqual(report.deviceScopedRows, 1)
        XCTAssertEqual(report.appGlobalRows, 1)
        XCTAssertEqual(report.quarantinedRows, 2)
        XCTAssertEqual(report.inventoryDigest.count, 64)

        let rows = try destination.mainContext.fetch(FetchDescriptor<DBScopedAppState>())
        XCTAssertEqual(rows.count, 4)
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.logicalKey, $0) })

        let device = try XCTUnwrap(byKey["itchPocket.sparkLastSyncAt.v2"])
        XCTAssertEqual(device.scopeID, AppStateScope.device.scopeID)
        XCTAssertEqual(device.dateValue, date)

        let global = try XCTUnwrap(byKey["itchPocket.avatarResolver.version"])
        XCTAssertEqual(global.scopeID, AppStateScope.appGlobal.scopeID)
        XCTAssertEqual(global.stringValue, "v3")

        let accountState = try XCTUnwrap(byKey["devlogSync.lastDate"])
        XCTAssertEqual(accountState.scopeID, AppStateScope.legacyUnclassified.scopeID)
        XCTAssertEqual(accountState.dateValue, date)

        let unknown = try XCTUnwrap(byKey["unknown.private.payload"])
        XCTAssertEqual(unknown.scopeID, AppStateScope.legacyUnclassified.scopeID)
        XCTAssertEqual(unknown.dataValue, payload)

        // V3 remains unchanged and account-scoped keys are never assigned to
        // whichever itch account happens to be active during migration.
        XCTAssertEqual(try source.fetchCount(FetchDescriptor<DBAppState>()), 4)
        XCTAssertFalse(rows.contains { $0.scopeID == "itch:1" || $0.scopeID == "patreon:1" })
    }

    @MainActor
    func testRejectsNonEmptyDestinationAndLeavesExistingRowsUntouched() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBAppState(key: "new.key", stringValue: "value"))
        try sourceDatabase.save()

        let destination = try makeV4Container()
        let context = destination.mainContext
        context.insert(DBScopedAppState(
            scopeID: AppStateScope.device.scopeID,
            logicalKey: "existing.key",
            stringValue: "keep"
        ))
        try context.save()

        XCTAssertThrowsError(try V4LegacyAppStateConverter.convert(
            source: source, destination: context
        )) { error in
            XCTAssertEqual(
                error as? V4LegacyAppStateConverter.ConversionError,
                .destinationNotEmpty
            )
        }
        let rows = try context.fetch(FetchDescriptor<DBScopedAppState>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.logicalKey, "existing.key")
    }

    @MainActor
    func testRejectsPendingChangesInEitherContext() throws {
        let sourceDatabase = try AppDatabase(inMemory: true)
        let source = sourceDatabase.context
        source.insert(DBAppState(key: "pending.source"))

        let destination = try makeV4Container()
        XCTAssertThrowsError(try V4LegacyAppStateConverter.convert(
            source: source, destination: destination.mainContext
        )) { error in
            XCTAssertEqual(
                error as? V4LegacyAppStateConverter.ConversionError,
                .sourceHasPendingChanges
            )
        }

        try sourceDatabase.save()
        destination.mainContext.insert(DBScopedAppState(
            scopeID: AppStateScope.device.scopeID,
            logicalKey: "pending.destination"
        ))
        XCTAssertThrowsError(try V4LegacyAppStateConverter.convert(
            source: source, destination: destination.mainContext
        )) { error in
            XCTAssertEqual(
                error as? V4LegacyAppStateConverter.ConversionError,
                .destinationHasPendingChanges
            )
        }
    }
}
