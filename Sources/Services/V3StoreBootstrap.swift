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

    static func prepareStore(v2StoreURL: URL, recoverInvalidExistingV3: Bool = false) throws -> URL {
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
            try migrateAndValidate(at: stagingStoreURL)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
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

    private static func validate(context: ModelContext) throws {
        let games = try context.fetch(FetchDescriptor<DBGame>())
        let gameIDs = Set(games.map(\.id))
        let details = try context.fetch(FetchDescriptor<DBGameDetail>())
        guard details.allSatisfy({ gameIDs.contains($0.gameID) }) else {
            throw BootstrapError.validationFailed("A detail record references a missing game.")
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
