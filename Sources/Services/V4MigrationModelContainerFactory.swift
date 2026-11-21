import Foundation
import SwiftData

/// Opens the immutable V3 input snapshot and creates a separate empty V4
/// destination. This factory never receives or resolves the production store URL.
@MainActor
enum V4MigrationModelContainerFactory {
    enum FactoryError: Error, Equatable {
        case sourceSnapshotMissing
        case destinationAlreadyExists
    }

    /// The source configuration disallows all SwiftData saves. Callers must
    /// still ensure the source snapshot was created from a coordinated SQLite
    /// online backup and must never pass the live production V3 URL here.
    static func openReadOnlyV3Snapshot(at snapshotURL: URL) throws -> ModelContainer {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            throw FactoryError.sourceSnapshotMissing
        }

        let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
        let configuration = ModelConfiguration(
            "V4MigrationReadOnlyV3Snapshot-\(UUID().uuidString)",
            schema: schema,
            url: snapshotURL,
            allowsSave: false
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// Creates a brand-new V4 store at this attempt's disposable staging URL.
    /// Existing files are rejected; a partially converted store must never be
    /// reopened and reused by a retry.
    static func createEmptyV4StagingStore(at stagingURL: URL) throws -> ModelContainer {
        guard !FileManager.default.fileExists(atPath: stagingURL.path) else {
            throw FactoryError.destinationAlreadyExists
        }

        try FileManager.default.createDirectory(
            at: stagingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let schema = Schema(versionedSchema: ItchPocketSchemaV4.self)
        let configuration = ModelConfiguration(
            "V4MigrationDestination-\(UUID().uuidString)",
            schema: schema,
            url: stagingURL
        )
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
