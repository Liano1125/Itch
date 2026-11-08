import Foundation
import SwiftData

/// Frozen snapshot of the twelve-model unversioned store shipped before
/// versioned migrations. Never edit these model declarations after release.
enum ItchPocketSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            DBDeveloper.self, DBGame.self, DBLibraryEntry.self, DBGameUpdate.self,
            DBCalendarEvent.self, DBSparkMetadata.self, DBTranslation.self,
            DBDiscoverySnapshot.self, DBUpdateWatch.self, DBLibraryCollection.self,
            DBLibraryStatusEvent.self, DBAppState.self
        ]
    }

    @Model final class DBDeveloper {
        @Attribute(.unique) var id: String
        var name: String
        var profileURL: String?
        var patreonURL: String?
        var discordURL: String?
        var avatarURL: String?
        var avatarSource: String?
        var avatarResolvedAt: Date?
        var updatedAt: Date
        init() {
            self.id = ""
            self.name = ""
            self.profileURL = nil
            self.patreonURL = nil
            self.discordURL = nil
            self.avatarURL = nil
            self.avatarSource = nil
            self.avatarResolvedAt = nil
            self.updatedAt = Date.distantPast
        }
    }
    @Model final class DBGame {
        @Attribute(.unique) var id: String
        var title: String
        var gameURL: String?
        var coverURL: String?
        var descriptionText: String?
        var galleryURLs: [String]
        var discoveryTagsData: Data?
        var engine: String?
        var developerID: String?
        var updatedAt: Date
        init() {
            self.id = ""
            self.title = ""
            self.gameURL = nil
            self.coverURL = nil
            self.descriptionText = nil
            self.galleryURLs = []
            self.discoveryTagsData = nil
            self.engine = nil
            self.developerID = nil
            self.updatedAt = Date.distantPast
        }
    }
    @Model final class DBLibraryEntry {
        @Attribute(.unique) var gameID: String
        var status: String
        var isFavorite: Bool
        var notes: String
        var addedAt: Date
        var updatedAt: Date
        init() {
            self.gameID = ""
            self.status = ""
            self.isFavorite = false
            self.notes = ""
            self.addedAt = Date.distantPast
            self.updatedAt = Date.distantPast
        }
    }
    @Model final class DBGameUpdate {
        @Attribute(.unique) var id: String
        var gameID: String
        var title: String?
        var summary: String
        var detectedAt: Date
        var publishedAt: Date?
        var url: String?
        var sourceID: String?
        var isHistorical: Bool
        init() {
            self.id = ""
            self.gameID = ""
            self.title = nil
            self.summary = ""
            self.detectedAt = Date.distantPast
            self.publishedAt = nil
            self.url = nil
            self.sourceID = nil
            self.isHistorical = false
        }
    }
    @Model final class DBCalendarEvent {
        @Attribute(.unique) var id: String
        var gameID: String
        var title: String?
        var date: Date?
        var kind: String
        var reminderEnabled: Bool
        var reminderMinutes: Int
        var notes: String?
        var sourceFingerprint: String?
        var sourceUpdateID: String?
        init() {
            self.id = ""
            self.gameID = ""
            self.title = nil
            self.date = nil
            self.kind = ""
            self.reminderEnabled = false
            self.reminderMinutes = 0
            self.notes = nil
            self.sourceFingerprint = nil
            self.sourceUpdateID = nil
        }
    }
    @Model final class DBSparkMetadata {
        @Attribute(.unique) var gameID: String
        var runtimeSeconds: Double
        var lastSaveAt: Date?
        var renpyVersion: String?
        var saveCount: Int?
        var scannedAt: Date
        init() {
            self.gameID = ""
            self.runtimeSeconds = 0.0
            self.lastSaveAt = nil
            self.renpyVersion = nil
            self.saveCount = nil
            self.scannedAt = Date.distantPast
        }
    }
    @Model final class DBTranslation {
        @Attribute(.unique) var cacheKey: String
        var scope: String
        var sourceHash: String
        var sourceText: String
        var targetLanguage: String
        var translatedText: String
        var updatedAt: Date
        init() {
            self.cacheKey = ""
            self.scope = ""
            self.sourceHash = ""
            self.sourceText = ""
            self.targetLanguage = ""
            self.translatedText = ""
            self.updatedAt = Date.distantPast
        }
    }
    @Model final class DBDiscoverySnapshot {
        @Attribute(.unique) var key: String
        var payload: Data
        var fetchedAt: Date
        var expiresAt: Date
        init() {
            self.key = ""
            self.payload = Data()
            self.fetchedAt = Date.distantPast
            self.expiresAt = Date.distantPast
        }
    }
    @Model final class DBUpdateWatch {
        @Attribute(.unique) var gameID: String
        var entityTag: String?
        var lastModified: String?
        var contentHash: String?
        var lastCheckedAt: Date?
        var hasBaseline: Bool
        var isEnabled: Bool
        init() {
            self.gameID = ""
            self.entityTag = nil
            self.lastModified = nil
            self.contentHash = nil
            self.lastCheckedAt = nil
            self.hasBaseline = false
            self.isEnabled = false
        }
    }
    @Model final class DBLibraryCollection {
        @Attribute(.unique) var id: String
        var title: String
        var gameIDs: [String]
        var createdAt: Date
        var updatedAt: Date
        init() {
            self.id = ""
            self.title = ""
            self.gameIDs = []
            self.createdAt = Date.distantPast
            self.updatedAt = Date.distantPast
        }
    }
    @Model final class DBLibraryStatusEvent {
        @Attribute(.unique) var id: String
        var gameID: String
        var fromStatus: String?
        var toStatus: String
        var changedAt: Date
        init() {
            self.id = ""
            self.gameID = ""
            self.fromStatus = nil
            self.toStatus = ""
            self.changedAt = Date.distantPast
        }
    }
    @Model final class DBAppState {
        @Attribute(.unique) var key: String
        var stringValue: String?
        var dateValue: Date?
        var dataValue: Data?
        var updatedAt: Date
        init() {
            self.key = ""
            self.stringValue = nil
            self.dateValue = nil
            self.dataValue = nil
            self.updatedAt = Date.distantPast
        }
    }
}

