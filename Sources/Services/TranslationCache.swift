import Foundation
import CryptoKit

/// Public cache facade. Persistence and retention are owned by TranslationCacheRepository.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()

    typealias Entry = TranslationCacheRepository.Entry

    private let repository: TranslationCacheRepository

    init(database: AppDatabase? = nil) {
        repository = TranslationCacheRepository(database: database ?? .shared)
    }

    func translation(for key: String) -> Entry? {
        do {
            return try repository.translation(for: key)
        } catch {
            print("itchPocket translation cache read failed: \\(error)")
            return nil
        }
    }

    func latest(scope: String, target: String) -> Entry? {
        do {
            return try repository.latest(scope: scope, target: target)
        } catch {
            print("itchPocket translation cache lookup failed: \\(error)")
            return nil
        }
    }

    func store(_ translation: String, source: String, scope: String, target: String, for key: String) {
        do {
            try repository.store(
                translation,
                source: source,
                scope: scope,
                target: target,
                for: key
            )
        } catch {
            print("itchPocket translation cache write failed: \\(error)")
        }
    }
}

enum TranslationCacheKey {
    static func make(scope: String, source: String, target: String) -> String {
        let input = "\\(scope)|\\(target)|\\(source)"
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
