import Foundation
import SwiftData

struct StoredSparkMetadata {
    let gameID: String
    let runtimeSeconds: Double
    let lastSaveAt: Date?
    let renpyVersion: String?
    let saveCount: Int?
    let scannedAt: Date

    init(
        gameID: String,
        runtimeSeconds: Double,
        lastSaveAt: Date? = nil,
        renpyVersion: String? = nil,
        saveCount: Int? = nil,
        scannedAt: Date = .now
    ) {
        self.gameID = gameID
        self.runtimeSeconds = runtimeSeconds
        self.lastSaveAt = lastSaveAt
        self.renpyVersion = renpyVersion
        self.saveCount = saveCount
        self.scannedAt = scannedAt
    }

    fileprivate init(_ row: DBSparkMetadata) {
        self.init(
            gameID: row.gameID,
            runtimeSeconds: row.runtimeSeconds,
            lastSaveAt: row.lastSaveAt,
            renpyVersion: row.renpyVersion,
            saveCount: row.saveCount,
            scannedAt: row.scannedAt
        )
    }
}

enum SparkRepositoryError: Error, Equatable {
    case duplicateGameID(String)
}

/// Owns persistence for Spark/Ren'Py save metadata. Filesystem scanning and
/// monotonic merge decisions remain in SparkSyncStore and PersonalLibraryStore.
@MainActor
final class SparkRepository {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func loadByGameID() throws -> [String: StoredSparkMetadata] {
        let rows = try database.context.fetch(FetchDescriptor<DBSparkMetadata>())
        return Dictionary(rows.map { ($0.gameID, StoredSparkMetadata($0)) }, uniquingKeysWith: { _, latest in latest })
    }

    func upsert(
        _ snapshots: [StoredSparkMetadata],
        save shouldSave: Bool = true
    ) throws {
        guard !snapshots.isEmpty else { return }

        var seen = Set<String>()
        for snapshot in snapshots {
            guard seen.insert(snapshot.gameID).inserted else {
                throw SparkRepositoryError.duplicateGameID(snapshot.gameID)
            }
        }

        let context = database.context
        // Resolve every existing row before mutating the shared context so a
        // fetch failure cannot leave a partially applied batch.
        var existingByGameID: [String: DBSparkMetadata] = [:]
        for snapshot in snapshots {
            let gameID = snapshot.gameID
            let descriptor = FetchDescriptor<DBSparkMetadata>(
                predicate: #Predicate { $0.gameID == gameID }
            )
            if let row = try context.fetch(descriptor).first {
                existingByGameID[gameID] = row
            }
        }

        for snapshot in snapshots {
            let row = existingByGameID[snapshot.gameID]
                ?? DBSparkMetadata(
                    gameID: snapshot.gameID,
                    runtimeSeconds: snapshot.runtimeSeconds,
                    scannedAt: snapshot.scannedAt
                )
            if row.modelContext == nil { context.insert(row) }
            row.runtimeSeconds = snapshot.runtimeSeconds
            row.lastSaveAt = snapshot.lastSaveAt
            row.renpyVersion = snapshot.renpyVersion
            row.saveCount = snapshot.saveCount
            row.scannedAt = snapshot.scannedAt
        }

        if shouldSave { try database.save() }
    }
}
