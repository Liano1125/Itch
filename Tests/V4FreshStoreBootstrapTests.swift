import XCTest
import SwiftData
@testable import itchPocket

final class V4FreshStoreBootstrapTests: XCTestCase {
    @MainActor
    func testCreatesEmptyV4StoreWithoutReadingOrChangingLegacyV3Store() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4FreshBootstrap-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let legacyURL = root.appendingPathComponent("legacy-v3.sqlite")
        let legacySchema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let legacyConfiguration = ModelConfiguration(
            "V4FreshBootstrapLegacyFixture-\(UUID().uuidString)",
            schema: legacySchema,
            url: legacyURL
        )
        let legacyContainer = try ModelContainer(
            for: legacySchema,
            configurations: [legacyConfiguration]
        )
        legacyContainer.mainContext.insert(
            DBGame(id: "legacy-game", title: "Must Not Be Imported")
        )
        try legacyContainer.mainContext.save()

        let freshStoreURL = try V4FreshStoreBootstrap.prepareStore(
            in: support
        )

        XCTAssertEqual(
            freshStoreURL,
            support
                .appendingPathComponent(V4FreshStoreBootstrap.directoryName, isDirectory: true)
                .appendingPathComponent(V4FreshStoreBootstrap.storeFileName)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshStoreURL.path))

        let freshSchema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let freshConfiguration = ModelConfiguration(
            "V4FreshBootstrapReadback-\(UUID().uuidString)",
            schema: freshSchema,
            url: freshStoreURL,
            allowsSave: false
        )
        let freshContainer = try ModelContainer(
            for: freshSchema,
            configurations: [freshConfiguration]
        )

        XCTAssertEqual(try freshContainer.mainContext.fetchCount(FetchDescriptor<DBAccount>()), 0)
        XCTAssertEqual(try freshContainer.mainContext.fetchCount(FetchDescriptor<DBGame>()), 0)
        XCTAssertEqual(
            try freshContainer.mainContext.fetchCount(
                FetchDescriptor<ItchPocketSchemaV4.DBLibraryEntry>()
            ),
            0
        )

        let legacyGames = try legacyContainer.mainContext.fetch(FetchDescriptor<DBGame>())
        XCTAssertEqual(legacyGames.map(\.id), ["legacy-game"])
    }

    @MainActor
    func testRepeatedPreparationReusesValidatedV4Store() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4FreshBootstrapReuse-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let first = try V4FreshStoreBootstrap.prepareStore(in: support)
        let second = try V4FreshStoreBootstrap.prepareStore(in: support)

        XCTAssertEqual(first.standardizedFileURL, second.standardizedFileURL)
        let stagingDirectories = try FileManager.default.contentsOfDirectory(
            at: support,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { $0.lastPathComponent.hasPrefix("itchPocket-v4.staging-") }
        XCTAssertTrue(stagingDirectories.isEmpty)
    }

    @MainActor
    func testInvalidExistingV4DirectoryIsQuarantinedInsteadOfDeleted() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("V4FreshBootstrapQuarantine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let invalidDirectory = support.appendingPathComponent(
            V4FreshStoreBootstrap.directoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let marker = invalidDirectory.appendingPathComponent("keep-for-diagnostics.txt")
        try Data("preserve".utf8).write(to: marker)

        let newStore = try V4FreshStoreBootstrap.prepareStore(in: support)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newStore.path))

        let entries = try FileManager.default.contentsOfDirectory(
            at: support,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let quarantine = try XCTUnwrap(
            entries.first { $0.lastPathComponent.hasPrefix("itchPocket-v4.quarantine-") }
        )
        let preservedMarker = quarantine.appendingPathComponent("keep-for-diagnostics.txt")
        XCTAssertEqual(try String(contentsOf: preservedMarker, encoding: .utf8), "preserve")
    }
}
