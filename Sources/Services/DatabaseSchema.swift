import Foundation
import SwiftData

/// V1 intentionally mirrors the twelve-model, unversioned schema shipped before
/// versioned migrations were introduced. Do not change its model list or model
/// definitions after this baseline is established.
enum ItchPocketSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            DBDeveloper.self,
            DBGame.self,
            DBLibraryEntry.self,
            DBGameUpdate.self,
            DBCalendarEvent.self,
            DBSparkMetadata.self,
            DBTranslation.self,
            DBDiscoverySnapshot.self,
            DBUpdateWatch.self,
            DBLibraryCollection.self,
            DBLibraryStatusEvent.self,
            DBAppState.self
        ]
    }
}

/// Central migration registry. Future schema versions and explicit migration
/// stages must be registered here; feature stores must never create containers.
enum ItchPocketMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ItchPocketSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
