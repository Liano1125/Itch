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
    static let migrationReceiptFileName = "itchPocket-v2.migration.json"
    static let bootstrapMarkerFileName = "itchPocket-v2.bootstrap.json"
    private static let migrationReceiptSchemaVersion = "2.0.0"

    private struct BootstrapMarker: Codable {
        let schemaVersion: String
        let sourceWasLegacy: Bool
        let initializedAt: Date
    }

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

    struct MigrationCounts: Codable, Equatable {
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

        static let zero = MigrationCounts(
            developers: 0, games: 0, libraryEntries: 0, updates: 0,
            calendarEvents: 0, sparkMetadata: 0, translations: 0,
            discoverySnapshots: 0, updateWatches: 0, collections: 0,
            libraryStatusEvents: 0, appStates: 0, gameDetails: 0,
            collectionItems: 0
        )
    }

    private struct MigrationReceipt: Codable, Equatable {
        let schemaVersion: String
        let counts: MigrationCounts
        let completedAt: Date
    }

    /// Returns the V2 store URL. A completed V2 store always wins; an existing
    /// legacy store is copied to a staging directory, validated, then promoted
    /// by a same-volume directory move. The legacy file remains untouched.
    static func prepareStore(
        legacyStoreURL: URL,
        finalDirectory: URL,
        beforePromotion: (() throws -> Void)? = nil,
        afterPromotion: (() throws -> Void)? = nil,
        recoverInvalidExistingV2: Bool = false
    ) throws -> URL {
        let fileManager = FileManager.default
        let parentDirectory = finalDirectory.deletingLastPathComponent()
        let finalStoreURL = finalDirectory.appendingPathComponent(v2StoreFileName)
        let markerURL = parentDirectory.appendingPathComponent(bootstrapMarkerFileName)
        let hasBootstrapMarker = fileManager.fileExists(atPath: markerURL.path)
        let hasLegacyStore = fileManager.fileExists(atPath: legacyStoreURL.path)

        // Once V2 has been promoted, the legacy store is only a migration-time
        // snapshot. Never silently recreate a missing V2 database from that
        // stale snapshot. Recovery from the legacy snapshot requires an
        // explicit user-confirmed action in the recovery UI.
        if hasBootstrapMarker && !fileManager.fileExists(atPath: finalDirectory.path) {
            guard recoverInvalidExistingV2 else {
                throw BootstrapError.validationFailed(
                    "The V2 database was previously initialized but is now missing. The preserved legacy database may be outdated; automatic rollback is blocked."
                )
            }
            guard hasLegacyStore else {
                throw BootstrapError.validationFailed(
                    "The V2 database is missing and no preserved legacy database is available. No new empty database was created."
                )
            }
            try validateLegacyStore(at: legacyStoreURL)
        }

        if fileManager.fileExists(atPath: finalDirectory.path) {
            do {
                try validateV2Store(
                    at: finalStoreURL,
                    legacyStoreURL: hasLegacyStore ? legacyStoreURL : nil
                )
                // Adopt stores created by the previous bootstrap implementation.
                // Write the marker only after the existing V2 store has passed
                // schema, logical-reference and physical SQLite validation.
                if !hasBootstrapMarker {
                    try writeBootstrapMarker(at: markerURL, sourceWasLegacy: hasLegacyStore)
                }
                return finalStoreURL
            } catch {
                guard recoverInvalidExistingV2 else {
                    throw BootstrapError.validationFailed(
                        "Existing V2 store was not reusable and has been left untouched: \(error.localizedDescription)"
                    )
                }
                guard hasLegacyStore else {
                    throw BootstrapError.validationFailed(
                        "The V2 store is invalid and no preserved legacy database is available. No files were changed."
                    )
                }
                try validateLegacyStore(at: legacyStoreURL)
                let quarantineDirectory = parentDirectory.appendingPathComponent(
                    "itchPocket-v2.quarantine-\(UUID().uuidString)",
                    isDirectory: true
                )
                // Keep the entire previous V2 directory, including SQLite
                // sidecars and receipt, for possible later data salvage.
                try fileManager.moveItem(at: finalDirectory, to: quarantineDirectory)
            }
        }

        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let stagingDirectory = parentDirectory.appendingPathComponent(
            stagingDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let stagingStoreURL = stagingDirectory.appendingPathComponent(v2StoreFileName)

        do {
            if hasLegacyStore {
                _ = try copyLegacyStore(from: legacyStoreURL, to: stagingStoreURL)
                try beforePromotion?()
            }

            // A fresh install has no legacy source. It still receives the same
            // V2 schema, receipt and conservative bootstrap marker.
            if !fileManager.fileExists(atPath: stagingStoreURL.path) {
                let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
                let configuration = ModelConfiguration(
                    v2ConfigurationName,
                    schema: schema,
                    url: stagingStoreURL
                )
                let container = try ModelContainer(for: schema, configurations: [configuration])
                try container.mainContext.save()
                try writeMigrationReceipt(at: stagingStoreURL, counts: .zero)
            }

            try validateV2Store(
                at: stagingStoreURL,
                legacyStoreURL: hasLegacyStore ? legacyStoreURL : nil
            )

            // Write the durable marker before promotion. If the process stops
            // between this write and the directory move, next launch fails
            // closed and requires explicit recovery instead of silently
            // recreating a database from a possibly stale source.
            try writeBootstrapMarker(at: markerURL, sourceWasLegacy: hasLegacyStore)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            try afterPromotion?()
            return finalStoreURL
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func copyLegacyStore(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> MigrationCounts {
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
        try writeMigrationReceipt(
            at: destinationURL,
            counts: expected
        )
        return expected
    }

    private static func validateV2Store(
        at storeURL: URL,
        legacyStoreURL: URL?
    ) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV2.self)
        let configuration = ModelConfiguration(
            v2ConfigurationName,
            schema: schema,
            url: storeURL,
            allowsSave: false
        )
        let receiptURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(migrationReceiptFileName)
        guard let receiptData = try? Data(contentsOf: receiptURL),
              let receipt = try? JSONDecoder().decode(MigrationReceipt.self, from: receiptData),
              receipt.schemaVersion == migrationReceiptSchemaVersion else {
            throw BootstrapError.validationFailed("The V2 migration-completion receipt is missing or invalid.")
        }
        // Do not compare raw SQLite/WAL bytes with a startup-time fingerprint.
        // SQLite may checkpoint or recreate WAL files without changing logical
        // rows, so byte hashes are not a stable identity for a preserved store.
        // Once a receipt exists, the V2 store is authoritative; validate its
        // schema, logical references and SQLite integrity instead of rejecting
        // it because mutable business-row counts or legacy file layout changed.
        _ = legacyStoreURL

        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext

            // A completion receipt proves this store passed the full copy/validation
            // path. Every model remains fetchable, but legitimate row deletions
            // are allowed after migration.
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

            // A readable SQLite store can still contain logically broken join
        // records. Re-check the V2 invariants every time an existing store is
        // reused, without comparing mutable business-row counts to old values.
        let currentGames = try context.fetch(FetchDescriptor<DBGame>())
        let gameIDs = Set(currentGames.map(\.id))
        let details = try context.fetch(FetchDescriptor<DBGameDetail>())
        guard details.allSatisfy({ gameIDs.contains($0.gameID) }) else {
            throw BootstrapError.validationFailed("A game-detail record references a missing game.")
        }

        let collectionIDs = Set(try context.fetch(FetchDescriptor<DBLibraryCollection>()).map(\.id))
            let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
            var membershipsByCollection: [String: Set<String>] = [:]
            for item in items {
                guard collectionIDs.contains(item.collectionID) else {
                    throw BootstrapError.validationFailed("A collection item references a missing collection.")
                }
                guard gameIDs.contains(item.gameID) else {
                    throw BootstrapError.validationFailed("A collection item references a missing game.")
                }
                guard membershipsByCollection[item.collectionID, default: []].insert(item.gameID).inserted else {
                    throw BootstrapError.validationFailed("A collection contains duplicate membership for game \(item.gameID).")
                }
            }
        }

        // SwiftData has released its container before SQLite is opened directly.
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    private static func writeBootstrapMarker(
        at markerURL: URL,
        sourceWasLegacy: Bool
    ) throws {
        let marker = BootstrapMarker(
            schemaVersion: migrationReceiptSchemaVersion,
            sourceWasLegacy: sourceWasLegacy,
            initializedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(marker).write(to: markerURL, options: .atomic)
    }

    /// Validate the preserved source before moving a broken V2 directory aside.
    /// The legacy store is opened read-only and is never migrated in place.
    private static func validateLegacyStore(at storeURL: URL) throws {
        let schema = Schema(versionedSchema: ItchPocketSchemaV1.self)
        let configuration = ModelConfiguration(
            legacyConfigurationName,
            schema: schema,
            url: storeURL,
            allowsSave: false
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBDeveloper>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBGame>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryEntry>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBGameUpdate>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBCalendarEvent>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBSparkMetadata>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBTranslation>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBDiscoverySnapshot>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBUpdateWatch>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryCollection>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBLibraryStatusEvent>())
        _ = try context.fetchCount(FetchDescriptor<ItchPocketSchemaV1.DBAppState>())
    }

    private static func writeMigrationReceipt(
        at storeURL: URL,
        counts: MigrationCounts
    ) throws {
        let receipt = MigrationReceipt(
            schemaVersion: migrationReceiptSchemaVersion,
            counts: counts,
            completedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let receiptURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(migrationReceiptFileName)
        try data.write(to: receiptURL, options: .atomic)
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
        let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.id, $0) })
        for detail in details {
            guard let game = gamesByID[detail.gameID],
                  detail.descriptionText == game.descriptionText,
                  detail.galleryURLs == game.galleryURLs,
                  detail.discoveryTagsData == game.discoveryTagsData,
                  detail.fetchedAt == nil,
                  !detail.isComplete else {
                throw BootstrapError.validationFailed("Migrated detail does not match its legacy game record: \(detail.gameID).")
            }
        }

        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        let collectionIDs = Set(collections.map(\.id))
        guard items.allSatisfy({ collectionIDs.contains($0.collectionID) }) else {
            throw BootstrapError.validationFailed("A collection item references a missing collection.")
        }
        let stableItemIDs = items.map(\.id)
        guard Set(stableItemIDs).count == stableItemIDs.count else {
            throw BootstrapError.validationFailed("Duplicate collection item identifiers were found.")
        }
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
