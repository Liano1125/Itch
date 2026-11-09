import Foundation

/// Shared TTL cache for rebuildable discovery and collection responses.
/// Serialization stays here; persistence is delegated to DiscoveryCacheRepository.
@MainActor
enum DiscoveryCacheStore {
    static func load<Value: Decodable>(
        _ type: Value.Type,
        key: String,
        now: Date = .now
    ) -> Value? {
        do {
            guard let payload = try DiscoveryCacheRepository.shared.payload(for: key, now: now) else {
                return nil
            }
            return try JSONDecoder().decode(type, from: payload)
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
            try DiscoveryCacheRepository.shared.save(
                payload: payload,
                for: key,
                timeToLive: timeToLive
            )
        } catch {
            print("itchPocket discovery cache write failed: \(error)")
        }
    }

    static func remove(key: String) {
        do {
            try DiscoveryCacheRepository.shared.remove(key: key)
        } catch {
            print("itchPocket discovery cache removal failed: \(error)")
        }
    }
}
