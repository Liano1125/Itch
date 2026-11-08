import Foundation
import SwiftData

/// Performs a one-time, copy-based bootstrap from the original unversioned
/// store into a separate V2 store. The source store is never modified or moved.
@MainActor
enum LegacyStoreBootstrap {
    static let legacyConfigurationName = "itchPocket"
    static let v2ConfigurationName = "itchPocket-v2"
    static let v2DirectoryName = "itchPocket-v2"
    static let v2StoreFileName = "itchPocket-v2.store"
    static let stagingDirectoryName = "itchPocket-v2.staging"

    enum BootstrapError: LocalizedError {
        case incompleteDestination(URL)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .incompleteDestination(let url):
                return "The V2 database directory exists but its store is missing: \(url.path)"
            case .validationFailed(let detail):
                return "The V2 database copy did not pass integrity validation: \(detail)"
            }
        }
    }

    struct MigrationCounts: Equatable {
        let developers: Int
        let games: Int
        let libraryEntries: Int
        let updates: Int
        let calendarEvents: Int
        let sparkMetadata: Int
        let translations: Int
        let discoverySnapshots: Int
        let updateWatches: Int
        let collections: Int
        let libraryStatusEvents: Int
        let appStates: Int
        let gameDetails: Int
        let collectionItems: Int
    }

    /// Returns the V2 store URL. A completed V2 store always wins; an existing
    /// legacy store is copied to a staging directory, validated, then promoted
    /// by a same-volume directory move. The legacy file remains untouched.
    static func prepareStore(
        legacyStoreURL: URL,
        finalDirectory: URL,
        beforePromotion: (() throws -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let finalStoreURL = finalDirectory.appendingPathComponent(v2StoreFileName)

        if fileManager.fileExists(atPath: finalDirectory.path) {
            guard fileManager.fileExists(atPath: finalStoreURL.path) else {
                throw BootstrapError.incompleteDestination(finalStoreURL)
            }
            return finalStoreURL
        }

        try fileManager.createDirectory(
            at: finalDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let stagingDirectory = finalDirectory.deletingLastPathComponent()
            .appendingPathComponent(stagingDirectoryName, isDirectory: true)

        // A previous process may have been terminated while building the
        // staging copy. It is disposable because the source is authoritative.
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingStoreURL = stagingDirectory.appendingPathComponent(v2StoreFileName)

        do {
            if fileManager.fileExists(atPath: legacyStoreURL.path) {
                _ = try copyLegacyStore(
                    from: legacyStoreURL,
                    to: stagingStoreURL
                )
                try beforePromotion?()
            }

            // For a new install there is no legacy store. Create an empty V2
            // store in staging and promote it through the same atomic path.
            if !fileManager.fileExists(atPath: stagingStoreURL.path) {
                let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
                let configuration = ModelConfiguration(
                    v2ConfigurationName,
                    schema: schema,
                    url: stagingStoreURL
                )
                let container = try ModelContainer(for: schema, configurations: [configuration])
                try container.mainContext.save()
            }

            // The store container must be released before the containing
            // directory is renamed. Validate/opening is completed in helpers.
            try validateV2Store(at: stagingStoreURL)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            return finalStoreURL
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func copyLegacyStore(from sourceURL: URL, to destinationURL: URL) throws -> MigrationCounts {
        let sourceSchema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let sourceConfiguration = ModelConfiguration(
            legacyConfigurationName,
            schema: sourceSchema,
            url: sourceURL,
            allowsSave: false
        )
        let sourceContainer = try ModelContainer(for: sourceSchema, configurations: [sourceConfiguration])
        let sourceContext = sourceContainer.mainContext

        let developers = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBDeveloper>())
        let games = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBGame>())
        let libraryEntries = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryEntry>())
        let updates = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBGameUpdate>())
        let calendarEvents = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBCalendarEvent>())
        let sparkMetadata = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBSparkMetadata>())
        let translations = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBTranslation>())
        let discoverySnapshots = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBDiscoverySnapshot>())
        let updateWatches = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBUpdateWatch>())
        let collections = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryCollection>())
        let statusEvents = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBLibraryStatusEvent>())
        let appStates = try sourceContext.fetch(FetchDescriptor<ItchPocketSchemaV1.DBAppState>())

        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let destinationConfiguration = ModelConfiguration(
            v2ConfigurationName,
            schema: schema,
            url: destinationURL
        )
        let destinationContainer = try ModelContainer(for: schema, configurations: [destinationConfiguration])
        let destinationContext = destinationContainer.mainContext

        for item in developers {
            destinationContext.insert(DBDeveloper(
                id: item.id,
                name: item.name,
                profileURL: item.profileURL,
                patreonURL: item.patreonURL,
                discordURL: item.discordURL,
                avatarURL: item.avatarURL,
                avatarSource: item.avatarSource,
                avatarResolvedAt: item.avatarResolvedAt,
                updatedAt: item.updatedAt
            ))
        }

        var titlesByGameID: [String: String] = [:]
        titlesByGameID.reserveCapacity(games.count)
        var detailCount = 0
        for item in games {
            titlesByGameID[item.id] = item.title
            destinationContext.insert(DBGame(
                id: item.id,
                title: item.title,
                gameURL: item.gameURL,
                coverURL: item.coverURL,
                descriptionText: item.descriptionText,
                galleryURLs: item.galleryURLs,
                discoveryTagsData: item.discoveryTagsData,
                engine: item.engine,
                developerID: item.developerID,
                updatedAt: item.updatedAt
            ))

            let hasDetails = item.descriptionText != nil
                || !item.galleryURLs.isEmpty
                || item.discoveryTagsData != nil
            if hasDetails {
                detailCount += 1
                destinationContext.insert(DBGameDetail(
                    gameID: item.id,
                    descriptionText: item.descriptionText,
                    galleryURLs: item.galleryURLs,
                    discoveryTagsData: item.discoveryTagsData,
                    fetchedAt: nil,
                    isComplete: false
                ))
            }
        }

        for item in libraryEntries {
            destinationContext.insert(DBLibraryEntry(
                gameID: item.gameID,
                status: item.status,
                isFavorite: item.isFavorite,
                notes: item.notes,
                addedAt: item.addedAt,
                updatedAt: item.updatedAt
            ))
        }

        for item in updates {
            destinationContext.insert(DBGameUpdate(
                id: item.id,
                gameID: item.gameID,
                title: item.title,
                summary: item.summary,
                detectedAt: item.detectedAt,
                publishedAt: item.publishedAt,
                url: item.url,
                sourceID: item.sourceID,
                isHistorical: item.isHistorical
            ))
        }

        for item in calendarEvents {
            destinationContext.insert(DBCalendarEvent(
                id: item.id,
                gameID: item.gameID,
                title: item.title,
                date: item.date,
                kind: item.kind,
                reminderEnabled: item.reminderEnabled,
                reminderMinutes: item.reminderMinutes,
                notes: item.notes,
                sourceFingerprint: item.sourceFingerprint,
                sourceUpdateID: item.sourceUpdateID,
                gameTitleSnapshot: titlesByGameID[item.gameID]
            ))
        }

        for item in sparkMetadata {
            destinationContext.insert(DBSparkMetadata(
                gameID: item.gameID,
                runtimeSeconds: item.runtimeSeconds,
                lastSaveAt: item.lastSaveAt,
                renpyVersion: item.renpyVersion,
                saveCount: item.saveCount,
                scannedAt: item.scannedAt
            ))
        }

        for item in translations {
            destinationContext.insert(DBTranslation(
                cacheKey: item.cacheKey,
                scope: item.scope,
                sourceHash: item.sourceHash,
                sourceText: item.sourceText,
                targetLanguage: item.targetLanguage,
                translatedText: item.translatedText,
                updatedAt: item.updatedAt
            ))
        }

        for item in discoverySnapshots {
            destinationContext.insert(DBDiscoverySnapshot(
                key: item.key,
                payload: item.payload,
                fetchedAt: item.fetchedAt,
                expiresAt: item.expiresAt
            ))
        }

        for item in updateWatches {
            destinationContext.insert(DBUpdateWatch(
                gameID: item.gameID,
                entityTag: item.entityTag,
                lastModified: item.lastModified,
                contentHash: item.contentHash,
                lastCheckedAt: item.lastCheckedAt,
                hasBaseline: item.hasBaseline,
                isEnabled: item.isEnabled
            ))
        }

        var collectionItemCount = 0
        for collection in collections {
            destinationContext.insert(DBLibraryCollection(
                id: collection.id,
                title: collection.title,
                gameIDs: collection.gameIDs,
                createdAt: collection.createdAt,
                updatedAt: collection.updatedAt
            ))

            var seen = Set<String>()
            for (index, gameID) in collection.gameIDs.enumerated() where seen.insert(gameID).inserted {
                collectionItemCount += 1
                destinationContext.insert(DBLibraryCollectionItem(
                    id: DBLibraryCollectionItem.stableID(collectionID: collection.id, gameID: gameID),
                    collectionID: collection.id,
                    gameID: gameID,
                    sortOrder: index,
                    addedAt: collection.createdAt
                ))
            }
        }

        for item in statusEvents {
            destinationContext.insert(DBLibraryStatusEvent(
                id: item.id,
                gameID: item.gameID,
                fromStatus: item.fromStatus,
                toStatus: item.toStatus,
                changedAt: item.changedAt
            ))
        }

        for item in appStates {
            destinationContext.insert(DBAppState(
                key: item.key,
                stringValue: item.stringValue,
                dateValue: item.dateValue,
                dataValue: item.dataValue,
                updatedAt: item.updatedAt
            ))
        }

        try destinationContext.save()

        let expected = MigrationCounts(
            developers: developers.count,
            games: games.count,
            libraryEntries: libraryEntries.count,
            updates: updates.count,
            calendarEvents: calendarEvents.count,
            sparkMetadata: sparkMetadata.count,
            translations: translations.count,
            discoverySnapshots: discoverySnapshots.count,
            updateWatches: updateWatches.count,
            collections: collections.count,
            libraryStatusEvents: statusEvents.count,
            appStates: appStates.count,
            gameDetails: detailCount,
            collectionItems: collectionItemCount
        )
        try validate(context: destinationContext, expected: expected)
        return expected
    }

    private static func validateV2Store(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration(v2ConfigurationName, schema: schema, url: storeURL)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext

        // A fresh store is valid when all tables are readable, even when empty.
        _ = try context.fetchCount(FetchDescriptor<DBDeveloper>())
        _ = try context.fetchCount(FetchDescriptor<DBGame>())
        _ = try context.fetchCount(FetchDescriptor<DBLibraryEntry>())
        _ = try context.fetchCount(FetchDescriptor<DBGameUpdate>())
        _ = try context.fetchCount(FetchDescriptor<DBCalendarEvent>())
        _ = try context.fetchCount(FetchDescriptor<DBSparkMetadata>())
        _ = try context.fetchCount(FetchDescriptor<DBTranslation>())
        _ = try context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>())
        _ = try context.fetchCount(FetchDescriptor<DBUpdateWatch>())
        _ = try context.fetchCount(FetchDescriptor<DBLibraryCollection>())
        _ = try context.fetchCount(FetchDescriptor<DBLibraryStatusEvent>())
        _ = try context.fetchCount(FetchDescriptor<DBAppState>())
        _ = try context.fetchCount(FetchDescriptor<DBGameDetail>())
        _ = try context.fetchCount(FetchDescriptor<DBLibraryCollectionItem>())
    }

    private static func validate(context: ModelContext, expected: MigrationCounts) throws {
        let actual = MigrationCounts(
            developers: try context.fetchCount(FetchDescriptor<DBDeveloper>()),
            games: try context.fetchCount(FetchDescriptor<DBGame>()),
            libraryEntries: try context.fetchCount(FetchDescriptor<DBLibraryEntry>()),
            updates: try context.fetchCount(FetchDescriptor<DBGameUpdate>()),
            calendarEvents: try context.fetchCount(FetchDescriptor<DBCalendarEvent>()),
            sparkMetadata: try context.fetchCount(FetchDescriptor<DBSparkMetadata>()),
            translations: try context.fetchCount(FetchDescriptor<DBTranslation>()),
            discoverySnapshots: try context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>()),
            updateWatches: try context.fetchCount(FetchDescriptor<DBUpdateWatch>()),
            collections: try context.fetchCount(FetchDescriptor<DBLibraryCollection>()),
            libraryStatusEvents: try context.fetchCount(FetchDescriptor<DBLibraryStatusEvent>()),
            appStates: try context.fetchCount(FetchDescriptor<DBAppState>()),
            gameDetails: try context.fetchCount(FetchDescriptor<DBGameDetail>()),
            collectionItems: try context.fetchCount(FetchDescriptor<DBLibraryCollectionItem>())
        )
        guard actual == expected else {
            throw BootstrapError.validationFailed("Expected \(expected), received \(actual).")
        }

        let games = try context.fetch(FetchDescriptor<DBGame>())
        let titles = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0.title) })
        for event in try context.fetch(FetchDescriptor<DBCalendarEvent>()) {
            guard event.gameTitleSnapshot == titles[event.gameID] else {
                throw BootstrapError.validationFailed("Calendar title snapshot mismatch for event \(event.id).")
            }
        }

        let details = try context.fetch(FetchDescriptor<DBGameDetail>())
        for detail in details {
            guard detail.fetchedAt == nil, !detail.isComplete else {
                throw BootstrapError.validationFailed("Legacy detail metadata was incorrectly marked fresh for game \(detail.gameID).")
            }
        }

        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        for collection in collections {
            let expectedIDs = collection.gameIDs.enumerated().reduce(into: [(Int, String)]()) { result, pair in
                if !result.contains(where: { $0.1 == pair.element }) {
                    result.append((pair.offset, pair.element))
                }
            }
            let actualItems = items.filter { $0.collectionID == collection.id }.sorted { $0.sortOrder < $1.sortOrder }
            guard actualItems.map(\.gameID) == expectedIDs.map(\.1),
                  actualItems.map(\.sortOrder) == expectedIDs.map(\.0) else {
                throw BootstrapError.validationFailed("Collection membership order mismatch for collection \(collection.id).")
            }
        }
    }
}
