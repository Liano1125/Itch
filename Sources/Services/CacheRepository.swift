import Foundation
import SwiftData

/// Owns persistence for rebuildable database caches. Durable library, calendar,
/// update history, Spark, developer identity, and app-state records stay in
/// their respective repositories.
@MainActor
final class CacheRepository {
    struct Translation {
        let translation: String
        let sourceHash: String
        let sourceText: String
        let scope: String
        let target: String
        let updatedAt: Date
    }

    struct Counts {
        let translations: Int
        let discoverySnapshots: Int
    }

    static let shared = CacheRepository(database: AppDatabase.shared)

    private let database: AppDatabase
    private let maximumTranslationEntries = 1200
    private let retainedTranslationEntries = 1000

    init(database: AppDatabase) {
        self.database = database
    }

    func translation(for key: String) throws -> Translation? {
        let descriptor = FetchDescriptor<DBTranslation>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        guard let item = try database.context.fetch(descriptor).first else { return nil }
        return Self.translation(from: item)
    }

    func latestTranslation(scope: String, target: String) throws -> Translation? {
        let descriptor = FetchDescriptor<DBTranslation>(
            predicate: #Predicate { $0.scope == scope && $0.targetLanguage == target },
            sortBy: [SortDescriptor(\\.updatedAt, order: .reverse)]
        )
        guard let item = try database.context.fetch(descriptor).first else { return nil }
        return Self.translation(from: item)
    }

    func storeTranslation(
        _ translation: String,
        source: String,
        sourceHash: String,
        scope: String,
        target: String,
        for key: String
    ) throws {
        let context = database.context
        let descriptor = FetchDescriptor<DBTranslation>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        let item = try context.fetch(descriptor).first ?? DBTranslation(
            cacheKey: key,
            scope: scope,
            sourceHash: sourceHash,
            sourceText: source,
            targetLanguage: target,
            translatedText: translation
        )
        if item.modelContext == nil { context.insert(item) }
        item.scope = scope
        item.sourceHash = sourceHash
        item.sourceText = source
        item.targetLanguage = target
        item.translatedText = translation
        item.updatedAt = .now

        let count = try context.fetchCount(FetchDescriptor<DBTranslation>())
        if count > maximumTranslationEntries {
            let oldest = try context.fetch(FetchDescriptor<DBTranslation>(
                sortBy: [SortDescriptor(\\.updatedAt, order: .forward)]
            ))
            let evictionCount = max(0, count - retainedTranslationEntries)
            for old in oldest.filter({ $0.cacheKey != key }).prefix(evictionCount) {
                context.delete(old)
            }
        }
        try database.save()
    }

    func discoverySnapshot(for key: String, now: Date = .now) throws -> Data? {
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

    func storeDiscoverySnapshot(
        _ payload: Data,
        key: String,
        timeToLive: TimeInterval,
        now: Date = .now
    ) throws {
        let context = database.context
        let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.key == key }
        )
        let snapshot = try context.fetch(descriptor).first
            ?? DBDiscoverySnapshot(key: key, payload: payload, expiresAt: now.addingTimeInterval(timeToLive))
        if snapshot.modelContext == nil { context.insert(snapshot) }
        snapshot.payload = payload
        snapshot.fetchedAt = now
        snapshot.expiresAt = now.addingTimeInterval(timeToLive)
        try database.save()
    }

    func removeDiscoverySnapshot(key: String) throws {
        let context = database.context
        let descriptor = FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.key == key }
        )
        if let snapshot = try context.fetch(descriptor).first {
            context.delete(snapshot)
            try database.save()
        }
    }

    func counts() throws -> Counts {
        let context = database.context
        return Counts(
            translations: try context.fetchCount(FetchDescriptor<DBTranslation>()),
            discoverySnapshots: try context.fetchCount(FetchDescriptor<DBDiscoverySnapshot>())
        )
    }

    /// Clears only the two cache-owned tables. Avatar metadata and app-state
    /// keys are invalidated by their own repositories at the lifecycle layer.
    func clearRebuildableCaches(save shouldSave: Bool = true) throws {
        let context = database.context
        try context.delete(model: DBTranslation.self)
        try context.delete(model: DBDiscoverySnapshot.self)
        if shouldSave { try database.save() }
    }

    func pruneExpiredDiscoverySnapshots(now: Date = .now, save shouldSave: Bool = true) throws {
        let context = database.context
        let expired = try context.fetch(FetchDescriptor<DBDiscoverySnapshot>(
            predicate: #Predicate { $0.expiresAt <= now }
        ))
        guard !expired.isEmpty else { return }
        for snapshot in expired { context.delete(snapshot) }
        if shouldSave { try database.save() }
    }

    private static func translation(from item: DBTranslation) -> Translation {
        Translation(
            translation: item.translatedText,
            sourceHash: item.sourceHash,
            sourceText: item.sourceText,
            scope: item.scope,
            target: item.targetLanguage,
            updatedAt: item.updatedAt
        )
    }
}
