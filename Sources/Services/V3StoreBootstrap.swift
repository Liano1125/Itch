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

    enum PreparationPhase: Equatable {
        case sourceCopiedToStaging
        case stagingMigratedAndValidated
        case stagingPromoted
        case backfillApplied
    }

    static func prepareStore(
        v2StoreURL: URL,
        recoverInvalidExistingV3: Bool = false,
        afterPhase: ((PreparationPhase) throws -> Void)? = nil,
        writeRecoveryMarker: ((Data, URL) throws -> Void)? = nil
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
            } catch {
                guard recoverInvalidExistingV3 else { throw error }
                let quarantine = parent.appendingPathComponent(
                    "itchPocket-v3.quarantine-\(UUID().uuidString)",
                    isDirectory: true
                )
                try fileManager.moveItem(at: finalDirectory, to: quarantine)
            }

            // A valid V3 store must never be quarantined merely because its
            // optional V2-backup backfill failed. However, do not silently
            // report startup success either: surface the error so the caller
            // can diagnose/restore the backup and retry on the next launch.
            if fileManager.fileExists(atPath: finalStoreURL.path) {
                try recoverMissingDataFromV2Backup(
                    v2StoreURL: v2StoreURL,
                    v3StoreURL: finalStoreURL,
                    directory: finalDirectory,
                    afterPhase: afterPhase,
                    writeRecoveryMarker: writeRecoveryMarker
                )
                return finalStoreURL
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
            try recoverMissingDataFromV2Backup(
                v2StoreURL: v2StoreURL,
                v3StoreURL: finalStoreURL,
                directory: finalDirectory,
                afterPhase: afterPhase,
                writeRecoveryMarker: writeRecoveryMarker
            )
            return finalStoreURL
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    private static func copySQLiteStoreFamily(from source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw BootstrapError.missingSource(source)
        }

        // SQLite's backup API takes a consistent read snapshot, including
        // committed pages still resident in WAL. Copying the main/WAL/SHM
        // files one by one can otherwise capture different database moments.
        try SQLiteStoreSnapshotCopier.copy(from: source, to: destination)
    }

    /// Validate V2 invariants that can be checked before SwiftData starts the
    /// destructive schema transition on the disposable staging copy. In
    /// particular, reject ambiguous collection membership while the store is
    /// still opened with its frozen V2 schema. A failed V3 migration can leave
    /// CoreData/SQLite descriptors attached to the staging files, so detecting
    /// this deterministic conflict first avoids quarantining live sidecars.
    private static func validateV2MigrationInputs(at storeURL: URL) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration(
                "itchPocket-v2-migration-preflight",
                schema: schema,
                url: storeURL,
                allowsSave: false
            )
            var container: ModelContainer? = try ModelContainer(
                for: schema,
                configurations: [configuration]
            )

            do {
                let context = container!.mainContext
                let collections = try context.fetch(
                    FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollection>()
                )
                let items = try context.fetch(
                    FetchDescriptor<ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem>()
                )
                let itemsByCollection = Dictionary(grouping: items, by: \.collectionID)

                for collection in collections {
                    let legacyIDs = uniqueInOrder(collection.gameIDs)
                    let existing = (itemsByCollection[collection.id] ?? []).sorted {
                        if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                        return $0.id < $1.id
                    }
                    let existingIDs = existing.map(\.gameID)

                    guard Set(existingIDs).count == existingIDs.count else {
                        throw ItchPocketMigrationPlan.MigrationError.duplicateCollectionMember(collection.id)
                    }
                    guard existing.allSatisfy({
                        $0.id == ItchPocketSchemaV2Snapshot.DBLibraryCollectionItem.stableID(
                            collectionID: collection.id,
                            gameID: $0.gameID
                        )
                    }) else {
                        throw ItchPocketMigrationPlan.MigrationError.collectionMembershipConflict(collection.id)
                    }
                    if !existing.isEmpty, existingIDs != legacyIDs {
                        throw ItchPocketMigrationPlan.MigrationError.collectionMembershipConflict(collection.id)
                    }
                }
            }

            // Release all persistent models and the V2 container before the
            // migration plan attempts to open the same staging store as V3.
            container = nil
        }
    }

    private static func migrateAndValidate(at storeURL: URL) throws {
        try validateV2MigrationInputs(at: storeURL)
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration(
                directoryName,
                schema: schema,
                url: storeURL
            )
            var container: ModelContainer? = try ModelContainer(
                for: schema,
                migrationPlan: ItchPocketMigrationPlan.self,
                configurations: [configuration]
            )

            // Keep the migration context scoped so every SwiftData reference
            // is released before the independent SQLite integrity check.
            do {
                let context = container!.mainContext
                try validate(context: context)
            }
            container = nil
        }
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    private static func validateV3Store(at storeURL: URL) throws {
        // Reject non-SQLite or structurally corrupt files before SwiftData /
        // CoreData attempts to attach a persistent store. A failed CoreData
        // open can leave SQLite sidecar descriptors alive while recovery
        // quarantines (moves) the invalid directory.
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)

        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration(
                "itchPocket-v3",
                schema: schema,
                url: storeURL
            )
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])
            do {
                try validate(context: container!.mainContext)
            }
            container = nil
        }
    }

    private struct V2BackfillSnapshot {
        struct Game {
            let id: String
            let gameURL: String?
            let developerID: String?
            let descriptionText: String?
            let galleryURLs: [String]
            let discoveryTagsData: Data?
        }

        struct Detail {
            let gameID: String
            let descriptionText: String?
            let galleryURLs: [String]
            let discoveryTagsData: Data?
        }

        struct Developer {
            let id: String
            let profileURL: String?
            let patreonURL: String?
            let discordURL: String?
            let avatarURL: String?
            let avatarSource: String?
            let avatarResolvedAt: Date?
        }

        let games: [Game]
        let detailsByGameID: [String: Detail]
        let developersByID: [String: Developer]
    }

    /// One-time, non-destructive backfill for V3 installs whose detail rows
    /// were incomplete after cutover. Read V2 into value-only snapshots first,
    /// close that store, and only then open V3 for writes. Never keep two
    /// SwiftData containers alive while checking or mutating either store.
    private static func recoverMissingDataFromV2Backup(
        v2StoreURL: URL,
        v3StoreURL: URL,
        directory: URL,
        afterPhase: ((PreparationPhase) throws -> Void)? = nil,
        writeRecoveryMarker: ((Data, URL) throws -> Void)? = nil
    ) throws {
        let fileManager = FileManager.default
        let markerURL = directory.appendingPathComponent(recoveryMarkerName)
        guard !fileManager.fileExists(atPath: markerURL.path),
              fileManager.fileExists(atPath: v2StoreURL.path) else { return }

        let snapshot = try readV2BackfillSnapshot(at: v2StoreURL)
        try applyBackfill(snapshot, to: v3StoreURL)
        try afterPhase?(.backfillApplied)

        // Write the marker only after the V3 store has been saved and validated.
        let markerData = Data("completed".utf8)
        if let writeRecoveryMarker {
            try writeRecoveryMarker(markerData, markerURL)
        } else {
            try markerData.write(to: markerURL, options: .atomic)
        }
    }

    private static func readV2BackfillSnapshot(at storeURL: URL) throws -> V2BackfillSnapshot {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV2Snapshot.self)
            let configuration = ModelConfiguration(
                "itchPocket-v2-recovery-readonly",
                schema: schema,
                url: storeURL,
                allowsSave: false
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let games = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGame>())
            let details = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBGameDetail>())
            let developers = try context.fetch(FetchDescriptor<ItchPocketSchemaV2Snapshot.DBDeveloper>())

            // Convert every SwiftData model into plain value data. No persistent
            // model or ModelContext is allowed to escape this autorelease scope.
            let gameValues = games.map {
                V2BackfillSnapshot.Game(
                    id: $0.id,
                    gameURL: $0.gameURL,
                    developerID: $0.developerID,
                    descriptionText: $0.descriptionText,
                    galleryURLs: $0.galleryURLs,
                    discoveryTagsData: $0.discoveryTagsData
                )
            }
            let detailValues = details.map {
                V2BackfillSnapshot.Detail(
                    gameID: $0.gameID,
                    descriptionText: $0.descriptionText,
                    galleryURLs: $0.galleryURLs,
                    discoveryTagsData: $0.discoveryTagsData
                )
            }
            let developerValues = developers.map {
                V2BackfillSnapshot.Developer(
                    id: $0.id,
                    profileURL: $0.profileURL,
                    patreonURL: $0.patreonURL,
                    discordURL: $0.discordURL,
                    avatarURL: $0.avatarURL,
                    avatarSource: $0.avatarSource,
                    avatarResolvedAt: $0.avatarResolvedAt
                )
            }

            return V2BackfillSnapshot(
                games: gameValues,
                detailsByGameID: Dictionary(
                    detailValues.map { ($0.gameID, $0) },
                    uniquingKeysWith: { first, _ in first }
                ),
                developersByID: Dictionary(
                    developerValues.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
            )
        }
    }

    private static func applyBackfill(
        _ snapshot: V2BackfillSnapshot,
        to storeURL: URL
    ) throws {
        try autoreleasepool {
            let schema = Schema(versionedSchema: ItchPocketSchemaV3.self)
            let configuration = ModelConfiguration(
                "itchPocket-v3-recovery",
                schema: schema,
                url: storeURL
            )
            var container: ModelContainer? = try ModelContainer(for: schema, configurations: [configuration])

            // Keep every ModelContext and PersistentModel local inside this
            // scope. Release those references before releasing the container,
            // so no SwiftData reader/writer can outlive the backfill operation.
            do {
                let context = container!.mainContext
                let currentGames = try context.fetch(FetchDescriptor<DBGame>())
                let currentGamesByID = Dictionary(
                    currentGames.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let currentDetails = try context.fetch(FetchDescriptor<DBGameDetail>())
                var currentDetailsByID = Dictionary(
                    currentDetails.map { ($0.gameID, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let currentDevelopers = try context.fetch(FetchDescriptor<DBDeveloper>())
                let currentDevelopersByID = Dictionary(
                    currentDevelopers.map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                )

                var changed = false
                for oldGame in snapshot.games {
                    guard let game = currentGamesByID[oldGame.id] else { continue }

                    if !hasText(game.gameURL), hasText(oldGame.gameURL) {
                        game.gameURL = oldGame.gameURL
                        changed = true
                    }
                    if game.developerID == nil, let oldDeveloperID = oldGame.developerID {
                        game.developerID = oldDeveloperID
                        changed = true
                    }

                    let oldDetail = snapshot.detailsByGameID[oldGame.id]
                    let sourceDescription = hasText(oldGame.descriptionText)
                        ? oldGame.descriptionText
                        : oldDetail?.descriptionText
                    let sourceGallery = !oldGame.galleryURLs.isEmpty
                        ? oldGame.galleryURLs
                        : (oldDetail?.galleryURLs ?? [])
                    let sourceTags = oldGame.discoveryTagsData ?? oldDetail?.discoveryTagsData
                    var detail = currentDetailsByID[oldGame.id]
                    if detail == nil,
                       hasText(sourceDescription) || !sourceGallery.isEmpty || sourceTags != nil {
                        let inserted = DBGameDetail(gameID: oldGame.id)
                        context.insert(inserted)
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
                       let oldDeveloper = snapshot.developersByID[developerID],
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

                if changed { try context.save() }
                try validate(context: context)
            }

            // The context and all fetched persistent models have left scope.
            container = nil
        }

        // The V3 ModelContainer is fully released before SQLite opens a
        // separate read-only connection for the post-backfill integrity check.
        try SQLiteStoreIntegrityChecker.quickCheck(at: storeURL)
    }

    /// Preserve the first occurrence of each legacy game ID while retaining its order.
    private static func uniqueInOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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
