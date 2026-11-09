import Foundation
import CryptoKit

/// Translation cache facade. All durable cache access is delegated to CacheRepository.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()

    struct Entry {
        let translation: String
        let sourceHash: String
        let sourceText: String
        let scope: String
        let target: String
        let updatedAt: Date
    }

    private let repository = CacheRepository.shared

    private init() {}

    func translation(for key: String) -> Entry? {
        do {
            guard let entry = try repository.translation(for: key) else { return nil }
            return Self.entry(from: entry)
        } catch {
            print("itchPocket translation cache read failed: \(error)")
            return nil
        }
    }

    func latest(scope: String, target: String) -> Entry? {
        do {
            guard let entry = try repository.latestTranslation(scope: scope, target: target) else { return nil }
            return Self.entry(from: entry)
        } catch {
            print("itchPocket translation cache lookup failed: \(error)")
            return nil
        }
    }

    func store(_ translation: String, source: String, scope: String, target: String, for key: String) {
        do {
            try repository.storeTranslation(
                translation,
                source: source,
                sourceHash: Self.hash(source),
                scope: scope,
                target: target,
                for: key
            )
        } catch {
            print("itchPocket translation cache write failed: \(error)")
        }
    }

    private static func entry(from value: CacheRepository.Translation) -> Entry {
        Entry(
            translation: value.translation,
            sourceHash: value.sourceHash,
            sourceText: value.sourceText,
            scope: value.scope,
            target: value.target,
            updatedAt: value.updatedAt
        )
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
