import Foundation

/// Owns disposable V4 staging snapshots. It never mutates or removes the V3 source.
struct V4MigrationStagingStore: Equatable {
    let runID: String
    let stagingStoreID: String
    let directoryURL: URL
    let storeURL: URL
}

/// Creates and removes isolated staging directories for one migration attempt.
struct V4MigrationStagingStoreManager {
    enum StagingError: Error, Equatable {
        case invalidIdentifier
        case sourceStoreMissing
        case stagingAlreadyExists
        case stagingStoreMissing
        case unexpectedSidecar
    }

    private let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    /// Copies the source into a fresh staging directory and runs full SQLite integrity checks.
    /// The caller must coordinate source-store writers and SwiftData lifetimes.
    func createSnapshot(
        from sourceURL: URL,
        runID: String,
        stagingStoreID: String
    ) throws -> V4MigrationStagingStore {
        guard Self.isSafeIdentifier(runID),
              Self.isSafeIdentifier(stagingStoreID) else {
            throw StagingError.invalidIdentifier
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw StagingError.sourceStoreMissing
        }

        let directoryURL = directoryURL(runID: runID, stagingStoreID: stagingStoreID)
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw StagingError.stagingAlreadyExists
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: false)

        let storeURL = directoryURL.appendingPathComponent("v4-staging.sqlite", isDirectory: false)
        do {
            try SQLiteStoreSnapshotCopier.copy(from: sourceURL, to: storeURL)
            try SQLiteStoreIntegrityChecker.fullCheck(at: storeURL)

            let attributes = try fileManager.attributesOfItem(atPath: storeURL.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                throw StagingError.stagingStoreMissing
            }

            for suffix in ["-wal", "-shm", "-journal"] {
                guard !fileManager.fileExists(atPath: storeURL.path + suffix) else {
                    throw StagingError.unexpectedSidecar
                }
            }

            return V4MigrationStagingStore(
                runID: runID,
                stagingStoreID: stagingStoreID,
                directoryURL: directoryURL,
                storeURL: storeURL
            )
        } catch {
            // A failed attempt is disposable. Never retry in a partial database.
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
    }

    /// Removes exactly the directory derived from the validated opaque IDs.
    /// Returns false when it has already been removed.
    @discardableResult
    func discard(runID: String, stagingStoreID: String) throws -> Bool {
        guard Self.isSafeIdentifier(runID),
              Self.isSafeIdentifier(stagingStoreID) else {
            throw StagingError.invalidIdentifier
        }
        let directory = directoryURL(runID: runID, stagingStoreID: stagingStoreID)
        guard fileManager.fileExists(atPath: directory.path) else {
            return false
        }
        try fileManager.removeItem(at: directory)
        return true
    }

    private func directoryURL(runID: String, stagingStoreID: String) -> URL {
        rootURL.appendingPathComponent(
            "run-\(runID)-staging-\(stagingStoreID)",
            isDirectory: true
        )
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }
}
