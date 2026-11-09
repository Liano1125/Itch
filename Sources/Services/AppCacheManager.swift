import Foundation

struct AppCacheSummary {
    let translations: Int
    let discoverySnapshots: Int
    let imageBytes: Int64
}

/// Coordinates cache lifecycle operations across their owning repositories
/// and the filesystem/URL caches.
@MainActor
enum AppCacheManager {
    static func summary() -> AppCacheSummary {
        let counts = try? CacheRepository.shared.counts()
        let directory = try? AppDataStore.cachesDirectory(named: "itchPocket-images")
        let files = directory.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey])
        } ?? []
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return AppCacheSummary(
            translations: counts?.translations ?? 0,
            discoverySnapshots: counts?.discoverySnapshots ?? 0,
            imageBytes: bytes
        )
    }

    static func clearRebuildableCaches() async throws {
        let database = AppDatabase.shared
        try CacheRepository.shared.clearRebuildableCaches(save: false)
        try AppStateRepository(database: database)
            .removeAll(matchingKeyPrefix: "avatarFailure.", save: false)
        try DeveloperRepository(database: database).invalidateAvatarCaches(save: false)
        try database.save()

        await PersistentImageCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
    }

    static func pruneExpiredCaches(now: Date = .now) async throws {
        try CacheRepository.shared.pruneExpiredDiscoverySnapshots(now: now)
        await PersistentImageCache.shared.prune()
    }
}
