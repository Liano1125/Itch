import Foundation

/// Small, rebuildable snapshot for the discovery landing page.
/// It is intentionally separate from canonical game entities: list ordering,
/// feed membership and paging are presentation cache, not game records.
enum DiscoveryFeedSnapshotCache {
    private struct Snapshot: Codable {
        let version: Int
        let savedAt: Date
        let gamesByFeed: [String: [PublicCollectionGame]]
    }

    private static let fileName = "curated-feeds-v1.json"
    private static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    static func load(now: Date = .now) -> [String: [PublicCollectionGame]]? {
        guard let fileURL = fileURL(),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1,
              DiscoverySnapshotPolicy.isUsable(savedAt: snapshot.savedAt, now: now, maximumAge: maximumAge) else {
            return nil
        }
        // Deliberately return stale-but-useful data. Refresh must never erase
        // the last successful landing page before replacement data is ready.
        return snapshot.gamesByFeed
    }

    static func needsRefresh(now: Date = .now, refreshAfter: TimeInterval = 12 * 60 * 60) -> Bool {
        guard let fileURL = fileURL(),
              let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == 1 else {
            return true
        }
        return DiscoverySnapshotPolicy.needsRefresh(
            savedAt: snapshot.savedAt,
            now: now,
            refreshAfter: refreshAfter
        )
    }

    static func save(_ gamesByFeed: [String: [PublicCollectionGame]], now: Date = .now) {
        guard let fileURL = fileURL() else { return }
        let compact = gamesByFeed.mapValues { Array($0.prefix(24)) }
        let snapshot = Snapshot(version: 1, savedAt: now, gamesByFeed: compact)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("itchPocket discovery snapshot write failed: \(error)")
        }
    }

    static func clear() {
        guard let fileURL = fileURL() else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func fileURL() -> URL? {
        guard let directory = try? AppDataStore.cachesDirectory(named: "itchPocket-discovery") else {
            return nil
        }
        return directory.appendingPathComponent(fileName)
    }
}

/// Deterministic age policy for discovery snapshots. Expired snapshots remain
/// useful until the hard retention limit; freshness only controls refresh intent.
enum DiscoverySnapshotPolicy {
    static func isUsable(savedAt: Date, now: Date, maximumAge: TimeInterval) -> Bool {
        now >= savedAt && now.timeIntervalSince(savedAt) <= maximumAge
    }

    static func needsRefresh(savedAt: Date, now: Date, refreshAfter: TimeInterval) -> Bool {
        now < savedAt || now.timeIntervalSince(savedAt) >= refreshAfter
    }
}
