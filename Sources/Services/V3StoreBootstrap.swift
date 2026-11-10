import Foundation
import SwiftData

/// Builds V3 from a copy of the authoritative V2 store. The V2 directory is
/// never opened for writing and remains available if migration or validation
/// fails. A completed V3 directory is reused only after logical and SQLite
/// integrity checks pass.
@MainActor
enum V3StoreBootstrap {
    enum BootstrapError: LocalizedError {
        case missingSource(URL)
        case incompleteDestination(URL)
        case validationFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingSource(let url):
                return "The V2 source database is missing: \(url.path)"
            case .incompleteDestination(let url):
                return "The V3 database directory exists but its store is missing: \(url.path)"
            case .validationFailed(let detail):
                return "The V3 database copy did not pass validation: \(detail)"
            }
        }
    }

    static let directoryName = "itchPocket-v3"
    static let stagingDirectoryName = "itchPocket-v3.staging"
    static let storeFileName = "itchPocket-v3.store"
    private static let recoveryMarkerName = ".v2-detail-recovery-v1"

    enum PreparationPhase {
        case sourceCopiedToStaging
        case stagingMigratedAndValidated
        case stagingPromoted
    }

    static func prepareStore(
        v2StoreURL: URL,
        recoverInvalidExistingV3: Bool = false,
        afterPhase: ((PreparationPhase) throws -> Void)? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let parent = v2StoreURL.deletingLastPathComponent().deletingLastPathComponent()
        let finalDirectory = parent.appendingPathComponent(directoryName, isDirectory: true)
        let stagingDirectory = parent.appendingPathComponent(stagingDirectoryName, isDirectory: true)
        let finalStoreURL = finalDirectory.appendingPathComponent(storeFileName)

        if fileManager.fileExists(atPath: finalDirectory.path) {
            do {
                guard fileManager.fileExists(atPath: finalStoreURL.path) else {
                    throw BootstrapError.incompleteDestination(finalStoreURL)
                }
                try validateV3Store(at: finalStoreURL)
                try? recoverMissingDataFromV2Backup(v2StoreURL: v2StoreURL, v3StoreURL: finalStoreURL, directory: finalDirectory)
                return finalStoreURL
            } catch {
                guard recoverInvalidExistingV3 else { throw error }
                let quarantine = parent.appendingPathComponent(
                    "itchPocket-v3.quarantine-\(UUID().uuidString)",
                    isDirectory: true
                )
                try fileManager.moveItem(at: finalDirectory, to: quarantine)
            }
        }

        guard fileManager.fileExists(atPath: v2StoreURL.path) else {
            throw BootstrapError.missingSource(v2StoreURL)
        }

        if fileManager.fileExists(atPath: stagingDirectory.path) {
            try fileManager.removeItem(at: stagingDirectory)
        }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagingStoreURL = stagingDirectory.appendingPathComponent(storeFileName)

        do {
            try copySQLiteStoreFamily(from: v2StoreURL, to: stagingStoreURL)
            try afterPhase?(.sourceCopiedToStaging)
            try migrateAndValidate(at: stagingStoreURL)
            try afterPhase?(.stagingMigratedAndValidated)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
            try afterPhase?(.stagingPromoted)
            try recoverMissingDataFromV2Backup(v2StoreURL: v2StoreURL, v3StoreURL: finalStoreURL, directory: finalDirectory)
            return finalStoreURL
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func copySQLiteStoreFamily(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else {
            throw BootstrapError.missingSource(source)
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let sourcePart = URL(fileURLWithPath: source.path + suffix)
            guard fileManager.fileExists(atPath: sourcePart.path) else { continue }
            let destinationPart = URL(fileURLWithPath: destination.path + suffix)
            try fileManager.copyItem(at: sourcePart, to: destinationPart)
        }
    }

    private static func migrateAndValidate(at storeURL: URL) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration(
                directoryName,
                schema: schema,
                url: storeURL
            )
            let container = try ModelContainer(
                for: schema,
                migrationPlan: ItchPocketMigrationPlan.self,
                configurations: [configuration]
            )
            try validate(context: container.mainContext)
        }
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    private static func validateV3Store(at storeURL: URL) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration(
                "itchPocket-v3",
                schema: schema,
                url: storeURL
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            try validate(context: container.mainContext)
        }
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    /// One-time, non-destructive backfill for V3 installs whose detail rows
    /// were incomplete after cutover. V2 is opened read-only and retained as
    /// the recovery source; only missing V3 values are filled.
    private static func recoverMissingDataFromV2Backup(
        v2StoreURL: URL,
        v3StoreURL: URL,
        directory: URL
    ) throws {
        let fileManager = FileManager.default
        let markerURL = directory.appendingPathComponent(recoveryMarkerName)
        guard !fileManager.fileExists(atPath: markerURL.path),
              fileManager.fileExists(atPath: v2StoreURL.path) else { return }

        try autoreleasepool {
            let v2Schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let v2Configuration = ModelConfiguration(
                "itchPocket-v2-recovery-readonly",
                schema: v2Schema,
                url: v2StoreURL,
                allowsSave: false
            )
            let v2Container = try ModelContainer(for: v2Schema, configurations: [v2Configuration])
            let v2Context = v2Container.mainContext
            let oldGames = try v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>())
            let oldDetails = try v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>())
            let oldDetailsByID = Dictionary(oldDetails.map { ($0.gameID, $0) }, uniquingKeysWith: { first, _ in first })
            let oldDevelopers = try v2Context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDeveloper>())
            let oldDevelopersByID = Dictionary(oldDevelopers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            let v3Schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let v3Configuration = ModelConfiguration("itchPocket-v3-recovery", schema: v3Schema, url: v3StoreURL)
            let v3Container = try ModelContainer(for: v3Schema, configurations: [v3Configuration])
            let v3Context = v3Container.mainContext
            let currentGames = try v3Context.fetch(FetchDescriptor<DBGame>())
            let currentGamesByID = Dictionary(currentGames.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let currentDetails = try v3Context.fetch(FetchDescriptor<DBGameDetail>())
            var currentDetailsByID = Dictionary(currentDetails.map { ($0.gameID, $0) }, uniquingKeysWith: { first, _ in first })
            let currentDevelopers = try v3Context.fetch(FetchDescriptor<DBDeveloper>())
            let currentDevelopersByID = Dictionary(currentDevelopers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            var changed = false
            for oldGame in oldGames {
                guard let game = currentGamesByID[oldGame.id] else { continue }

                if !hasText(game.gameURL), hasText(oldGame.gameURL) {
                    game.gameURL = oldGame.gameURL
                    changed = true
                }
                if game.developerID == nil, let oldDeveloperID = oldGame.developerID {
                    game.developerID = oldDeveloperID
                    changed = true
                }

                let oldDetail = oldDetailsByID[oldGame.id]
                let sourceDescription = hasText(oldGame.descriptionText) ? oldGame.descriptionText : oldDetail?.descriptionText
                let sourceGallery = !oldGame.galleryURLs.isEmpty ? oldGame.galleryURLs : (oldDetail?.galleryURLs ?? [])
                let sourceTags = oldGame.discoveryTagsData ?? oldDetail?.discoveryTagsData
                var detail = currentDetailsByID[oldGame.id]
                if detail == nil,
                   hasText(sourceDescription) || !sourceGallery.isEmpty || sourceTags != nil {
                    let inserted = DBGameDetail(gameID: oldGame.id)
                    v3Context.insert(inserted)
                    currentDetailsByID[oldGame.id] = inserted
                    detail = inserted
                    changed = true
                }
                if let detail {
                    if !hasText(detail.descriptionText), hasText(sourceDescription) {
                        detail.descriptionText = sourceDescription
                        changed = true
                    }
                    if detail.galleryURLs.isEmpty, !sourceGallery.isEmpty {
                        detail.galleryURLs = sourceGallery
                        changed = true
                    }
                    if detail.discoveryTagsData == nil, let sourceTags {
                        detail.discoveryTagsData = sourceTags
                        changed = true
                    }
                }

                if let developerID = game.developerID,
                   let oldDeveloper = oldDevelopersByID[developerID],
                   let developer = currentDevelopersByID[developerID] {
                    if !hasText(developer.profileURL), hasText(oldDeveloper.profileURL) {
                        developer.profileURL = oldDeveloper.profileURL
                        changed = true
                    }
                    if !hasText(developer.patreonURL), hasText(oldDeveloper.patreonURL) {
                        developer.patreonURL = oldDeveloper.patreonURL
                        changed = true
                    }
                    if !hasText(developer.discordURL), hasText(oldDeveloper.discordURL) {
                        developer.discordURL = oldDeveloper.discordURL
                        changed = true
                    }
                    if !hasText(developer.avatarURL), hasText(oldDeveloper.avatarURL) {
                        developer.avatarURL = oldDeveloper.avatarURL
                        developer.avatarSource = oldDeveloper.avatarSource
                        developer.avatarResolvedAt = oldDeveloper.avatarResolvedAt
                        changed = true
                    }
                }
            }

            if changed { try v3Context.save() }
            try validate(context: v3Context)
        }

        // Write the marker only after the V3 store has been saved and validated.
        try Data("completed".utf8).write(to: markerURL, options: .atomic)
    }

    private static func hasText(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validate(context: ModelContext) throws {
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let gameIDs = Set(games.map(\.id))

        let details = try context.fetch(FetchDescriptor<DBGameDetail>())
        for detail in details where !gameIDs.contains(detail.gameID) {
            throw BootstrapError.validationFailed("Game detail references missing game: \(detail.gameID).")
        }
        guard Set(details.map(\.gameID)).count == details.count else {
            throw BootstrapError.validationFailed("Duplicate game-detail records were found.")
        }

        let libraryEntries = try context.fetch(FetchDescriptor<DBLibraryEntry>())
        for entry in libraryEntries where !gameIDs.contains(entry.gameID) {
            throw BootstrapError.validationFailed("Library entry references missing game: \(entry.gameID).")
        }

        let updates = try context.fetch(FetchDescriptor<DBGameUpdate>())
        let updatesByID = Dictionary(updates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for update in updates where !gameIDs.contains(update.gameID) {
            throw BootstrapError.validationFailed("Game update references missing game: \(update.gameID).")
        }

        let calendarEvents = try context.fetch(FetchDescriptor<DBCalendarEvent>())
        for event in calendarEvents {
            guard gameIDs.contains(event.gameID) else {
                throw BootstrapError.validationFailed("Calendar event references missing game: \(event.gameID).")
            }
            if let sourceUpdateID = event.sourceUpdateID,
               let linkedUpdate = updatesByID[sourceUpdateID],
               linkedUpdate.gameID != event.gameID {
                throw BootstrapError.validationFailed(
                    "Calendar event \(event.id) links to an update belonging to another game."
                )
            }
        }

        let sparkRows = try context.fetch(FetchDescriptor<DBSparkMetadata>())
        for row in sparkRows where !gameIDs.contains(row.gameID) {
            throw BootstrapError.validationFailed("Spark metadata references missing game: \(row.gameID).")
        }

        let updateWatches = try context.fetch(FetchDescriptor<DBUpdateWatch>())
        for watch in updateWatches where !gameIDs.contains(watch.gameID) {
            throw BootstrapError.validationFailed("Update watch references missing game: \(watch.gameID).")
        }

        let statusEvents = try context.fetch(FetchDescriptor<DBLibraryStatusEvent>())
        for event in statusEvents where !gameIDs.contains(event.gameID) {
            throw BootstrapError.validationFailed("Library status event references missing game: \(event.gameID).")
        }

        let collections = try context.fetch(FetchDescriptor<DBLibraryCollection>())
        let collectionIDs = Set(collections.map(\.id))
        let items = try context.fetch(FetchDescriptor<DBLibraryCollectionItem>())
        var seen = Set<String>()
        for item in items {
            guard collectionIDs.contains(item.collectionID),
                  gameIDs.contains(item.gameID),
                  item.id == DBLibraryCollectionItem.stableID(
                    collectionID: item.collectionID,
                    gameID: item.gameID
                  ),
                  seen.insert(item.id).inserted else {
                throw BootstrapError.validationFailed(
                    "A collection membership is orphaned, duplicated, or has an invalid identifier."
                )
            }
        }
    }
}
