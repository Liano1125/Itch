import Foundation
import SwiftData

struct AppCacheSummary {
    let translations: Int
    let discoverySnapshots: Int
    let imageBytes: Int64
}

/// The only entry point for cache lifecycle operations. Durable library,
/// calendar, Spark and account data are deliberately excluded from clearing.
@MainActor
enum AppCacheManager {
    static func summary() -> AppCacheSummary {
        let context = AppDatabase.shared.context
        let translations = (try? context.fetchCount(FetchDescriptor<DBTranslation>())) ?? 0
        let discovery = (try? context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>())) ?? 0
        let directory = (try? AppDataStore.cachesDirectory(named: "itchPocket-images"))
        let files = directory.flatMap {
            try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.fileSizeKey])
        } ?? []
        let bytes = files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return AppCacheSummary(translations: translations, discoverySnapshots: discovery, imageBytes: bytes)
    }

    static func clearRebuildableCaches() async throws {
        let context = AppDatabase.shared.context
        try context.delete(model: DBTranslation.self)
        try context.delete(model: DBDiscoverySnapshot.self)

        // These are refetchable page enrichments, not user-authored data.
        for game in try context.fetch(FetchDescriptor<DBGame>()) {
            game.descriptionText = nil
            game.galleryURLs = []
        }
        for state in try context.fetch(FetchDescriptor<DBAppState>()) where state.key.hasPrefix("avatarFailure.") {\n            context.delete(state)\n        }\n        for developer in try context.fetch(FetchDescriptor<DBDeveloper>()) {
            developer.avatarURL = nil
            developer.avatarSource = nil
            developer.avatarResolvedAt = nil
        }

        try AppDatabase.shared.save()
        await PersistentImageCache.shared.clear()
        URLCache.shared.removeAllCachedResponses()
    }

    static func pruneExpiredCaches(now: Date = .now) async throws {
        let context = AppDatabase.shared.context
        let expired = try context.fetch(FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.expiresAt <= now }
        ))
        for snapshot in expired { context.delete(snapshot) }
        try AppDatabase.shared.save()
    }
}