/// V2 uses the app's current model types plus normalized detail/collection
/// records. Legacy columns remain for a later, separately verified V3 cutover.
enum ItchPocketSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            DBDeveloper.self, DBGame.self, DBLibraryEntry.self, DBGameUpdate.self,
            DBCalendarEvent.self, DBSparkMetadata.self, DBTranslation.self,
            DBDiscoverySnapshot.self, DBUpdateWatch.self, DBLibraryCollection.self,
            DBLibraryStatusEvent.self, DBAppState.self, DBGameDetail.self,
            DBLibraryCollectionItem.self
        ]
    }
}

enum ItchPocketMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [ItchPocketSchemaV1.self, ItchPocketSchemaV2.self]
    }

    static var stages: [MigrationStage] { [migrateV1toV2] }

    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: ItchPocketSchemaV1.self,
        toVersion: ItchPocketSchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
            let games = try context.fetch(FetchDescriptor<DBGame>())
            var titlesByGameID: [String: String] = [:]
            titlesByGameID.reserveCapacity(games.count)

            for game in games {
                titlesByGameID[game.id] = game.title
                let hasSavedDetails = game.descriptionText != nil
                    || !game.galleryURLs.isEmpty
                    || game.discoveryTagsData != nil
                guard hasSavedDetails else { continue }

                context.insert(DBGameDetail(
                    gameID: game.id,
                    descriptionText: game.descriptionText,
                    galleryURLs: game.galleryURLs,
                    discoveryTagsData: game.discoveryTagsData,
                    fetchedAt: nil,
                    isComplete: false
                ))
            }

            let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
            for collection in collections {
                var seen = Set<String>()
                for (index, gameID) in collection.gameIDs.enumerated() {
                    guard seen.insert(gameID).inserted else { continue }
                    context.insert(DBLibraryCollectionItem(
                        id: DBLibraryCollectionItem.stableID(
                            collectionID: collection.id,
                            gameID: gameID
                        ),
                        collectionID: collection.id,
                        gameID: gameID,
                        sortOrder: index,
                        addedAt: collection.createdAt
                    ))
                }
            }

            let events = try context.fetch(FetchDescriptor<DBCalendarEvent>())
            for event in events {
                event.gameTitleSnapshot = titlesByGameID[event.gameID]
            }
            try context.save()
        }
    )
}
