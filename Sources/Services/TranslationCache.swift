import Foundation
import CryptoKit

/// Translation records live in the canonical database; this type is a small
/// repository facade, not a second JSON cache file.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()

    struct Entry {
        let translation: String
        let sourceHash: String
        let scope: String
        let target: String
        let updatedAt: Date
    }

    private let database = AppDatabase.shared
    private let maximumEntries = 1200
    private let retainedEntries = 1000

    private init() {}

    func translation(for key: String) -> Entry? {
        do {
            guard let item = try database.context.fetch(FetchDescriptor<DBTranslation>(
                predicate: #Predicate { $0.cacheKey == key }
            )).first else { return nil }
            return Entry(
                translation: item.translatedText,
                sourceHash: item.sourceHash,
                scope: item.scope,
                target: item.targetLanguage,
                updatedAt: item.updatedAt
            )
        } catch {
            print("itchPocket translation cache read failed: \(error)")
            return nil
        }
    }

    func latest(scope: String, target: String) -> Entry? {
        do {
            let items = try database.context.fetch(FetchDescriptor<DBTranslation>(
                predicate: #Predicate { $0.scope == scope && $0.targetLanguage == target },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            ))
            guard let item = items.first else { return nil }
            return Entry(
                translation: item.translatedText,
                sourceHash: item.sourceHash,
                scope: item.scope,
                target: item.targetLanguage,
                updatedAt: item.updatedAt
            )
        } catch {
            print("itchPocket translation cache lookup failed: \(error)")
            return nil
        }
    }

    func store(_ translation: String, source: String, scope: String, target: String, for key: String) {
        let context = database.context
        do {
            let item = try context.fetch(FetchDescriptor<DBTranslation>(
                predicate: #Predicate { $0.cacheKey == key }
            )).first ?? DBTranslation(
                cacheKey: key,
                scope: scope,
                sourceHash: Self.hash(source),
                targetLanguage: target,
                translatedText: translation
            )
            if item.modelContext == nil { context.insert(item) }
            item.scope = scope
            item.sourceHash = Self.hash(source)
            item.targetLanguage = target
            item.translatedText = translation
            item.updatedAt = .now

            let count = try context.fetchCount(FetchDescriptor<DBTranslation>())
            if count > maximumEntries {
                let oldest = try context.fetch(FetchDescriptor<DBTranslation>(
                    sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
                ))
                for old in oldest.prefix(max(0, count - retainedEntries)) where old.cacheKey != key {
                    context.delete(old)
                }
            }
            try database.save()
        } catch {
            print("itchPocket translation cache write failed: \(error)")
        }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum TranslationCacheKey {
    static func make(scope: String, source: String, target: String) -> String {
        let input = "\(scope)|\(target)|\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
