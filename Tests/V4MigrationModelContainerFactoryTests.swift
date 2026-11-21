import XCTest
import SwiftData
@testable import itchPocket

final class V4MigrationModelContainerFactoryTests: XCTestCase {
    @MainActor
    func testSnapshotFactoryReadsV3SnapshotAndRejectsWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4ContainerFactory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = root.appendingPathComponent("source-v3.sqlite")
        let sourceSchema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let sourceConfiguration = ModelConfiguration(
            "V4ContainerFactorySource-\(UUID().uuidString)",
            schema: sourceSchema,
            url: sourceURL
        )
        let sourceContainer = try ModelContainer(
            for: sourceSchema,
            configurations: [sourceConfiguration]
        )
        sourceContainer.mainContext.insert(DBGame(id: "snapshot-game", title: "Snapshot Game"))
        try sourceContainer.mainContext.save()

        let stagingManager = V4MigrationStagingStoreManager(
            rootURL: root.appendingPathComponent("snapshots", isDirectory: true)
        )
        let snapshot = try stagingManager.createSnapshot(
            from: sourceURL,
            runID: "factory-run",
            stagingStoreID: "factory-snapshot"
        )

        let readOnlyContainer = try V4MigrationModelContainerFactory
            .openReadOnlyV3Snapshot(at: snapshot.storeURL)
        let games = try readOnlyContainer.mainContext.fetch(FetchDescriptor<DBGame>())
        XCTAssertEqual(games.map(\.id), ["snapshot-game"])

        readOnlyContainer.mainContext.insert(
            DBGame(id: "must-not-save", title: "Must Not Save")
        )
        XCTAssertThrowsError(try readOnlyContainer.mainContext.save())

        let sourceGames = try sourceContainer.mainContext.fetch(FetchDescriptor<DBGame>())
        XCTAssertEqual(Set(sourceGames.map(\.id)), ["snapshot-game"])
    }

    @MainActor
    func testCreatesFreshIndependentV4DestinationAndRejectsReuse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4ContainerDestination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationURL = root.appendingPathComponent("attempt-1/v4-staging.sqlite")

        let container = try V4MigrationModelContainerFactory
            .createEmptyV4StagingStore(at: destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<DBAccount>()), 0)
        XCTAssertEqual(
            try container.mainContext.fetchCount(
                FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
            ),
            0
        )

        XCTAssertThrowsError(
            try V4MigrationModelContainerFactory.createEmptyV4StagingStore(at: destinationURL)
        ) { error in
            XCTAssertEqual(
                error as? V4MigrationModelContainerFactory.FactoryError,
                .destinationAlreadyExists
            )
        }
    }

    @MainActor
    func testMissingSnapshotFailsClosed() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-v3-\(UUID().uuidString).sqlite")
        XCTAssertThrowsError(
            try V4MigrationModelContainerFactory.openReadOnlyV3Snapshot(at: missingURL)
        ) { error in
            XCTAssertEqual(
                error as? V4MigrationModelContainerFactory.FactoryError,
                .sourceSnapshotMissing
            )
        }
    }
}
