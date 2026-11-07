import Foundation
import SwiftData

/// Shared TTL cache for rebuildable discovery and collection responses.
@MainActor
enum DiscoveryCacheStore {
    static func load<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        now: Date = .now
    ) -> Value? {
        do {
            let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
                predicate: #Predicate { $0.key == key }
            )
            guard let snapshot = try AppDatabase.shared.context.fetch(descriptor).first else { return nil }
            guard snapshot.expiresAt > now else {
                AppDatabase.shared.context.delete(snapshot)
                try AppDatabase.shared.save()
                return nil
            }
            return try JSONDecoder().decode(type, from: snapshot.payload)
        } catch {
            print("itchPocket discovery cache read failed: \(error)")
            return nil
        }
    }

    static func save<Value: Encodable>(
        _ value: Value,
        key: String,
        timeToLive: TimeInterval
    ) {
        do {
            let payload = try JSONEncoder().encode(value)
            let context = AppDatabase.shared.context
            let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
                predicate: #Predicate { $0.key == key }
            )
            let snapshot = try context.fetch(descriptor).first
                ?? DBDiscoverySnapshot(key: key, payload: payload, expiresAt: .now.addingTimeInterval(timeToLive))
            if snapshot.modelContext == nil { context.insert(snapshot) }
            snapshot.payload = payload
            snapshot.fetchedAt = .now
            snapshot.expiresAt = .now.addingTimeInterval(timeToLive)
            try AppDatabase.shared.save()
        } catch {
            print("itchPocket discovery cache write failed: \(error)")
        }
    }

    static func remove(key: String) {
        do {
            let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
                predicate: #Predicate { $0.key == key }
            )
            if let snapshot = try AppDatabase.shared.context.fetch(descriptor).first {
                AppDatabase.shared.context.delete(snapshot)
                try AppDatabase.shared.save()
            }
        } catch {
            print("itchPocket discovery cache removal failed: \(error)")
        }
    }
}
