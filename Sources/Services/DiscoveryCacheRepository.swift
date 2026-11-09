import Foundation
import SwiftData

/// Owns persistence operations for rebuildable discovery snapshots.
/// Callers deal in payloads and keys; SwiftData models remain behind this boundary.
@MainActor
final class DiscoveryCacheRepository {
    static let shared = DiscoveryCacheRepository(database: .shared)

    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func payload(for key: String, now: Date = .now) throws -> Data? {
        let context = database.context
        let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.key == key }
        )
        guard let snapshot = try context.fetch(descriptor).first else { return nil }
        guard snapshot.expiresAt > now else {
            context.delete(snapshot)
            try database.save()
            return nil
        }
        return snapshot.payload
    }

    func save(
        payload: Data,
        for key: String,
        timeToLive: TimeInterval,
        fetchedAt: Date = .now
    ) throws {
        let context = database.context
        let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.key == key }
        )
        let snapshot = try context.fetch(descriptor).first
            ?? DBDiscoverySnapshot(
                key: key,
                payload: payload,
                expiresAt: fetchedAt.addingTimeInterval(timeToLive)
            )
        if snapshot.modelContext == nil { context.insert(snapshot) }
        snapshot.payload = payload
        snapshot.fetchedAt = fetchedAt
        snapshot.expiresAt = fetchedAt.addingTimeInterval(timeToLive)
        try database.save()
    }

    func remove(key: String) throws {
        let context = database.context
        let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.key == key }
        )
        if let snapshot = try context.fetch(descriptor).first {
            context.delete(snapshot)
            try database.save()
        }
    }
}
