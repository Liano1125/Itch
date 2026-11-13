import Foundation
import CryptoKit
import SwiftData

/// Owns all SwiftData access and retention policy for translated text.
@MainActor
final class TranslationCacheRepository {
    struct Entry {
        let translation: String
        let sourceHash: String
        let sourceText: String
        let scope: String
        let target: String
        let updatedAt: Date
    }

    private let database: AppDatabase
    private let maximumEntries: Int
    private let retainedEntries: Int

    init(
        database: AppDatabase,
        maximumEntries: Int = 1200,
        retainedEntries: Int = 1000
    ) {
        self.database = database
        self.maximumEntries = maximumEntries
        self.retainedEntries = min(retainedEntries, maximumEntries)
    }

    func translation(for key: String) throws -> Entry? {
        let descriptor = FetchDescriptor<DBTranslation>(
            predicate: #Predicate { $0.cacheKey == key }
        )
        guard let item = try database.repositoryContext.fetch(descriptor).first else { return nil }
        return Self.entry(from: item)
    }

    func latest(scope: String, target: String) throws -> Entry? {
        let descriptor = FetchDescriptor<DBTranslation>(
            predicate: #Predicate { $0.scope == scope && $0.targetLanguage == target },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let item = try database.repositoryContext.fetch(descriptor).first else { return nil }
        return Self.entry(from: item)
    }

    func store(
        _ translation: String,
        source: String,
        scope: String,
        target: String,
        for key: String,
        updatedAt: Date = .now
    ) throws {
        try database.performTransaction {
            let context = database.repositoryContext
            let descriptor = FetchDescriptor<DBTranslation>(
                predicate: #Predicate { $0.cacheKey == key }
            )
            let item: DBTranslation
            if let existing = try context.fetch(descriptor).first {
                item = existing
            } else {
                item = DBTranslation(
                    cacheKey: key,
                    scope: scope,
                    sourceHash: Self.hash(source),
                    sourceText: source,
                    targetLanguage: target,
                    translatedText: translation,
                    updatedAt: updatedAt
                )
                context.insert(item)
            }
            item.scope = scope
            item.sourceHash = Self.hash(source)
            item.sourceText = source
            item.targetLanguage = target
            item.translatedText = translation
            item.updatedAt = updatedAt

            let count = try context.fetchCount(FetchDescriptor<DBTranslation>())
            if count > maximumEntries {
                let oldest = try context.fetch(FetchDescriptor<DBTranslation>(
                    sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
                ))
                let excess = max(0, count - retainedEntries)
                var removed = 0
                for old in oldest where old.cacheKey != key && removed < excess {
                    context.delete(old)
                    removed += 1
                }
            }
            try database.save()
    
        }
    }

    private static func entry(from item: DBTranslation) -> Entry {
        Entry(
            translation: item.translatedText,
            sourceHash: item.sourceHash,
            sourceText: item.sourceText,
            scope: item.scope,
            target: item.targetLanguage,
            updatedAt: item.updatedAt
        )
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
